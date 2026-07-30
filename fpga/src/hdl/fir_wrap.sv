`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：fir_wrap
//
// 主要功能：
//   在fifo_ctrl的定长帧valid-ready接口与fir_compiler_0 AXI4-Stream接口之间
//   完成协议适配。模块在每帧之间复位FIR数据向量，把IP的40位有符号原始输出
//   按2^19系数标度执行对称舍入和16位饱和，并重新产生输出帧首、帧尾及完成脉冲。
//
// 使用方法：
//   1. 将fir_*输入及fir_ready/fir_frame_done连接fifo_ctrl的同名接口。
//   2. 将sample_*输出连接峰峰值、均方值及波形写入模块。
//   3. 工程中必须包含配置完成的fir_compiler_0，输入16位、物理输出40位，
//      并启用低电平有效的aresetn端口。
//
// 时钟与复位：
//   所有端口均属于clk域。rst为高电平有效同步业务复位，同时组合拉低FIR IP的
//   aresetn。每帧输出结束后，IP的aresetn至少保持RESET_CYCLES个clk上升沿为低。
//
// 数据及定点格式：
//   fir_data/sample_data均为16位有符号二进制补码整数。fir_compiler_0输出端口
//   为40位符号扩展数据，其中配置的有效运算宽度为36位。COE整数系数和为
//   524288=2^19，因此原始输出经对称最近值舍入后算术右移19位恢复单位增益。
//   超过16位范围时输出饱和值并锁存saturation_error，绝不执行回绕截断。
//
// 握手及时序：
//   仅在fir_valid && fir_ready时接收输入；反压期间不推进输入计数。IP未配置
//   输出TREADY，因此每个m_axis_data_tvalid都必须被本模块和下游立即接收。
//   sample_first/sample_last仅随sample_valid有效，分别标记第0和FRAME_SIZE-1个
//   输出。最后一个有效输出在上升沿被下游接收后，fir_frame_done在随后一个
//   clk周期保持为高，用于通知fifo_ctrl整帧输出已经结束。
//
// 帧语义：
//   帧长度固定为FRAME_SIZE。帧标志错误会锁存protocol_error，但模块仍按内部
//   计数完成当前帧，避免链路死锁。每帧之间复位IP，所以各帧从零历史状态开始；
//   帧首约TAP_COUNT-1个输出包含FIR零状态启动瞬态。
//
// 性能：
//   吞吐率由fir_compiler_0的s_axis_data_tready决定。当前IP按100 MHz时钟、
//   32 MSPS样点率配置，通常每3个时钟接受一个输入；包装层不增加输入限速。
// ============================================================================

module fir_wrap #(
    parameter int unsigned FRAME_SIZE   = 65536, // 每帧输入和输出样点数，单位为点，必须大于0
    parameter int unsigned RESET_CYCLES = 3      // 两帧间FIR复位保持周期数，必须至少为2
) (
    input  wire logic               clk,              // 100 MHz FIR处理时钟
    input  wire logic               rst,              // 高电平有效同步业务复位
    input  wire logic               clear_error,      // 清除粘滞错误，高电平可保持

    input  wire logic signed [15:0] fir_data,         // fifo_ctrl输出的16位有符号样点
    input  wire logic               fir_valid,        // 输入样点有效
    output      logic               fir_ready,        // 包装层及FIR IP可以接收当前样点
    input  wire logic               fir_first,        // 当前样点为输入帧首
    input  wire logic               fir_last,         // 当前样点为输入帧尾

    output      logic signed [15:0] sample_data,      // 缩放、舍入、饱和后的FIR输出
    output      logic               sample_valid,     // 输出样点有效
    output      logic               sample_first,     // 当前有效输出为帧首
    output      logic               sample_last,      // 当前有效输出为帧尾

    output      logic               fir_frame_done,   // 最后一个有效输出接收后的单周期完成脉冲
    output      logic               busy,             // 正在复位、输入或排空一帧
    output      logic               protocol_error,   // 帧标志或输出数量异常，粘滞有效
    output      logic               saturation_error  // 输出曾发生16位饱和，粘滞有效
);

    localparam int unsigned INDEX_WIDTH =
        (FRAME_SIZE <= 1) ? 1 : $clog2(FRAME_SIZE);
    localparam int unsigned RESET_COUNT_WIDTH =
        (RESET_CYCLES <= 1) ? 1 : $clog2(RESET_CYCLES);
    localparam logic [INDEX_WIDTH-1:0] LAST_INDEX =
        INDEX_WIDTH'(FRAME_SIZE - 1);
    localparam logic [RESET_COUNT_WIDTH-1:0] RESET_LAST =
        RESET_COUNT_WIDTH'(RESET_CYCLES - 1);
    localparam int unsigned COEF_FRACTION_BITS = 19;

    typedef enum logic [1:0] {
        STATE_RESET_FIR,
        STATE_WAIT_FIRST,
        STATE_STREAM,
        STATE_DRAIN
    } state_t;

    state_t state;

    logic [INDEX_WIDTH-1:0]       input_index;
    logic [INDEX_WIDTH-1:0]       output_index;
    logic [RESET_COUNT_WIDTH-1:0] reset_count;

    logic        ip_aresetn;
    logic        ip_input_valid;
    wire  logic  ip_input_ready;
    wire  logic  ip_output_valid;
    wire  logic [39:0] ip_output_data;

    logic input_fire;
    logic output_fire;
    logic input_enabled;
    logic saturation_now;
    logic signed [40:0] raw_extended;
    logic signed [40:0] rounded_value;
    logic signed [40:0] scaled_value;

    initial begin
        assert (FRAME_SIZE > 0)
            else $fatal(1, "fir_wrap: FRAME_SIZE必须大于0");
        assert (RESET_CYCLES >= 2)
            else $fatal(1, "fir_wrap: RESET_CYCLES必须至少为2");
    end

    always_comb begin
        input_enabled = (state == STATE_WAIT_FIRST) || (state == STATE_STREAM);

        // IP复位在系统复位或帧间复位状态下拉低；释放后由AXI ready决定吞吐率。
        ip_aresetn    = !rst && (state != STATE_RESET_FIR);
        ip_input_valid = !rst && input_enabled && fir_valid;
        fir_ready      = !rst && input_enabled && ip_input_ready;
        input_fire     = ip_input_valid && ip_input_ready;

        // IP没有输出反压端口，任何有效输出都必须在当前周期被接收。
        output_fire = !rst
                   && ((state == STATE_STREAM) || (state == STATE_DRAIN))
                   && ip_output_valid;

        sample_valid = output_fire;
        sample_first = output_fire && (output_index == '0);
        sample_last  = output_fire && (output_index == LAST_INDEX);
        busy         = (state != STATE_WAIT_FIRST);

        // 40位AXI数据为36位有效结果的符号扩展。负数采用2^(F-1)-1偏置，
        // 正数采用2^(F-1)偏置，实现关于零对称的最近值舍入。
        raw_extended = {ip_output_data[39], ip_output_data};
        if (raw_extended < 0) begin
            rounded_value = raw_extended
                          + ((41'sd1 <<< (COEF_FRACTION_BITS - 1)) - 1);
        end else begin
            rounded_value = raw_extended
                          + (41'sd1 <<< (COEF_FRACTION_BITS - 1));
        end
        scaled_value = rounded_value >>> COEF_FRACTION_BITS;

        saturation_now = 1'b0;
        sample_data     = 16'sd0;
        if (output_fire) begin
            if (scaled_value > 41'sd32767) begin
                sample_data     = 16'sh7fff;
                saturation_now = 1'b1;
            end else if (scaled_value < -41'sd32768) begin
                sample_data     = 16'sh8000;
                saturation_now = 1'b1;
            end else begin
                sample_data = scaled_value[15:0];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state            <= STATE_RESET_FIR;
            input_index      <= '0;
            output_index     <= '0;
            reset_count      <= '0;
            fir_frame_done   <= 1'b0;
            protocol_error   <= 1'b0;
            saturation_error <= 1'b0;
        end else begin
            fir_frame_done <= 1'b0;

            if (clear_error) begin
                protocol_error   <= 1'b0;
                saturation_error <= 1'b0;
            end

            unique case (state)
                STATE_RESET_FIR: begin
                    input_index  <= '0;
                    output_index <= '0;
                    if (reset_count == RESET_LAST) begin
                        reset_count <= '0;
                        state       <= STATE_WAIT_FIRST;
                    end else begin
                        reset_count <= reset_count + 1'b1;
                    end
                end

                STATE_WAIT_FIRST: begin
                    input_index  <= '0;
                    output_index <= '0;

                    // 正常复位释放后不应残留任何旧帧输出。
                    if (ip_output_valid) begin
                        protocol_error <= 1'b1;
                    end

                    if (input_fire) begin
                        if (!fir_first || (fir_last != (FRAME_SIZE == 1))) begin
                            protocol_error <= 1'b1;
                        end

                        if (FRAME_SIZE == 1) begin
                            input_index <= '0;
                            state       <= STATE_DRAIN;
                        end else begin
                            input_index <= INDEX_WIDTH'(1);
                            state       <= STATE_STREAM;
                        end
                    end
                end

                STATE_STREAM: begin
                    if (input_fire) begin
                        if (fir_first || (fir_last != (input_index == LAST_INDEX))) begin
                            protocol_error <= 1'b1;
                        end

                        if (input_index == LAST_INDEX) begin
                            input_index <= '0;
                            state       <= STATE_DRAIN;
                        end else begin
                            input_index <= input_index + 1'b1;
                        end
                    end
                end

                STATE_DRAIN: begin
                    // 等待最后一个输出，输入接口在本状态保持反压。
                    input_index <= '0;
                end

                default: begin
                    state          <= STATE_RESET_FIR;
                    input_index    <= '0;
                    output_index   <= '0;
                    reset_count    <= '0;
                    protocol_error <= 1'b1;
                end
            endcase

            if (output_fire) begin
                if (saturation_now) begin
                    saturation_error <= 1'b1;
                end

                if (output_index == LAST_INDEX) begin
                    // 最终输出正常情况下只能在全部输入已经接收后的排空状态出现。
                    if (state != STATE_DRAIN) begin
                        protocol_error <= 1'b1;
                    end
                    output_index   <= '0;
                    fir_frame_done <= 1'b1;
                    reset_count    <= '0;
                    state          <= STATE_RESET_FIR;
                end else begin
                    output_index <= output_index + 1'b1;
                end
            end
        end
    end

    fir_compiler_0 u_fir_compiler (
        .aresetn           (ip_aresetn),
        .aclk              (clk),
        .s_axis_data_tvalid(ip_input_valid),
        .s_axis_data_tready(ip_input_ready),
        .s_axis_data_tdata (fir_data),
        .m_axis_data_tvalid(ip_output_valid),
        .m_axis_data_tdata (ip_output_data)
    );

endmodule

`default_nettype wire
