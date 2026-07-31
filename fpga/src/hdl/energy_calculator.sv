`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：energy_calculator
//
// 主要功能：
//   根据基频检测结果依次计算基波、二次谐波和三次谐波的7点功率谱能量，
//   判断高次谐波是否存在，并将一帧完整结果写入独立的能量结果BRAM。
//
// 使用方法：
//   1. 基频检测结束后，将base_valid、base_index_500和阈值参数保持稳定；
//   2. 向start输入一个时钟周期的高脉冲；
//   3. 通过mem_req/mem_ready提交频谱读取请求，只在mem_rvalid时接收数据；
//   4. 等待done单拍脉冲，随后可由PS读取能量结果BRAM。
//
// 连接说明：
//   clk/result_bram_*  <- 本模块工作时钟及能量结果BRAM的PL写端口
//   start              <- Spectrol的energy_start
//   base_*             <- base_detector的检测结果
//   mem_*              <-> Spectrol提供的能量频谱读取接口
//   done               -> Spectrol的energy_done
//
// 时钟与复位：
//   所有逻辑位于clk时钟域；rst为高电平有效的同步复位。复位期间停止读请求和
//   BRAM写入，并清除busy、done及普通状态输出。
//
// 输入格式：
//   mem_rdata为U32功率谱；base_index_500的单位为500 Hz；absolute_threshold
//   使用“功率谱已右移8位、7点求和后、能量尚未右移3位”的原始能量尺度。
//
// 输出格式：
//   原始7点能量内部使用POWER_WIDTH+3位无符号数。写入BRAM的能量统一执行
//   (energy_raw + 4) >> 3，并在超过U32时防御性饱和。
//
// 握手时序：
//   mem_req在请求未被接受时保持有效且地址稳定；mem_req与mem_ready同时为1
//   表示请求被接受。模块允许提交请求和接收旧请求返回在同一周期发生。
//   最终状态字W0是每帧最后一次BRAM写入；done在该写入完成后保持一个周期。
//
// 参数说明：
//   当前系统配置为U32功率、11位频谱地址、7点窗口、最大bin 2047和右移3位。
//   参数保留用于独立验证防御性位宽逻辑，系统集成时应使用默认配置。
//
// 错误行为：
//   busy期间的start被忽略；ratio_den为0时置threshold_invalid且高次谐波均
//   判为不存在；无效基频或越界候选不发起读取并写入零能量；收到无对应请求的
//   mem_rvalid时置read_error。接口不包含超时计数，缺失返回会使模块保持busy。
//
// 使用限制：
//   同一候选最多允许WINDOW_POINTS个未完成读请求。上游必须保证每个被接受的
//   请求最终恰好返回一次，并且返回顺序与请求顺序一致。
// ============================================================================
module energy_calculator #(
    parameter int unsigned POWER_WIDTH         = 32,
    parameter int unsigned ENERGY_ACC_WIDTH    = POWER_WIDTH + 3,
    parameter int unsigned ENERGY_SHIFT        = 3,
    parameter int unsigned INDEX_WIDTH         = 16,
    parameter int unsigned SPECTRUM_ADDR_WIDTH = 11,
    parameter int unsigned RESULT_ADDR_WIDTH   = 4,
    parameter int unsigned WINDOW_RADIUS       = 3,
    parameter int unsigned MAX_SPECTRUM_BIN    = 2047
) (
    // 时钟与复位
    input  wire logic                              clk,  // 模块工作时钟
    input  wire logic                              rst,  // 高电平有效同步复位

    // 控制接口
    input  wire logic                              start, // 空闲时采样的单拍启动脉冲
    output      logic                              busy,  // 模块正在处理一帧
    output      logic                              done,  // 最终状态字写完后的单拍脉冲

    // 基频结果和谐波判断配置
    input  wire logic                              base_valid,     // 基频检测结果有效
    input  wire logic [INDEX_WIDTH-1:0]            base_index_500, // 基频编号，单位500 Hz
    input  wire logic [31:0]                       absolute_threshold, // 原始7点能量绝对阈值
    input  wire logic [15:0]                       ratio_num,      // 相对基波能量比例分子
    input  wire logic [15:0]                       ratio_den,      // 相对基波能量比例分母

    // 通过Spectrol读取频谱BRAM
    output      logic                              mem_req,    // 频谱读取请求，未接受时保持
    output      logic [SPECTRUM_ADDR_WIDTH-1:0]    mem_addr,   // 频谱BRAM逻辑字地址
    input  wire logic                              mem_ready,  // Spectrol本周期可接受请求
    input  wire logic                              mem_rvalid, // 返回功率数据有效
    input  wire logic [POWER_WIDTH-1:0]            mem_rdata,  // 无符号功率谱数据

    // 能量结果BRAM写端口
    output      logic                              result_bram_en,   // BRAM端口使能
    output      logic                              result_bram_we,   // 单比特整字写使能
    output      logic [RESULT_ADDR_WIDTH-1:0]      result_bram_addr, // 32位字地址
    output      logic [31:0]                       result_bram_din,  // 32位写数据

    // 状态和调试输出
    output      logic [2:0]                        harmonic_present_mask, // bit0～2对应1～3次
    output      logic [2:0]                        position_valid_mask,   // 三个7点窗口有效位
    output      logic                              result_valid,          // 当前结果BRAM已提交完整帧
    output      logic                              energy_overflow        // 至少一个能量发生饱和
);

    localparam int unsigned WINDOW_POINTS =
        (2 * WINDOW_RADIUS) + 1;
    localparam int unsigned COUNT_WIDTH =
        $clog2(WINDOW_POINTS + 1);
    localparam int unsigned RATIO_PRODUCT_WIDTH =
        ENERGY_ACC_WIDTH + 16;
    localparam int unsigned MAX_CENTER_BIN =
        MAX_SPECTRUM_BIN - WINDOW_RADIUS;

    typedef enum logic [3:0] {
        STATE_IDLE,
        STATE_WRITE_BUSY,
        STATE_PREPARE,
        STATE_DIVIDE,
        STATE_CHECK_POSITION,
        STATE_READ,
        STATE_RATIO_MULTIPLY,
        STATE_CHECK,
        STATE_WRITE_RESULTS,
        STATE_COMMIT
    } state_t;

    state_t state;

    logic                              base_valid_latched;
    logic [INDEX_WIDTH-1:0]            base_index_latched;
    logic [31:0]                       absolute_threshold_latched;
    logic [15:0]                       ratio_num_latched;
    logic [15:0]                       ratio_den_latched;

    logic [1:0]                        candidate_order;
    logic [31:0]                       candidate_index_calc;
    logic [39:0]                       candidate_numerator_calc;
    logic [31:0]                       current_candidate_index;
    logic [39:0]                       candidate_bin_reg;
    logic [31:0]                       candidate_index [0:2];
    logic [SPECTRUM_ADDR_WIDTH-1:0]    window_start_addr;

    logic [39:0]                       divide_dividend;
    logic [39:0]                       divide_quotient;
    logic [7:0]                        divide_remainder;
    logic [5:0]                        divide_count;
    logic [7:0]                        divide_trial;
    logic [39:0]                       divide_dividend_next;
    logic [39:0]                       divide_quotient_next;
    logic [7:0]                        divide_remainder_next;

    logic [COUNT_WIDTH-1:0]            issue_count;
    logic [COUNT_WIDTH-1:0]            receive_count;
    logic [ENERGY_ACC_WIDTH-1:0]       energy_acc;
    logic [ENERGY_ACC_WIDTH-1:0]       energy_acc_next;

    logic [ENERGY_ACC_WIDTH-1:0]       base_energy_raw;
    logic [ENERGY_ACC_WIDTH-1:0]       harmonic2_energy_raw;
    logic [ENERGY_ACC_WIDTH-1:0]       harmonic3_energy_raw;
    logic [31:0]                       base_energy_out;
    logic [31:0]                       harmonic2_energy_out;
    logic [31:0]                       harmonic3_energy_out;

    logic                              base_invalid;
    logic                              threshold_invalid;
    logic                              read_error;
    logic [RESULT_ADDR_WIDTH-1:0]      write_addr;

    logic [RATIO_PRODUCT_WIDTH-1:0]    base_ratio_product;
    logic [RATIO_PRODUCT_WIDTH-1:0]    harmonic2_ratio_product;
    logic [RATIO_PRODUCT_WIDTH-1:0]    harmonic3_ratio_product;
    logic [RATIO_PRODUCT_WIDTH-1:0]    base_ratio_product_calc;
    logic [RATIO_PRODUCT_WIDTH-1:0]    harmonic2_ratio_product_calc;
    logic [RATIO_PRODUCT_WIDTH-1:0]    harmonic3_ratio_product_calc;
    logic [ENERGY_ACC_WIDTH-1:0]       absolute_threshold_ext;

    logic [32:0]                       base_scaled;
    logic [32:0]                       harmonic2_scaled;
    logic [32:0]                       harmonic3_scaled;
    logic [31:0]                       status_common;
    logic [31:0]                       status_busy;
    logic [31:0]                       status_final;

    wire logic request_fire;

    initial begin
        assert (POWER_WIDTH > 0)
            else $fatal(1, "POWER_WIDTH必须大于0");
        assert (ENERGY_ACC_WIDTH >= POWER_WIDTH + 3)
            else $fatal(1, "ENERGY_ACC_WIDTH不足以保存7点功率和");
        assert (ENERGY_ACC_WIDTH >= 32)
            else $fatal(1, "ENERGY_ACC_WIDTH必须至少为32");
        assert (ENERGY_SHIFT > 0 && ENERGY_SHIFT <= ENERGY_ACC_WIDTH)
            else $fatal(1, "ENERGY_SHIFT超出合法范围");
        assert (INDEX_WIDTH > 0 && INDEX_WIDTH <= 32)
            else $fatal(1, "INDEX_WIDTH必须位于1到32之间");
        assert (SPECTRUM_ADDR_WIDTH > 0 &&
                MAX_SPECTRUM_BIN < (1 << SPECTRUM_ADDR_WIDTH))
            else $fatal(1, "频谱地址位宽不足");
        assert (RESULT_ADDR_WIDTH >= 4)
            else $fatal(1, "结果BRAM地址位宽必须至少为4");
        assert (WINDOW_RADIUS == 3 && WINDOW_POINTS == 7)
            else $fatal(1, "当前版本仅验证7点能量窗口");
        assert (MAX_SPECTRUM_BIN > WINDOW_RADIUS)
            else $fatal(1, "MAX_SPECTRUM_BIN过小");
    end

    // 将原始宽位能量统一四舍五入右移，并返回{溢出标志,U32结果}。
    function automatic logic [32:0] scale_energy (
        input logic [ENERGY_ACC_WIDTH-1:0] value
    );
        logic [ENERGY_ACC_WIDTH:0] rounded_ext;
        logic [ENERGY_ACC_WIDTH:0] scaled_ext;
        begin
            rounded_ext =
                {1'b0, value} +
                ({{ENERGY_ACC_WIDTH{1'b0}}, 1'b1} <<
                 (ENERGY_SHIFT - 1));
            scaled_ext = rounded_ext >> ENERGY_SHIFT;

            if (|scaled_ext[ENERGY_ACC_WIDTH:32]) begin
                scale_energy = {1'b1, 32'hFFFF_FFFF};
            end else begin
                scale_energy = {1'b0, scaled_ext[31:0]};
            end
        end
    endfunction

    always_comb begin
        case (candidate_order)
            2'd1: candidate_index_calc =
                {{(32-INDEX_WIDTH){1'b0}}, base_index_latched};
            2'd2: candidate_index_calc =
                {{(32-INDEX_WIDTH){1'b0}}, base_index_latched} << 1;
            default: candidate_index_calc =
                {{(32-INDEX_WIDTH){1'b0}}, base_index_latched} +
                ({{(32-INDEX_WIDTH){1'b0}}, base_index_latched} << 1);
        endcase
        candidate_numerator_calc =
            ({8'd0, candidate_index_calc} << 7) + 40'd62;

        // 逐位无符号除法每拍只包含8位比较和减法，避免组合“除以125”长路径。
        divide_trial = {divide_remainder[6:0], divide_dividend[39]};
        divide_dividend_next = {divide_dividend[38:0], 1'b0};
        divide_quotient_next =
            {divide_quotient[38:0], (divide_trial >= 8'd125)};
        if (divide_trial >= 8'd125) begin
            divide_remainder_next = divide_trial - 8'd125;
        end else begin
            divide_remainder_next = divide_trial;
        end

        energy_acc_next =
            energy_acc +
            {{(ENERGY_ACC_WIDTH - POWER_WIDTH){1'b0}}, mem_rdata};

        absolute_threshold_ext =
            {{(ENERGY_ACC_WIDTH-32){1'b0}},
              absolute_threshold_latched};

        // 显式扩展原始能量，保证比例乘法的完整结果宽度为ENERGY_ACC_WIDTH+16。
        base_ratio_product_calc =
            {{16{1'b0}}, base_energy_raw} * ratio_num_latched;
        harmonic2_ratio_product_calc =
            {{16{1'b0}}, harmonic2_energy_raw} * ratio_den_latched;
        harmonic3_ratio_product_calc =
            {{16{1'b0}}, harmonic3_energy_raw} * ratio_den_latched;

        base_scaled      = scale_energy(base_energy_raw);
        harmonic2_scaled = scale_energy(harmonic2_energy_raw);
        harmonic3_scaled = scale_energy(harmonic3_energy_raw);

        status_common = 32'd0;
        status_common[2]     = energy_overflow;
        status_common[3]     = base_invalid;
        status_common[4]     = threshold_invalid;
        status_common[5]     = read_error;
        status_common[10:8]  = harmonic_present_mask;
        status_common[13:11] = position_valid_mask;

        status_busy       = status_common;
        status_busy[0]    = 1'b0;
        status_busy[1]    = 1'b1;
        status_final      = status_common;
        status_final[0]   = 1'b1;
        status_final[1]   = 1'b0;
    end

    assign request_fire = mem_req && mem_ready;

    // 读取请求由已提交数量直接生成，反压时计数不变，因此地址和req自然保持。
    always_comb begin
        mem_req  = 1'b0;
        mem_addr = window_start_addr + issue_count;

        if ((state == STATE_READ) &&
            (issue_count < WINDOW_POINTS)) begin
            mem_req = 1'b1;
        end
    end

    // 结果BRAM没有ready接口；每个写状态在当前上升沿完成一次整字写入。
    always_comb begin
        result_bram_en   = 1'b0;
        result_bram_we   = 1'b0;
        result_bram_addr = '0;
        result_bram_din  = 32'd0;

        case (state)
            STATE_WRITE_BUSY: begin
                result_bram_en   = 1'b1;
                result_bram_we   = 1'b1;
                result_bram_addr = '0;
                result_bram_din  = status_busy;
            end

            STATE_WRITE_RESULTS: begin
                result_bram_en   = 1'b1;
                result_bram_we   = 1'b1;
                result_bram_addr = write_addr;
                case (write_addr)
                    4'd1: result_bram_din = candidate_index[0];
                    4'd2: result_bram_din = base_energy_out;
                    4'd3: result_bram_din = candidate_index[1];
                    4'd4: result_bram_din = harmonic2_energy_out;
                    4'd5: result_bram_din = candidate_index[2];
                    4'd6: result_bram_din = harmonic3_energy_out;
                    4'd7: result_bram_din = ENERGY_SHIFT;
                    4'd8: result_bram_din = absolute_threshold_latched;
                    4'd9: result_bram_din =
                        {ratio_den_latched, ratio_num_latched};
                    default: result_bram_din = 32'd0; // W10～W15保留字
                endcase
            end

            STATE_COMMIT: begin
                result_bram_en   = 1'b1;
                result_bram_we   = 1'b1;
                result_bram_addr = '0;
                result_bram_din  = status_final;
            end

            default: begin
                result_bram_en   = 1'b0;
                result_bram_we   = 1'b0;
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state                       <= STATE_IDLE;
            busy                        <= 1'b0;
            done                        <= 1'b0;
            base_valid_latched          <= 1'b0;
            base_index_latched          <= '0;
            absolute_threshold_latched  <= 32'd0;
            ratio_num_latched           <= 16'd0;
            ratio_den_latched           <= 16'd0;
            candidate_order             <= 2'd1;
            current_candidate_index     <= 32'd0;
            candidate_bin_reg           <= 40'd0;
            candidate_index[0]          <= 32'd0;
            candidate_index[1]          <= 32'd0;
            candidate_index[2]          <= 32'd0;
            window_start_addr           <= '0;
            divide_dividend             <= 40'd0;
            divide_quotient             <= 40'd0;
            divide_remainder            <= 8'd0;
            divide_count                <= 6'd0;
            issue_count                 <= '0;
            receive_count               <= '0;
            energy_acc                  <= '0;
            base_energy_raw             <= '0;
            harmonic2_energy_raw        <= '0;
            harmonic3_energy_raw        <= '0;
            base_energy_out             <= 32'd0;
            harmonic2_energy_out        <= 32'd0;
            harmonic3_energy_out        <= 32'd0;
            base_ratio_product          <= '0;
            harmonic2_ratio_product     <= '0;
            harmonic3_ratio_product     <= '0;
            harmonic_present_mask       <= 3'b000;
            position_valid_mask         <= 3'b000;
            result_valid                <= 1'b0;
            energy_overflow             <= 1'b0;
            base_invalid                <= 1'b0;
            threshold_invalid           <= 1'b0;
            read_error                  <= 1'b0;
            write_addr                  <= '0;
        end else begin
            done <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy                       <= 1'b1;
                        result_valid               <= 1'b0;
                        base_valid_latched         <= base_valid;
                        base_index_latched         <= base_index_500;
                        absolute_threshold_latched <= absolute_threshold;
                        ratio_num_latched          <= ratio_num;
                        ratio_den_latched          <= ratio_den;
                        candidate_order            <= 2'd1;
                        current_candidate_index    <= 32'd0;
                        candidate_bin_reg          <= 40'd0;
                        candidate_index[0]         <= 32'd0;
                        candidate_index[1]         <= 32'd0;
                        candidate_index[2]         <= 32'd0;
                        issue_count                <= '0;
                        receive_count              <= '0;
                        energy_acc                 <= '0;
                        divide_dividend            <= 40'd0;
                        divide_quotient            <= 40'd0;
                        divide_remainder           <= 8'd0;
                        divide_count               <= 6'd0;
                        base_energy_raw            <= '0;
                        harmonic2_energy_raw       <= '0;
                        harmonic3_energy_raw       <= '0;
                        base_energy_out            <= 32'd0;
                        harmonic2_energy_out       <= 32'd0;
                        harmonic3_energy_out       <= 32'd0;
                        base_ratio_product         <= '0;
                        harmonic2_ratio_product    <= '0;
                        harmonic3_ratio_product    <= '0;
                        harmonic_present_mask      <= 3'b000;
                        position_valid_mask        <= 3'b000;
                        energy_overflow            <= 1'b0;
                        base_invalid               <= !base_valid;
                        threshold_invalid          <= (ratio_den == 16'd0);
                        read_error                 <= 1'b0;
                        write_addr                 <= '0;
                        state                      <= STATE_WRITE_BUSY;
                    end
                end

                STATE_WRITE_BUSY: begin
                    state <= STATE_PREPARE;
                end

                STATE_PREPARE: begin
                    current_candidate_index <= candidate_index_calc;
                    divide_dividend  <= candidate_numerator_calc;
                    divide_quotient  <= 40'd0;
                    divide_remainder <= 8'd0;
                    divide_count     <= 6'd0;
                    issue_count   <= '0;
                    receive_count <= '0;
                    energy_acc    <= '0;
                    state         <= STATE_DIVIDE;
                end

                STATE_DIVIDE: begin
                    divide_dividend  <= divide_dividend_next;
                    divide_quotient  <= divide_quotient_next;
                    divide_remainder <= divide_remainder_next;
                    if (divide_count == 6'd39) begin
                        candidate_bin_reg <= divide_quotient_next;
                        state             <= STATE_CHECK_POSITION;
                    end else begin
                        divide_count <= divide_count + 1'b1;
                    end
                end

                STATE_CHECK_POSITION: begin
                    candidate_index[candidate_order-1'b1] <=
                        current_candidate_index;
                    if (base_valid_latched &&
                        (candidate_bin_reg >= WINDOW_RADIUS) &&
                        (candidate_bin_reg <= MAX_CENTER_BIN)) begin
                        position_valid_mask[candidate_order-1'b1] <= 1'b1;
                        window_start_addr <=
                            candidate_bin_reg[SPECTRUM_ADDR_WIDTH-1:0] -
                            WINDOW_RADIUS;
                        state <= STATE_READ;
                    end else begin
                        case (candidate_order)
                            2'd1: begin
                                base_energy_raw <= '0;
                                if (base_valid_latched) begin
                                    base_invalid <= 1'b1;
                                end
                            end
                            2'd2: harmonic2_energy_raw <= '0;
                            default: harmonic3_energy_raw <= '0;
                        endcase

                        if (candidate_order == 2'd3) begin
                            state <= STATE_RATIO_MULTIPLY;
                        end else begin
                            candidate_order <= candidate_order + 1'b1;
                            state <= STATE_PREPARE;
                        end
                    end
                end

                STATE_READ: begin
                    if (request_fire) begin
                        issue_count <= issue_count + 1'b1;
                    end

                    if (mem_rvalid) begin
                        // 允许同拍提交新请求并接收旧请求；也兼容零延迟响应模型。
                        if ((receive_count < issue_count) || request_fire) begin
                            if (receive_count == WINDOW_POINTS-1) begin
                                case (candidate_order)
                                    2'd1: base_energy_raw <=
                                        energy_acc_next;
                                    2'd2: harmonic2_energy_raw <=
                                        energy_acc_next;
                                    default: harmonic3_energy_raw <=
                                        energy_acc_next;
                                endcase

                                energy_acc <= energy_acc_next;
                                if (candidate_order == 2'd3) begin
                                    state <= STATE_RATIO_MULTIPLY;
                                end else begin
                                    candidate_order <=
                                        candidate_order + 1'b1;
                                    state <= STATE_PREPARE;
                                end
                            end else begin
                                energy_acc <= energy_acc_next;
                                receive_count <= receive_count + 1'b1;
                            end
                        end else begin
                            read_error <= 1'b1;
                        end
                    end
                end

                STATE_RATIO_MULTIPLY: begin
                    base_ratio_product      <= base_ratio_product_calc;
                    harmonic2_ratio_product <= harmonic2_ratio_product_calc;
                    harmonic3_ratio_product <= harmonic3_ratio_product_calc;
                    base_energy_out      <= base_scaled[31:0];
                    harmonic2_energy_out <= harmonic2_scaled[31:0];
                    harmonic3_energy_out <= harmonic3_scaled[31:0];
                    energy_overflow <=
                        base_scaled[32] ||
                        harmonic2_scaled[32] ||
                        harmonic3_scaled[32];
                    state <= STATE_CHECK;
                end

                STATE_CHECK: begin
                    harmonic_present_mask[0] <=
                        base_valid_latched && position_valid_mask[0];
                    harmonic_present_mask[1] <=
                        position_valid_mask[1] &&
                        !threshold_invalid &&
                        (harmonic2_energy_raw >= absolute_threshold_ext) &&
                        (harmonic2_ratio_product >= base_ratio_product);
                    harmonic_present_mask[2] <=
                        position_valid_mask[2] &&
                        !threshold_invalid &&
                        (harmonic3_energy_raw >= absolute_threshold_ext) &&
                        (harmonic3_ratio_product >= base_ratio_product);

                    write_addr <= {{(RESULT_ADDR_WIDTH-1){1'b0}}, 1'b1};
                    state      <= STATE_WRITE_RESULTS;
                end

                STATE_WRITE_RESULTS: begin
                    if (write_addr == 4'd15) begin
                        state <= STATE_COMMIT;
                    end else begin
                        write_addr <= write_addr + 1'b1;
                    end
                end

                STATE_COMMIT: begin
                    // 本上升沿完成最终W0写入；done随后保持一个完整时钟周期。
                    busy         <= 1'b0;
                    result_valid <= 1'b1;
                    done         <= 1'b1;
                    state        <= STATE_IDLE;
                end

                default: begin
                    state        <= STATE_IDLE;
                    busy         <= 1'b0;
                    result_valid <= 1'b0;
                    read_error   <= 1'b1;
                end
            endcase
        end
    end

    // 实现问题记录：
    // 1. 第7个返回数据与保存原始能量发生在同一拍，使用energy_acc_next避免遗漏。
    // 2. 比例比较先把原始能量扩展16位，避免35位与16位乘法结果被截断。
    // 3. 最终W0使用独立COMMIT状态，保证它严格晚于W1～W15的全部写入。
    // 4. 组合除以125无法满足100 MHz，改用40拍逐位除法并流水化比例乘法。

endmodule

`default_nettype wire
