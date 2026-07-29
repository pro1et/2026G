`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：adc_capture
//
// 主要功能：
//   驱动 ATK_DUAL_HS_AD 板上的两颗 3PA1030 ADC，并连续采集两路 10 位并行
//   数据。本模块仅负责物理接口时序和输入寄存，不执行码制转换、滤波或缓存。
//
// 使用方法：
//   1. 将 clk 连接到统一时钟树输出的 30 MHz ADC 捕获时钟。
//   2. 将 clk_drive 连接到与 clk 同频同相的 ADC 驱动时钟。
//   3. 将 rst 连接到 clk 时钟域的高有效同步复位。
//   4. 将 adc_clk_a/adc_clk_b、adc_oe_a/adc_oe_b 和两路数据总线连接到
//      GPIO2 转接板对应的 CLK_1/CLK_2、OE_1/OE_2 和 D0~D9。
//   5. out_valid 为高时，下游在每个 clk 上升沿接收 data_a 和 data_b。
//
// 连接说明：
//   clk        <- clock_tree 的 30 MHz ADC 时钟输出
//   clk_drive  <- clock_tree 与 clk 同频同相的 30 MHz ADC 驱动时钟输出
//   rst        <- clock_tree 的 30 MHz 域高有效复位输出
//   adc_data_a <- ADC 通道 1 的 D0_1~D9_1；D9 为最高位
//   adc_data_b <- ADC 通道 2 的 D0_2~D9_2；D9 为最高位
//   adc_clk_a  -> ADC 通道 1 的 CLK_1
//   adc_clk_b  -> ADC 通道 2 的 CLK_2
//   adc_oe_a   -> ADC 通道 1 的 OE_1，高电平关闭数据输出
//   adc_oe_b   -> ADC 通道 2 的 OE_2，高电平关闭数据输出
//   data_a     -> 下游预处理或缓存模块的通道 1 数据输入
//   data_b     -> 下游预处理或缓存模块的通道 2 数据输入
//   out_valid  -> 下游模块的数据有效输入
//
// 时钟与复位：
//   所有内部逻辑工作在 clk 域。ODDR 仅将 clk_drive 转发到 ADC，不产生新频率。
//   clk_drive 与 clk 必须同频同相。外部转发时钟经过 ODDR 和输出缓冲后到达 ADC，
//   因而 ADC 在内部捕获沿之后才开始下一次转换，数据由下一个 clk 上升沿捕获。
//   rst 为高有效同步复位；ODDR 使用异步复位，以便复位时立即停止外部 ADC 时钟。
//
// 输入格式：
//   adc_data_a、adc_data_b 为 10 位无符号直二进制数。ATK_DUAL_HS_AD 模块
//   约将 -5 V 映射为 0、0 V 映射为 512、+5 V 映射为 1023。
//
// 输出格式：
//   data_a、data_b 保持 ADC 原始无符号直二进制编码，不在本模块内转换为补码。
//
// 握手时序：
//   本接口无反压。启动等待期结束后 out_valid 持续为高，每个 clk 周期输出一组
//   双通道样本；下游必须能够持续接收。
//
// 参数说明：
//   STARTUP_CYCLES 为解除复位后屏蔽输出有效的 clk 周期数，必须大于等于 1。
//   默认值 6 覆盖 3PA1030 的 4 周期流水线以及 FPGA 下一上升沿输入寄存。
//
// 错误行为：
//   转接板未引出 3PA1030 的 OTR 信号，本模块无法检测模拟输入过量程。复位期间
//   data_a、data_b 和 out_valid 清零，OE 拉高使 ADC 数据端口进入高阻态。
//
// 使用限制：
//   仅适用于 Xilinx 7 系列 ODDR 原语。3PA1030 时钟不得超过 50 MHz；若提高
//   频率、改变相位或改变 PCB/转接板，必须重新分析输入建立与保持时序。
// ============================================================================

module adc_capture #(
    parameter int unsigned STARTUP_CYCLES = 6  // 启动屏蔽周期数，单位为 clk 周期，必须大于等于 1
) (
    input  wire  logic       clk,         // ADC 接口捕获时钟，推荐 30 MHz，连续运行
    input  wire  logic       clk_drive,   // ADC 驱动时钟，与 clk 同频同相
    input  wire  logic       rst,         // clk 域高有效同步复位

    input  wire  logic [9:0] adc_data_a,  // 通道 1 原始并行数据，无符号直二进制，D9 为最高位
    input  wire  logic [9:0] adc_data_b,  // 通道 2 原始并行数据，无符号直二进制，D9 为最高位

    output wire  logic       adc_clk_a,   // 通道 1 ADC 转发时钟，与 clk_drive 同频同相
    output wire  logic       adc_clk_b,   // 通道 2 ADC 转发时钟，与 clk_drive 同频同相
    output wire  logic       adc_oe_a,    // 通道 1 输出控制，高电平为高阻、低电平正常输出
    output wire  logic       adc_oe_b,    // 通道 2 输出控制，高电平为高阻、低电平正常输出

    (* IOB = "TRUE" *) output logic [9:0] data_a, // 通道 1 输入 IOB 寄存采样值，无符号直二进制
    (* IOB = "TRUE" *) output logic [9:0] data_b, // 通道 2 输入 IOB 寄存采样值，无符号直二进制
    output       logic       out_valid    // 双通道输出有效，启动后持续为高，每周期一组
);

    localparam int unsigned COUNT_WIDTH = $clog2(STARTUP_CYCLES + 1);
    localparam logic [COUNT_WIDTH-1:0] STARTUP_COUNT_MAX = COUNT_WIDTH'(STARTUP_CYCLES);

    logic [COUNT_WIDTH-1:0] startup_count;

    initial begin
        assert (STARTUP_CYCLES >= 1)
            else $fatal(1, "STARTUP_CYCLES 必须大于等于 1");
    end

    // ODDR 保证转发时钟占空比由时钟树控制，并避免用普通逻辑产生外部时钟。
    ODDR #(
        .DDR_CLK_EDGE("OPPOSITE_EDGE"),
        .INIT        (1'b0),
        .SRTYPE      ("ASYNC")
    ) u_oddr_clk_a (
        .Q (adc_clk_a),
        .C (clk_drive),
        .CE(1'b1),
        .D1(1'b1),
        .D2(1'b0),
        .R (rst),
        .S (1'b0)
    );

    ODDR #(
        .DDR_CLK_EDGE("OPPOSITE_EDGE"),
        .INIT        (1'b0),
        .SRTYPE      ("ASYNC")
    ) u_oddr_clk_b (
        .Q (adc_clk_b),
        .C (clk_drive),
        .CE(1'b1),
        .D1(1'b1),
        .D2(1'b0),
        .R (rst),
        .S (1'b0)
    );

    // OE 高电平使 ADC 数据输出进入高阻态；复位释放后立即允许两路 ADC 输出。
    assign adc_oe_a = rst;
    assign adc_oe_b = rst;

    always_ff @(posedge clk) begin
        if (rst) begin
            data_a        <= 10'd0;
            data_b        <= 10'd0;
            startup_count <= '0;
            out_valid     <= 1'b0;
        end else begin
            // ADC 数据在前一个同名时钟上升沿之后变更，此处捕获上一稳定结果。
            data_a <= adc_data_a;
            data_b <= adc_data_b;

            if (startup_count < STARTUP_COUNT_MAX) begin
                startup_count <= startup_count + 1'b1;
            end

            if (startup_count == (STARTUP_COUNT_MAX - 1'b1)) begin
                out_valid <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
