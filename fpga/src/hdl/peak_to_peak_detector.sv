`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：peak_to_peak_detector
//
// 主要功能：
//   将一帧有效采样划分为固定数量的等长分段，分别计算各段最大值与最小值之差，
//   删除指定数量的最大、最小分段峰峰值后，对剩余结果进行四舍五入平均。本模块
//   只负责峰峰值计算，不控制BRAM、不换算电压，也不产生系统frame_done。
//
// 使用方法：
//   1. 将FIR的有符号输出流连接到sample_data/sample_valid。
//   2. 在一帧第一个、最后一个有效样点分别拉高sample_first/sample_last。
//   3. 在vpp_valid为高的周期采集vpp_out；vpp_error供顶层监控帧协议。
//   4. 可将vpp_out/vpp_valid直接连接到measurement_bram_writer的
//      vpp_data/vpp_valid，写控制器应在结果到达前已经进入busy状态。
//
// 连接说明：
//   clk          <- FIR数据处理时钟
//   rst          <- 本时钟域高电平有效同步复位
//   sample_*     <- FIR输出及其有效、帧边界信号
//   vpp_out      -> measurement_bram_writer.vpp_data或其他结果通路
//   vpp_valid    -> measurement_bram_writer.vpp_valid或其他结果有效输入
//   vpp_busy     -> 顶层测量流程状态监控
//   vpp_error    -> 顶层协议错误监控
//
// 时钟与复位：
//   所有端口均属于clk域。rst为高电平有效同步复位；复位丢弃未完成帧并清零所有
//   计数器、统计量和输出脉冲。异步来源必须在模块外完成CDC。
//
// 输入格式：
//   sample_data为DATA_WIDTH位有符号二进制补码。仅sample_valid为高时接收一个
//   样点；无效周期不推进分段或帧计数。sample_first/sample_last必须分别与一帧
//   第一个、最后一个有效样点对齐，但不参与算术帧边界的形成。
//
// 输出格式：
//   vpp_out为32位无符号整数，数值尺度与sample_data一致。每段峰峰值范围为0至
//   2^DATA_WIDTH-1；最终结果采用(trimmed_sum + retained_count/2)/retained_count
//   的正数四舍五入。vpp_valid和vpp_error均为严格单周期脉冲，vpp_out保持到
//   下一帧结果产生。
//
// 握手时序：
//   本模块没有ready和背压，每clk最多接收一个有效样点。vpp_busy在接受一帧首个
//   有效点后拉高，在接受最后一个有效点并产生vpp_valid后拉低。最后一个样点会先
//   更新所在分段极值，再参与截尾平均；下一时钟可无空拍接收下一帧首个样点。
//
// 参数说明：
//   DATA_WIDTH    为输入位宽，范围2至32。
//   FRAME_SIZE    为每帧有效样点数，必须等于SEGMENT_COUNT*SEGMENT_SIZE。
//   SEGMENT_COUNT 为分段数量，必须大于2*TRIM_COUNT。
//   SEGMENT_SIZE  为每段有效样点数，必须大于0。
//   TRIM_COUNT    为最大端和最小端各删除的分段数量，必须大于0。
//
// 错误行为：
//   sample_first或sample_last与固定计数边界不一致时，vpp_error拉高一个周期；
//   模块仍按固定有效样点数继续计算，以免错误标志改变数据通路时序。复位是丢弃
//   未完成帧的唯一方式。
//
// 使用限制：
//   参数在 elaboration 阶段进行合法性检查。除法的除数由参数确定，综合器会实现
//   常数除法；默认除数为12。本模块不缓存多个输出，下游必须捕获vpp_valid，或者
//   在同一时钟域利用vpp_out的保持特性读取最新结果。
// ============================================================================

module peak_to_peak_detector #(
    parameter int unsigned DATA_WIDTH    = 16,    // 输入有符号样点位宽，范围2至32
    parameter int unsigned FRAME_SIZE    = 65536, // 每帧有效样点数
    parameter int unsigned SEGMENT_COUNT = 16,    // 每帧分段数量
    parameter int unsigned SEGMENT_SIZE  = 4096,  // 每段有效样点数
    parameter int unsigned TRIM_COUNT    = 2      // 最大端和最小端各删除的分段数量
) (
    input  wire logic                         clk,          // 模块工作时钟，所有端口均属于此时钟域
    input  wire logic                         rst,          // 高电平有效同步复位

    input  wire logic signed [DATA_WIDTH-1:0] sample_data,  // FIR有符号二进制补码输出样点
    input  wire logic                         sample_valid, // 样点有效，高电平周期接收一个样点
    input  wire logic                         sample_first, // 一帧第一个有效样点标志
    input  wire logic                         sample_last,  // 一帧最后一个有效样点标志

    output      logic [31:0]                  vpp_out,      // 32位无符号截尾平均峰峰值，保持至下次结果
    output      logic                         vpp_valid,    // 新峰峰值结果有效脉冲，严格持续一个clk周期
    output      logic                         vpp_busy,     // 当前正在接收和统计一帧数据
    output      logic                         vpp_error     // 当前周期检测到帧首尾标志位置错误
);

    localparam int unsigned VPP_WIDTH = DATA_WIDTH;
    localparam int unsigned SUM_WIDTH = DATA_WIDTH + $clog2(SEGMENT_COUNT);
    localparam int unsigned SEGMENT_SAMPLE_INDEX_WIDTH =
        (SEGMENT_SIZE <= 1) ? 1 : $clog2(SEGMENT_SIZE);
    localparam int unsigned SEGMENT_INDEX_WIDTH =
        (SEGMENT_COUNT <= 1) ? 1 : $clog2(SEGMENT_COUNT);
    localparam int unsigned RETAINED_COUNT = SEGMENT_COUNT - (2 * TRIM_COUNT);

    localparam logic [SEGMENT_SAMPLE_INDEX_WIDTH-1:0] LAST_SEGMENT_SAMPLE =
        SEGMENT_SAMPLE_INDEX_WIDTH'(SEGMENT_SIZE - 1);
    localparam logic [SEGMENT_INDEX_WIDTH-1:0] LAST_SEGMENT =
        SEGMENT_INDEX_WIDTH'(SEGMENT_COUNT - 1);

    logic [SEGMENT_SAMPLE_INDEX_WIDTH-1:0] segment_sample_index; // 当前样点在分段内的序号
    logic [SEGMENT_INDEX_WIDTH-1:0]        segment_index;        // 当前分段序号
    logic signed [DATA_WIDTH-1:0]          segment_max;          // 当前分段此前样点最大值
    logic signed [DATA_WIDTH-1:0]          segment_min;          // 当前分段此前样点最小值

    logic [SUM_WIDTH-1:0] vpp_sum; // 已完成分段峰峰值总和，不含当前未完成分段
    logic [VPP_WIDTH-1:0] largest_vpp [0:TRIM_COUNT-1]; // 已完成分段中从大到小的前TRIM_COUNT项
    logic [VPP_WIDTH-1:0] smallest_vpp[0:TRIM_COUNT-1]; // 已完成分段中从小到大的前TRIM_COUNT项

    logic signed [DATA_WIDTH-1:0] segment_max_with_sample; // 包含当前样点的分段最大值
    logic signed [DATA_WIDTH-1:0] segment_min_with_sample; // 包含当前样点的分段最小值
    logic signed [DATA_WIDTH:0]   segment_max_extended;    // 为差值运算增加符号保护位
    logic signed [DATA_WIDTH:0]   segment_min_extended;    // 为差值运算增加符号保护位
    logic signed [DATA_WIDTH:0]   segment_difference;      // 完整有符号差值，结果恒非负
    logic        [VPP_WIDTH-1:0]  completed_segment_vpp;   // 包含当前样点的分段峰峰值

    logic [VPP_WIDTH-1:0] largest_next [0:TRIM_COUNT-1]; // 插入当前分段后的最大项集合
    logic [VPP_WIDTH-1:0] smallest_next[0:TRIM_COUNT-1]; // 插入当前分段后的最小项集合
    logic [VPP_WIDTH-1:0] largest_carry;
    logic [VPP_WIDTH-1:0] smallest_carry;
    logic [VPP_WIDTH-1:0] swap_value;

    logic [SUM_WIDTH-1:0] total_sum_next;       // 加入当前完成分段后的总和
    logic [SUM_WIDTH-1:0] trimmed_sum_next;     // 删除两端极值后的分段峰峰值总和
    logic [SUM_WIDTH:0]   rounded_numerator;    // 加入半个除数后的舍入分子
    logic [SUM_WIDTH:0]   rounded_quotient;     // 常数除法后的完整商
    logic                  marker_fault;        // 当前有效样点的帧标志位置错误

    integer comb_index;
    integer seq_index;

    initial begin
        assert (DATA_WIDTH >= 2 && DATA_WIDTH <= 32)
            else $fatal(1, "DATA_WIDTH必须在2至32之间");
        assert (SEGMENT_COUNT > 0 && SEGMENT_SIZE > 0)
            else $fatal(1, "SEGMENT_COUNT和SEGMENT_SIZE必须大于0");
        assert (TRIM_COUNT > 0 && SEGMENT_COUNT > (2 * TRIM_COUNT))
            else $fatal(1, "TRIM_COUNT必须大于0且SEGMENT_COUNT必须大于2*TRIM_COUNT");
        assert (FRAME_SIZE == SEGMENT_COUNT * SEGMENT_SIZE)
            else $fatal(1, "FRAME_SIZE必须等于SEGMENT_COUNT*SEGMENT_SIZE");
    end

    always_comb begin
        // 分段第一个有效样点直接作为初始极值，其余样点再与寄存极值比较。
        if (segment_sample_index == '0) begin
            segment_max_with_sample = sample_data;
            segment_min_with_sample = sample_data;
        end else begin
            segment_max_with_sample = (sample_data > segment_max) ? sample_data : segment_max;
            segment_min_with_sample = (sample_data < segment_min) ? sample_data : segment_min;
        end

        // 符号扩展后做减法，避免32767-(-32768)在DATA_WIDTH位内溢出。
        segment_max_extended = {segment_max_with_sample[DATA_WIDTH-1], segment_max_with_sample};
        segment_min_extended = {segment_min_with_sample[DATA_WIDTH-1], segment_min_with_sample};
        segment_difference   = segment_max_extended - segment_min_extended;
        completed_segment_vpp = segment_difference[VPP_WIDTH-1:0];

        // 将当前分段峰峰值插入最大项列表，列表始终保持从大到小。
        for (comb_index = 0; comb_index < TRIM_COUNT; comb_index = comb_index + 1) begin
            largest_next[comb_index] = largest_vpp[comb_index];
        end
        swap_value    = '0;
        largest_carry = completed_segment_vpp;
        for (comb_index = 0; comb_index < TRIM_COUNT; comb_index = comb_index + 1) begin
            if (largest_carry > largest_next[comb_index]) begin
                swap_value                   = largest_next[comb_index];
                largest_next[comb_index]      = largest_carry;
                largest_carry                 = swap_value;
            end
        end

        // 将当前分段峰峰值插入最小项列表，列表始终保持从小到大。
        for (comb_index = 0; comb_index < TRIM_COUNT; comb_index = comb_index + 1) begin
            smallest_next[comb_index] = smallest_vpp[comb_index];
        end
        smallest_carry = completed_segment_vpp;
        for (comb_index = 0; comb_index < TRIM_COUNT; comb_index = comb_index + 1) begin
            if (smallest_carry < smallest_next[comb_index]) begin
                swap_value                    = smallest_next[comb_index];
                smallest_next[comb_index]      = smallest_carry;
                smallest_carry                 = swap_value;
            end
        end

        total_sum_next = vpp_sum + SUM_WIDTH'(completed_segment_vpp);
        trimmed_sum_next = total_sum_next;
        for (comb_index = 0; comb_index < TRIM_COUNT; comb_index = comb_index + 1) begin
            trimmed_sum_next = trimmed_sum_next
                             - SUM_WIDTH'(largest_next[comb_index])
                             - SUM_WIDTH'(smallest_next[comb_index]);
        end

        rounded_numerator = {1'b0, trimmed_sum_next} + (RETAINED_COUNT / 2);
        rounded_quotient  = rounded_numerator / RETAINED_COUNT;

        marker_fault = (sample_first != ((segment_index == '0) &&
                                         (segment_sample_index == '0))) ||
                       (sample_last  != ((segment_index == LAST_SEGMENT) &&
                                         (segment_sample_index == LAST_SEGMENT_SAMPLE)));
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            segment_sample_index <= '0;
            segment_index        <= '0;
            segment_max          <= '0;
            segment_min          <= '0;
            vpp_sum              <= '0;
            vpp_out              <= 32'd0;
            vpp_valid            <= 1'b0;
            vpp_busy             <= 1'b0;
            vpp_error            <= 1'b0;

            for (seq_index = 0; seq_index < TRIM_COUNT; seq_index = seq_index + 1) begin
                largest_vpp[seq_index]  <= '0;
                smallest_vpp[seq_index] <= {VPP_WIDTH{1'b1}};
            end
        end else begin
            vpp_valid <= 1'b0;
            vpp_error <= sample_valid && marker_fault;

            if (sample_valid) begin
                if ((segment_index == '0) && (segment_sample_index == '0)) begin
                    vpp_busy <= 1'b1;
                end

                if (segment_sample_index == LAST_SEGMENT_SAMPLE) begin
                    segment_sample_index <= '0;
                    segment_max          <= '0;
                    segment_min          <= '0;

                    if (segment_index == LAST_SEGMENT) begin
                        // 组合路径已包含当前帧最后一点和第16段，直接输出并清空下一帧状态。
                        vpp_out   <= {{(32-VPP_WIDTH){1'b0}}, rounded_quotient[VPP_WIDTH-1:0]};
                        vpp_valid <= 1'b1;
                        vpp_busy  <= 1'b0;

                        segment_index <= '0;
                        vpp_sum       <= '0;
                        for (seq_index = 0; seq_index < TRIM_COUNT; seq_index = seq_index + 1) begin
                            largest_vpp[seq_index]  <= '0;
                            smallest_vpp[seq_index] <= {VPP_WIDTH{1'b1}};
                        end
                    end else begin
                        segment_index <= segment_index + 1'b1;
                        vpp_sum       <= total_sum_next;
                        for (seq_index = 0; seq_index < TRIM_COUNT; seq_index = seq_index + 1) begin
                            largest_vpp[seq_index]  <= largest_next[seq_index];
                            smallest_vpp[seq_index] <= smallest_next[seq_index];
                        end
                    end
                end else begin
                    segment_sample_index <= segment_sample_index + 1'b1;
                    segment_max          <= segment_max_with_sample;
                    segment_min          <= segment_min_with_sample;
                end
            end
        end
    end

endmodule

`default_nettype wire
