`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：mean_square_calculator_tb
//
// 主要功能：
//   对mean_square_calculator执行可重复的自检式功能仿真，覆盖零输入、正负方波、
//   正弦波、最后一点非零、最大负数、连续帧、valid空拍、帧标志异常和运行中复位。
//
// 使用方法：
//   从fpga/work目录运行fpga/scripts/run_mean_square_calculator_sim.ps1。
//   全部检查通过时打印TEST PASSED；任一断言失败会立即调用$fatal。
//
// 连接说明：
//   本文件仅实例化被测模块，不依赖工程顶层、BRAM或外部测试向量。
//
// 时钟与复位：
//   产生100 MHz仿真时钟；激励在下降沿更新，输出在采样上升沿后检查。
//
// 输入格式：
//   所有参考结果都由testbench对实际送入的16位整数逐点平方后独立累加得到。
//
// 输出格式：
//   预期结果采用与规格相同的(sum+32768)>>16整数算法进行精确比较。
//
// 握手时序：
//   覆盖逐周期连续输入和sample_valid含空拍两种情况，并检查result_valid脉宽。
//
// 参数说明：
//   被测模块帧长固定为65536，本testbench使用完整长度验证计数回绕和除法位移。
//
// 错误行为：
//   仿真总超时为20 ms；超时、结果错误、脉宽错误或输出保持错误均立即失败。
//
// 使用限制：
//   本测试验证RTL功能，不替代实现后的综合、板级时序和系统CDC验证。
// ============================================================================

module mean_square_calculator_tb;

    localparam int unsigned FRAME_SAMPLE_COUNT = 65536;
    localparam real TWO_PI = 6.28318530717958647692;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic signed [15:0] sample_in;
    logic               rst;
    logic               sample_valid;
    logic               sample_first;
    logic               sample_last;
    logic [31:0]        mean_square_out;
    logic               result_valid;
    logic               overflow;

    int unsigned result_count = 0;
    logic        previous_result_valid;

    mean_square_calculator dut (
        .clk             (clk),
        .rst             (rst),
        .sample_in       (sample_in),
        .sample_valid    (sample_valid),
        .sample_first    (sample_first),
        .sample_last     (sample_last),
        .mean_square_out (mean_square_out),
        .result_valid    (result_valid),
        .overflow        (overflow)
    );

    // 统一监控结果脉冲宽度，并统计已经产生的完整帧结果数量。
    always @(posedge clk) begin
        if (rst) begin
            previous_result_valid <= 1'b0;
        end else begin
            #1;
            assert (!(result_valid && previous_result_valid))
                else $fatal(1, "result_valid持续超过一个周期：time=%0t", $time);
            if (result_valid) begin
                result_count <= result_count + 1;
            end
            previous_result_valid <= result_valid;
        end
    end

    function automatic longint unsigned reference_square(
        input logic signed [15:0] value
    );
        longint signed extended_value;
        begin
            extended_value  = value;
            reference_square = extended_value * extended_value;
        end
    endfunction

    task automatic drive_sample(
        input logic signed [15:0] value,
        input logic               first_flag,
        input logic               last_flag
    );
        begin
            @(negedge clk);
            sample_in    = value;
            sample_valid = 1'b1;
            sample_first = first_flag;
            sample_last  = last_flag;
            @(posedge clk);
            #1;
        end
    endtask

    task automatic insert_gap(input int unsigned cycle_count);
        begin
            @(negedge clk);
            sample_valid = 1'b0;
            sample_first = 1'b0;
            sample_last  = 1'b0;
            repeat (cycle_count) @(posedge clk);
            #1;
        end
    endtask

    task automatic check_result(
        input longint unsigned expected_sum,
        input logic            expected_overflow,
        input string           case_name
    );
        longint unsigned expected_mean;
        int unsigned wait_cycles;
        begin
            expected_mean = (expected_sum + 64'd32768) >> 16;
            // Model the top-level last-sample handshake while the output
            // pipeline drains.
            @(negedge clk);
            sample_valid = 1'b0;
            sample_first = 1'b0;
            sample_last  = 1'b0;
            wait_cycles = 0;
            while (!result_valid && (wait_cycles < 16)) begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
            end
            assert (result_valid)
                else $fatal(1, "%s未产生result_valid：time=%0t", case_name, $time);
            assert (mean_square_out == expected_mean[31:0])
                else $fatal(1, "%s结果错误：actual=%0d expected=%0d sum=%0d",
                            case_name, mean_square_out, expected_mean, expected_sum);
            assert (overflow == expected_overflow)
                else $fatal(1, "%s overflow错误：actual=%b expected=%b",
                            case_name, overflow, expected_overflow);
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge clk);
            rst          = 1'b1;
            sample_in    = 16'sd0;
            sample_valid = 1'b0;
            sample_first = 1'b0;
            sample_last  = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            @(posedge clk);
            #1;
            assert (!result_valid && mean_square_out == 32'd0 && !overflow)
                else $fatal(1, "复位输出错误：time=%0t", $time);
        end
    endtask

    initial begin : run_tests
        longint unsigned expected_sum;
        logic [31:0] held_result;
        logic signed [15:0] sine_sample;
        int signed quantized_sine;
        int unsigned index;

        rst          = 1'b1;
        sample_in    = 16'sd0;
        sample_valid = 1'b0;
        sample_first = 1'b0;
        sample_last  = 1'b0;

        reset_dut();

        // 全零输入：结果和异常标志都必须为零。
        expected_sum = 0;
        for (index = 0; index < FRAME_SAMPLE_COUNT; index = index + 1) begin
            drive_sample(16'sd0, index == 0, index == FRAME_SAMPLE_COUNT - 1);
        end
        check_result(expected_sum, 1'b0, "全零输入");

        // 固定幅值正负方波：符号交替不应改变平方结果。
        expected_sum = 0;
        for (index = 0; index < FRAME_SAMPLE_COUNT; index = index + 1) begin
            if (index[0]) begin
                drive_sample(-16'sd12345, index == 0, index == FRAME_SAMPLE_COUNT - 1);
                expected_sum = expected_sum + reference_square(-16'sd12345);
            end else begin
                drive_sample(16'sd12345, index == 0, index == FRAME_SAMPLE_COUNT - 1);
                expected_sum = expected_sum + reference_square(16'sd12345);
            end
        end
        check_result(expected_sum, 1'b0, "正负方波");

        // 一周期量化正弦波：参考模型对实际送入的整数样点独立计算。
        expected_sum = 0;
        for (index = 0; index < FRAME_SAMPLE_COUNT; index = index + 1) begin
            quantized_sine = $rtoi(12000.0 * $sin(TWO_PI * index / FRAME_SAMPLE_COUNT));
            sine_sample    = quantized_sine;
            drive_sample(sine_sample, index == 0, index == FRAME_SAMPLE_COUNT - 1);
            expected_sum = expected_sum + reference_square(sine_sample);
        end
        check_result(expected_sum, 1'b0, "正弦波");

        // 仅最后一个样点非零：专门检查帧末非阻塞赋值不会漏算当前样点。
        expected_sum = reference_square(16'sd32767);
        for (index = 0; index < FRAME_SAMPLE_COUNT; index = index + 1) begin
            drive_sample((index == FRAME_SAMPLE_COUNT - 1) ? 16'sd32767 : 16'sd0,
                         index == 0, index == FRAME_SAMPLE_COUNT - 1);
        end
        check_result(expected_sum, 1'b0, "最后一点非零");

        // 最大负数：-32768平方必须精确得到2^30，验证有符号乘法边界。
        expected_sum = 0;
        for (index = 0; index < FRAME_SAMPLE_COUNT; index = index + 1) begin
            drive_sample(-16'sd32768, index == 0, index == FRAME_SAMPLE_COUNT - 1);
            expected_sum = expected_sum + reference_square(-16'sd32768);
        end
        check_result(expected_sum, 1'b0, "最大负数");

        // 连续两帧：最后点与下一帧第一点之间不插入任何sample_valid空拍。
        expected_sum = 0;
        for (index = 0; index < FRAME_SAMPLE_COUNT; index = index + 1) begin
            drive_sample(16'sd100, index == 0, index == FRAME_SAMPLE_COUNT - 1);
            expected_sum = expected_sum + reference_square(16'sd100);
        end
        check_result(expected_sum, 1'b0, "连续帧1");
        held_result = mean_square_out;

        expected_sum = 0;
        for (index = 0; index < FRAME_SAMPLE_COUNT; index = index + 1) begin
            drive_sample(-16'sd200, index == 0, index == FRAME_SAMPLE_COUNT - 1);
            if (index == 0) begin
                assert (!result_valid && mean_square_out == held_result)
                    else $fatal(1, "连续帧开始时结果脉冲或输出保持错误");
            end
            expected_sum = expected_sum + reference_square(-16'sd200);
        end
        check_result(expected_sum, 1'b0, "连续帧2");

        // sample_valid中间存在空拍：空拍不得推进帧计数或改变平方和。
        expected_sum = 0;
        for (index = 0; index < FRAME_SAMPLE_COUNT; index = index + 1) begin
            if (index != 0 && (index % 4096) == 0) begin
                insert_gap(3);
            end
            drive_sample(16'sd300, index == 0, index == FRAME_SAMPLE_COUNT - 1);
            expected_sum = expected_sum + reference_square(16'sd300);
        end
        check_result(expected_sum, 1'b0, "valid间断");

        // 帧标志异常：运算仍按固定点数完成，但结果关联的overflow必须置位。
        expected_sum = 0;
        for (index = 0; index < FRAME_SAMPLE_COUNT; index = index + 1) begin
            drive_sample(16'sd0, 1'b0, index == FRAME_SAMPLE_COUNT - 1);
        end
        check_result(expected_sum, 1'b1, "帧首标志缺失");

        // 运行中复位应丢弃部分帧，复位后重新从第一个有效样点开始统计。
        drive_sample(16'sd123, 1'b1, 1'b0);
        drive_sample(16'sd456, 1'b0, 1'b0);
        reset_dut();
        expected_sum = 0;
        for (index = 0; index < FRAME_SAMPLE_COUNT; index = index + 1) begin
            drive_sample(16'sd0, index == 0, index == FRAME_SAMPLE_COUNT - 1);
        end
        check_result(expected_sum, 1'b0, "运行中复位恢复");

        insert_gap(1);
        assert (!result_valid)
            else $fatal(1, "最后结果的result_valid未按时撤销");
        assert (result_count == 10)
            else $fatal(1, "结果帧数量错误：actual=%0d expected=10", result_count);

        $display("TEST PASSED");
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "测试超时");
    end

endmodule

`default_nettype wire
