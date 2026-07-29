`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：dac_output
//
// 主要功能：
//   驱动 ATK_DUAL_HS_DA 板上的两颗 3PD5651E，将上游同步提交的两路 10 位
//   无符号码转换为并行 GPIO 数据和两路转发时钟。本模块只负责物理接口时序，
//   不生成波形、不跨时钟域，也不执行幅值缩放或码制转换。
//
// 使用方法：
//   1. 将 clk 和 rst 连接到 clock_tree 的 clk_30m 和 rst_30m。
//   2. 上游在 clk 上升沿同时满足 in_valid 和 in_ready 时提交一对样本。
//   3. 将 dac_data_a/b[9:0] 和 dac_clk_a/b 连接至 DA 转接板的两组 D0~D9、CLK。
//
// 连接说明：
//   clk          <- clock_tree 的 30 MHz 时钟输出
//   rst          <- clock_tree 的 30 MHz 域高有效复位输出
//   data_a/b     <- DDS、波形存储器或其他码流发生模块
//   in_valid     <- 上游双通道样本有效信号
//   in_ready     -> 上游双通道样本接收就绪信号
//   dac_data_a/b -> DA 板通道 1/2 的 D0~D9，其中 D9 为最高位
//   dac_clk_a/b  -> DA 板通道 1/2 的 CLK
//
// 时钟与复位：
//   内部只使用 clk 一个时钟域。上升沿接收上游样本，下降沿更新物理数据输出；
//   ODDR 将 clk 转发到两颗 DAC。rst 为 clk 域高有效同步复位，转发时钟使用异步
//   复位，以便复位时立即保持低电平。
//
// 输入/输出格式：
//   data_a/b 和 dac_data_a/b 均为 10 位无符号直二进制码，0、512、1023 分别为
//   最小码、中间码和最大码。ATK_DUAL_HS_DA 板的模拟放大级为反相关系，典型
//   调整下最小码约输出 +5 V、最大码约输出 -5 V，本模块不补偿该极性。
//
// 握手时序：
//   in_ready 在非复位期间恒为高。in_valid && in_ready 的上升沿接收一对样本；
//   随后下降沿改变 GPIO 数据，再下一个上升沿由 DAC 锁存。无有效输入时保持
//   最近一次输出码。吞吐率为每通道每 clk 周期一个样本，锁存延迟为一个周期。
//
// 参数说明：
//   RESET_CODE 为复位期间及首次有效样本前的输出码，合法范围为 0~1023。
//
// 错误行为：
//   接口不提供错误或丢包指示；上游若在 in_valid 为低时改变 data_a/b，不会影响
//   DAC 输出。复位期间拒绝输入并输出 RESET_CODE。
//
// 使用限制：
//   使用 Xilinx 7 系列 ODDR 原语。3PD5651E 最高采样率为 125 MSPS；修改时钟
//   频率、I/O 电压或板级走线后，必须重新验证建立/保持时间和电气兼容性。
// ============================================================================

module dac_output #(
    parameter logic [9:0] RESET_CODE = 10'd512  // 复位和启动默认码，通常对应约 0 V
) (
    input  wire  logic       clk,         // DA 接口时钟，推荐 30 MHz、连续运行
    input  wire  logic       rst,         // clk 域高有效同步复位

    input  wire  logic [9:0] data_a,      // 通道 1 待输出码，D9 为最高位
    input  wire  logic [9:0] data_b,      // 通道 2 待输出码，D9 为最高位
    input  wire  logic       in_valid,    // 双通道输入有效，高电平表示本周期提交样本
    output wire  logic       in_ready,    // 双通道输入就绪，非复位期间恒为高

    (* IOB = "TRUE" *) output logic [9:0] dac_data_a, // 通道 1 DA 并行数据
    (* IOB = "TRUE" *) output logic [9:0] dac_data_b, // 通道 2 DA 并行数据
    output wire  logic       dac_clk_a,   // 通道 1 DA 转发时钟，与 clk 同频同相
    output wire  logic       dac_clk_b    // 通道 2 DA 转发时钟，与 clk 同频同相
);

    logic [9:0] pending_data_a;
    logic [9:0] pending_data_b;

    assign in_ready = ~rst;

    // 上升沿接收输入，使上游接口遵循工程统一的同步 valid/ready 约定。
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_data_a <= RESET_CODE;
            pending_data_b <= RESET_CODE;
        end else if (in_valid) begin
            pending_data_a <= data_a;
            pending_data_b <= data_b;
        end
    end

    // 在转发时钟下降沿改变数据，为下一上升沿锁存留出约半个周期建立时间。
    always_ff @(negedge clk) begin
        if (rst) begin
            dac_data_a <= RESET_CODE;
            dac_data_b <= RESET_CODE;
        end else begin
            dac_data_a <= pending_data_a;
            dac_data_b <= pending_data_b;
        end
    end

    // 使用专用 DDR 输出寄存器转发时钟，避免普通组合逻辑产生毛刺或占空比失真。
    ODDR #(
        .DDR_CLK_EDGE("OPPOSITE_EDGE"),
        .INIT        (1'b0),
        .SRTYPE      ("ASYNC")
    ) u_oddr_clk_a (
        .Q (dac_clk_a),
        .C (clk),
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
        .Q (dac_clk_b),
        .C (clk),
        .CE(1'b1),
        .D1(1'b1),
        .D2(1'b0),
        .R (rst),
        .S (1'b0)
    );

endmodule

`default_nettype wire
