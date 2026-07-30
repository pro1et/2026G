`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：mean_square_calculator
//
// 主要功能：
//   对每帧65536个16位有符号交流采样值逐点平方并累加，在帧末计算均方值。
//   本模块不计算直流分量、不执行去直流处理，也不计算平方根。
//
// 使用方法：
//   1. 将已经完成码制转换和去直流处理的采样流连接到sample_in/sample_valid。
//   2. 在每帧第一个和最后一个有效样点分别拉高sample_first和sample_last。
//   3. 在result_valid为高的周期采集mean_square_out和overflow。
//   4. 可将mean_square_out/result_valid直接连接到measurement_bram_writer的
//      vrms_data/vrms_valid；此时BRAM地址0x0004保存的是均方值而不是平方根结果。
//
// 连接说明：
//   clk             <- 数据处理时钟
//   rst             <- 本时钟域高电平有效同步复位
//   sample_*        <- 上游码制转换及去直流模块
//   mean_square_out -> PS结果通路或measurement_bram_writer.vrms_data
//   result_valid    -> 下游结果有效输入或measurement_bram_writer.vrms_valid
//   overflow        -> 状态监控逻辑，与mean_square_out对应并保持到下一帧结果
//
// 时钟与复位：
//   所有端口均属于clk域。rst为高电平有效同步复位；复位会丢弃未完成帧，清零
//   累加器、计数器、输出和有效脉冲。异步来源必须在模块外完成CDC。
//
// 输入格式：
//   sample_in为16位有符号二进制补码，范围-32768至32767。仅sample_valid为高时
//   接收一个样点；无效周期的sample_in和帧标志均被忽略。每帧必须恰有65536个
//   有效样点，sample_first/sample_last必须与第0/65535号有效样点对齐。
//
// 输出格式：
//   mean_square_out为32位无符号整数，计算式为
//   (一帧平方和 + 2^15) >> 16，采用正数四舍五入，不执行平方根。result_valid
//   严格持续一个clk周期；mean_square_out和overflow保持到下一帧结果产生。
//
// 握手时序：
//   本模块没有ready和背压，每个clk最多接收一个有效样点。帧边界由有效样点计数
//   唯一确定，sample_valid中的任意空拍不会推进计数。第65536个有效样点所在时钟沿
//   同时计入最终结果；下一时钟可无空拍接收下一帧第一个样点。
//
// 参数说明：
//   帧长固定为65536，即2^16，因此除法固定使用右移16位，不提供可变帧长参数。
//
// 错误行为：
//   overflow为本次输出结果的异常标志：48位平方和发生进位，或sample_first/
//   sample_last与固定帧边界不一致时置1。错误不会停止数据流；仍按每65536个有效
//   样点产生结果。合法16位输入的最大平方和为2^46，正常情况下不会算术溢出。
//
// 使用限制：
//   上游必须保证每帧数据已经去除直流分量。本模块不提供结果背压，下游必须在
//   result_valid周期接收结果或利用输出保持特性稍后读取。跨时钟连接必须在外部
//   使用能够同时保护32位数据和有效事件的CDC结构。
// ============================================================================

module mean_square_calculator (
    input  wire logic               clk,             // 模块工作时钟，所有端口均属于此时钟域
    input  wire logic               rst,             // 高电平有效同步复位

    input  wire logic signed [15:0] sample_in,       // 16位有符号二进制补码采样值
    input  wire logic               sample_valid,    // 样点有效，高电平周期接收一个样点
    input  wire logic               sample_first,    // 本帧第一个有效样点标志，须与sample_valid同时有效
    input  wire logic               sample_last,     // 本帧最后一个有效样点标志，须与sample_valid同时有效

    output      logic [31:0]        mean_square_out, // 32位无符号均方值，保持到下一帧结果
    output      logic               result_valid,    // 新结果有效脉冲，严格持续一个clk周期
    output      logic               overflow         // 当前输出帧的算术或帧边界异常标志
);

    localparam logic [48:0] ROUNDING_BIAS = 49'd32768; // 除以2^16前加入的0.5 LSB舍入量

    logic [15:0] sample_magnitude;  // 输入的无符号绝对值，能够表示|-32768|=32768
    logic [31:0] magnitude_extended; // 绝对值零扩展到32位，明确乘法表达式位宽
    logic [31:0] sample_square;      // 单点平方，无符号，最大值为2^30

    logic [47:0] square_sum;             // 当前帧已接收样点的48位无符号平方和
    logic [15:0] sample_count;           // 当前有效样点序号，范围0至65535
    logic        frame_fault;            // 当前帧此前已检测到的异常状态

    logic [48:0] sum_with_sample;         // 包含当前样点的49位平方和，用于保留进位
    logic [48:0] rounded_sum;             // 加入舍入量后的49位帧末平方和
    logic        marker_fault;            // 当前样点的首尾标志与固定位置不一致

    always_comb begin
        // 先求二进制补码绝对值再零扩展相乘，明确覆盖-32768的平方边界。
        sample_magnitude  = sample_in[15]
                          ? (~sample_in[15:0] + 16'd1)
                          : sample_in[15:0];
        magnitude_extended = {16'd0, sample_magnitude};
        sample_square      = magnitude_extended * magnitude_extended;

        // 两个操作数均显式扩展到49位，最高位用于检测48位累加器进位。
        sum_with_sample = {1'b0, square_sum} + {17'd0, sample_square};
        rounded_sum     = sum_with_sample + ROUNDING_BIAS;

        // 帧标志仅校验协议，不参与计数和运算，保证空拍及错误标志不会改变帧长度。
        marker_fault = (sample_first != (sample_count == 16'h0000)) ||
                       (sample_last  != (sample_count == 16'hffff));
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            square_sum      <= 48'd0;
            sample_count    <= 16'd0;
            frame_fault     <= 1'b0;
            mean_square_out <= 32'd0;
            result_valid    <= 1'b0;
            overflow        <= 1'b0;
        end else begin
            // 默认撤销结果脉冲；数值输出和结果异常标志保持稳定。
            result_valid <= 1'b0;

            if (sample_valid) begin
                if (sample_count == 16'hffff) begin
                    // 必须使用包含当前样点的组合和值，防止非阻塞赋值漏算最后一点。
                    mean_square_out <= rounded_sum[47:16];
                    result_valid    <= 1'b1;
                    overflow        <= frame_fault || marker_fault ||
                                       sum_with_sample[48] || rounded_sum[48];

                    // 同一时钟沿完成旧帧并清空工作寄存器，下一周期可接收连续新帧。
                    square_sum   <= 48'd0;
                    sample_count <= 16'd0;
                    frame_fault  <= 1'b0;
                end else begin
                    square_sum   <= sum_with_sample[47:0];
                    sample_count <= sample_count + 1'b1;
                    frame_fault  <= frame_fault || marker_fault || sum_with_sample[48];
                end
            end
        end
    end

endmodule

`default_nettype wire
