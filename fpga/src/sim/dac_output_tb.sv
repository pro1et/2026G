`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：dac_output_tb
//
// 主要功能：
//   对 dac_output 执行自检式仿真，验证双通道码制转换、板级极性补偿、饱和、
//   间断有效、转发时钟相位和工作中复位。
//
// 使用方法：
//   从 fpga/work 运行 fpga/scripts/run_dac_output_sim.ps1。
//   测试通过时打印 TEST PASSED，任一检查失败时调用 $fatal。
//
// 连接说明：
//   本文件仅用于仿真，不加入综合源文件。
//
// 时钟与复位：
//   clk 和 clk_drive 使用同一个 100 MHz 仿真时钟。激励在下降沿之后改变，
//   被测模块在上升沿接收，并在随后下降沿产生 DAC 时钟上升沿。
//
// 输入格式：
//   两路输入均为 16 位有符号二进制补码。
//
// 输出格式：
//   自动检查两路 10 位原始码和两路 DAC 时钟。
//
// 握手时序：
//   in_valid 高电平接受新样点，低电平必须保持上一组数据。
//
// 参数说明：
//   本测试无参数。
//
// 错误行为：
//   检查失败立即结束仿真。
//
// 使用限制：
//   测试中的 ODDR 是仅供 RTL 仿真的行为模型，不代替器件级时序仿真。
// ============================================================================

// Xilinx ODDR 的最小行为模型，仅覆盖被测模块使用的 OPPOSITE_EDGE 模式。
module ODDR #(
    parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
    parameter INIT         = 1'b0,
    parameter SRTYPE       = "ASYNC"
) (
    output logic Q,
    input  wire  logic C,
    input  wire  logic CE,
    input  wire  logic D1,
    input  wire  logic D2,
    input  wire  logic R,
    input  wire  logic S
);
    initial Q = INIT;

    always @(C or R or S) begin
        if (R) begin
            Q = 1'b0;
        end else if (S) begin
            Q = 1'b1;
        end else if (CE) begin
            Q = C ? D1 : D2;
        end
    end
endmodule

module dac_output_tb;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic               rst;
    logic signed [15:0] data_a;
    logic signed [15:0] data_b;
    logic               in_valid;
    logic               dac_clk_a;
    logic               dac_clk_b;
    logic [9:0]         dac_data_a;
    logic [9:0]         dac_data_b;

    dac_output dut (
        .clk       (clk),
        .clk_drive (clk),
        .rst       (rst),
        .data_a    (data_a),
        .data_b    (data_b),
        .in_valid  (in_valid),
        .dac_clk_a (dac_clk_a),
        .dac_clk_b (dac_clk_b),
        .dac_data_a(dac_data_a),
        .dac_data_b(dac_data_b)
    );

    task automatic apply_sample(
        input logic signed [15:0] sample_a,
        input logic signed [15:0] sample_b,
        input logic        [9:0] expected_a,
        input logic        [9:0] expected_b
    );
        begin
            @(negedge clk);
            #1;
            data_a   = sample_a;
            data_b   = sample_b;
            in_valid = 1'b1;

            @(posedge clk);
            #1;
            assert (dac_data_a === expected_a && dac_data_b === expected_b)
                else $fatal(1,
                    "数据转换错误：time=%0t a=%0d/%0d b=%0d/%0d",
                    $time, dac_data_a, expected_a, dac_data_b, expected_b);
            assert (!dac_clk_a && !dac_clk_b)
                else $fatal(1, "数据更新沿上 DAC 时钟应为低，time=%0t", $time);

            @(negedge clk);
            #1;
            assert (dac_clk_a && dac_clk_b)
                else $fatal(1, "内部下降沿未产生 DAC 捕获上升沿，time=%0t", $time);
        end
    endtask

    initial begin
        rst      = 1'b1;
        data_a   = '0;
        data_b   = '0;
        in_valid = 1'b0;

        repeat (2) @(posedge clk);
        #1;
        assert (dac_data_a === 10'd511 && dac_data_b === 10'd511)
            else $fatal(1, "复位零点码错误，time=%0t", $time);
        assert (!dac_clk_a && !dac_clk_b)
            else $fatal(1, "复位期间 DAC 时钟未停止，time=%0t", $time);

        @(negedge clk);
        #1;
        rst = 1'b0;

        // 有效范围端点与零点：数值极性应和最终模拟电压极性一致。
        apply_sample(-16'sd512, 16'sd511, 10'd1023, 10'd0);
        apply_sample(16'sd0,   -16'sd1,  10'd511,  10'd512);

        // 超范围输入必须饱和，不允许截位回绕。
        apply_sample(-16'sd513, 16'sd512,   10'd1023, 10'd0);
        apply_sample(-16'sd32768, 16'sd32767, 10'd1023, 10'd0);

        // in_valid 为低时，即使输入变化也保持上一组输出。
        @(negedge clk);
        #1;
        in_valid = 1'b0;
        data_a   = 16'sd123;
        data_b   = -16'sd234;
        @(posedge clk);
        #1;
        assert (dac_data_a === 10'd1023 && dac_data_b === 10'd0)
            else $fatal(1, "无效周期未保持输出，time=%0t", $time);

        // 工作中复位应立即停止外部时钟，并在内部上升沿恢复零点码。
        #2;
        rst = 1'b1;
        #1;
        assert (!dac_clk_a && !dac_clk_b)
            else $fatal(1, "异步时钟复位未立即生效，time=%0t", $time);
        @(posedge clk);
        #1;
        assert (dac_data_a === 10'd511 && dac_data_b === 10'd511)
            else $fatal(1, "工作中复位未恢复零点码，time=%0t", $time);

        $display("TEST PASSED");
        $finish;
    end

    initial begin
        #5000;
        $fatal(1, "测试超时");
    end

endmodule

`default_nettype wire

