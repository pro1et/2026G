`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：dac_output
//
// 主要功能：
//   驱动 ATK_DUAL_HS_DA 板上的两颗 3PD5651E DAC。模块接收两路 16 位有符号
//   二进制补码样点，将其饱和到 adc_capture 的有效数值范围 -512～+511，再转换
//   为 DAC 所需的 10 位无符号码。转换同时补偿扩展板模拟输出级的反相特性，使
//   输入数值的正负方向与最终模拟电压的正负方向一致。
//
// 使用方法：
//   1. 将 clk 连接到生成待输出样点的接口时钟。
//   2. 将 clk_drive 连接到与 clk 同频同相的 DAC 驱动时钟。
//   3. 将 rst 连接到 clk 时钟域的高有效同步复位。
//   4. 将两路 16 位有符号样点和共同的 in_valid 连接到本模块。
//   5. 将 dac_clk_a/dac_clk_b 和 dac_data_a/dac_data_b 连接到扩展板两路接口。
//
// 连接说明：
//   clk        <- clock_tree 输出的 DAC 接口时钟
//   clk_drive  <- clock_tree 中与 clk 同频同相的 DAC 驱动时钟
//   rst        <- clk 域高有效复位
//   data_a     <- 待观察信号的通道 1 样点
//   data_b     <- 待观察信号的通道 2 样点
//   in_valid   <- 上游双通道样点有效信号
//   dac_clk_a  -> DAC 通道 1 的 CLK
//   dac_clk_b  -> DAC 通道 2 的 CLK
//   dac_data_a -> DAC 通道 1 的 D0～D9，位 9 为最高位
//   dac_data_b -> DAC 通道 2 的 D0～D9，位 9 为最高位
//
// 时钟与复位：
//   数据寄存器工作在 clk 上升沿。clk_drive 必须与 clk 同频同相；ODDR 将
//   clk_drive 反相转发，使 DAC 时钟上升沿位于内部时钟下降沿，为上升沿更新的
//   数据提供半个周期的建立时间。rst 为高有效同步复位，ODDR 使用异步复位，
//   因而复位时会立即把外部 DAC 时钟保持为低电平。
//
// 输入格式：
//   data_a、data_b 为 16 位有符号二进制补码整数。与 adc_capture 直接连接时，
//   有效范围是 -512～+511；超出该范围的调试信号会在本模块内饱和而不回绕。
//
// 输出格式：
//   dac_data_a、dac_data_b 为 10 位 DAC 原始码。根据扩展板说明，原始码 0、
//   1023 分别产生约 +5 V、-5 V，因此转换采用 raw_code = 511 - signed_code：
//   输入 -512、0、+511 分别映射为 1023、511、0。零点位于两个中间码之间，
//   选用 511 作为复位和零输入的输出码。
//
// 握手时序：
//   本接口无反压。in_valid 为高时，两路数据在同一个 clk 上升沿被接收，并在随后
//   的 DAC 时钟上升沿锁存；从接收到模拟更新的数字接口延迟为半个 clk 周期。
//   in_valid 为低时保持上一组输出，但 DAC 仍按连续时钟重复锁存该数值。
//
// 参数说明：
//   本模块的数据输入固定为 16 位，DAC 输出固定为器件要求的 10 位。
//
// 错误行为：
//   输入超出 -512～+511 时分别饱和为对应端点。复位期间输出零点码并停止 DAC
//   时钟；模块不检测扩展板断开、模拟过载或外部时钟布线错误。
//
// 使用限制：
//   仅适用于 Xilinx 7 系列 ODDR 原语和 3PD5651E 接口。DAC 时钟不得超过
//   125 MHz。clk 与 clk_drive 的频率或相位关系改变后必须重新检查输出时序。
// ============================================================================

module dac_output (
    input  wire logic               clk,         // DAC 数据接口时钟，数据在上升沿接收
    input  wire logic               clk_drive,   // DAC 驱动时钟，必须与 clk 同频同相
    input  wire logic               rst,         // clk 域高有效同步复位

    input  wire logic signed [15:0] data_a,      // 通道 1 有符号二补码样点，有效范围 -512～+511
    input  wire logic signed [15:0] data_b,      // 通道 2 有符号二补码样点，有效范围 -512～+511
    input  wire logic               in_valid,    // 双通道输入有效，高电平时在 clk 上升沿接收

    output wire logic               dac_clk_a,   // 通道 1 DAC 时钟，上升沿锁存 dac_data_a
    output wire logic               dac_clk_b,   // 通道 2 DAC 时钟，上升沿锁存 dac_data_b
    output wire logic [9:0]         dac_data_a,  // 通道 1 DAC 原始码，0 对应约 +5 V
    output wire logic [9:0]         dac_data_b   // 通道 2 DAC 原始码，1023 对应约 -5 V
);

    localparam logic [9:0] DAC_ZERO_CODE = 10'd511;

    (* IOB = "TRUE" *) logic [9:0] dac_data_reg_a;
    (* IOB = "TRUE" *) logic [9:0] dac_data_reg_b;

    // 先饱和再转换，防止超出 10 位有符号范围的调试信号在 DAC 端发生回绕。
    function automatic logic [9:0] to_dac_code(input logic signed [15:0] sample);
        begin
            if (sample < -16'sd512) begin
                to_dac_code = 10'd1023;
            end else if (sample > 16'sd511) begin
                to_dac_code = 10'd0;
            end else begin
                // 511-sample 同时完成有符号码转换和板级模拟极性补偿。
                to_dac_code = 10'(16'sd511 - sample);
            end
        end
    endfunction

    assign dac_data_a = dac_data_reg_a;
    assign dac_data_b = dac_data_reg_b;

    // D1=0、D2=1 生成反相转发时钟；数据在 clk 上升沿更新，DAC 在半周期后的
    // 外部上升沿锁存，从而避免数据变化沿与 DAC 捕获沿重合。
    ODDR #(
        .DDR_CLK_EDGE("OPPOSITE_EDGE"),
        .INIT        (1'b0),
        .SRTYPE      ("ASYNC")
    ) u_oddr_clk_a (
        .Q (dac_clk_a),
        .C (clk_drive),
        .CE(1'b1),
        .D1(1'b0),
        .D2(1'b1),
        .R (rst),
        .S (1'b0)
    );

    ODDR #(
        .DDR_CLK_EDGE("OPPOSITE_EDGE"),
        .INIT        (1'b0),
        .SRTYPE      ("ASYNC")
    ) u_oddr_clk_b (
        .Q (dac_clk_b),
        .C (clk_drive),
        .CE(1'b1),
        .D1(1'b0),
        .D2(1'b1),
        .R (rst),
        .S (1'b0)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            dac_data_reg_a <= DAC_ZERO_CODE;
            dac_data_reg_b <= DAC_ZERO_CODE;
        end else if (in_valid) begin
            dac_data_reg_a <= to_dac_code(data_a);
            dac_data_reg_b <= to_dac_code(data_b);
        end
    end

endmodule

`default_nettype wire

