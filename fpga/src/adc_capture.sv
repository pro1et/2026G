`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：adc_capture
//
// 主要功能：
//   为两片 ADS6149 转发采样时钟，并分别使用 ADC 返回时钟捕获两路14位并行
//   二进制补码数据。每路数据左移2位形成16位有符号输出。本模块不包含 FIFO、
//   跨时钟域、滤波、标定或通道合并逻辑。
//
// 连接说明：
//   clk_drive          <- 时钟树产生的32 MHz ADC驱动时钟；
//   adc_clk_a/b        -> ADC转接板两路采样时钟输入；
//   adc_clk_return_a/b <- ADC两路返回数据时钟，分别作为对应数据采集时钟；
//   adc_data_a/b       <- 按 AD_DA_Test 约束排列的14位ADC数据；
//   data_a/b           -> 外置异步FIFO的数据输入；
//   out_valid_a/b      -> 外置异步FIFO的写使能。
//
// 时钟与复位：
//   通道A、B分别工作在 adc_clk_return_a、adc_clk_return_b 时钟域。rst 对两个
//   返回时钟域异步置位，并在对应返回时钟恢复后经过两级寄存器同步释放。ODDR
//   使用 rst 异步停止外部采样时钟。
//
// 数据格式：
//   ADS6149 在 DFS=3/8 AVDD 时输出14位二进制补码，D13为符号位。转换规则为
//   data = $signed({raw_data[13:0], 2'b00})：
//     -8192 -> -32768，0 -> 0，8191 -> 32764。
//
// 握手时序：
//   每路解除复位后屏蔽 STARTUP_CYCLES 个返回时钟周期，随后对应 out_valid
//   持续为高，表示每个该路返回时钟上升沿均有一个有效样本。本接口无反压。
//
// 使用限制：
//   data_a/out_valid_a 与 data_b/out_valid_b 属于两个独立时钟域，禁止直接在
//   其他时钟域使用；必须分别进入以对应返回时钟为写时钟的外置异步 FIFO。
// ============================================================================

module adc_capture #(
    parameter int unsigned STARTUP_CYCLES = 8
) (
    input  wire logic clk_drive,
    input  wire logic rst,

    input  wire logic [13:0] adc_data_a,
    input  wire logic [13:0] adc_data_b,
    input  wire logic        adc_clk_return_a,
    input  wire logic        adc_clk_return_b,

    output wire logic adc_clk_a,
    output wire logic adc_clk_b,
    output      logic signed [15:0] data_a,
    output      logic signed [15:0] data_b,
    output      logic               out_valid_a,
    output      logic               out_valid_b
);

    localparam int unsigned COUNT_WIDTH =
        (STARTUP_CYCLES <= 1) ? 1 : $clog2(STARTUP_CYCLES + 1);
    localparam logic [COUNT_WIDTH-1:0] STARTUP_LAST =
        COUNT_WIDTH'(STARTUP_CYCLES - 1);

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] reset_sync_a;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] reset_sync_b;
    wire logic reset_a = reset_sync_a[1];
    wire logic reset_b = reset_sync_b[1];

    logic [COUNT_WIDTH-1:0] startup_count_a;
    logic [COUNT_WIDTH-1:0] startup_count_b;

    initial begin
        assert (STARTUP_CYCLES >= 1)
            else $fatal(1, "STARTUP_CYCLES 必须大于等于 1");
    end

    // 返回时钟在系统复位期间可能停止，因此采用异步置位、同步释放。
    always_ff @(posedge adc_clk_return_a or posedge rst) begin
        if (rst) begin
            reset_sync_a <= 2'b11;
        end else begin
            reset_sync_a <= {reset_sync_a[0], 1'b0};
        end
    end

    always_ff @(posedge adc_clk_return_b or posedge rst) begin
        if (rst) begin
            reset_sync_b <= 2'b11;
        end else begin
            reset_sync_b <= {reset_sync_b[0], 1'b0};
        end
    end

    // 输出寄存器直接采集 ADC 管脚并完成低两位补零。属性要求 Vivado 尽量将
    // 采集寄存器放入输入 IOB；拼接的两个常量低位由后续布线实现。
    (* IOB = "TRUE" *) always_ff @(posedge adc_clk_return_a) begin
        if (reset_a) begin
            data_a          <= 16'sd0;
            startup_count_a <= '0;
            out_valid_a     <= 1'b0;
        end else begin
            data_a <= $signed({adc_data_a, 2'b00});
            if (!out_valid_a) begin
                if (startup_count_a == STARTUP_LAST) begin
                    out_valid_a <= 1'b1;
                end else begin
                    startup_count_a <= startup_count_a + 1'b1;
                end
            end
        end
    end

    (* IOB = "TRUE" *) always_ff @(posedge adc_clk_return_b) begin
        if (reset_b) begin
            data_b          <= 16'sd0;
            startup_count_b <= '0;
            out_valid_b     <= 1'b0;
        end else begin
            data_b <= $signed({adc_data_b, 2'b00});
            if (!out_valid_b) begin
                if (startup_count_b == STARTUP_LAST) begin
                    out_valid_b <= 1'b1;
                end else begin
                    startup_count_b <= startup_count_b + 1'b1;
                end
            end
        end
    end

    ODDR #(
        .DDR_CLK_EDGE("OPPOSITE_EDGE"),
        .INIT(1'b0),
        .SRTYPE("ASYNC")
    ) u_oddr_clk_a (
        .Q(adc_clk_a), .C(clk_drive), .CE(1'b1),
        .D1(1'b1), .D2(1'b0), .R(rst), .S(1'b0)
    );

    ODDR #(
        .DDR_CLK_EDGE("OPPOSITE_EDGE"),
        .INIT(1'b0),
        .SRTYPE("ASYNC")
    ) u_oddr_clk_b (
        .Q(adc_clk_b), .C(clk_drive), .CE(1'b1),
        .D1(1'b1), .D2(1'b0), .R(rst), .S(1'b0)
    );

endmodule

`default_nettype wire
