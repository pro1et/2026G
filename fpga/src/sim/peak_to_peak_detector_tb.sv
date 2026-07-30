`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：peak_to_peak_detector_tb
//
// 主要功能：
//   对默认参数的峰峰值检测模块执行完整帧自检，覆盖零输入、正负方波、截尾排序、
//   有符号边界、最后一点非零、连续帧、sample_valid空拍、帧标志错误和运行中复位。
//
// 使用方法：
//   从fpga/work目录运行fpga/scripts/run_peak_to_peak_detector_sim.ps1。
//   全部检查通过时打印TEST PASSED；任一断言失败立即调用$fatal。
//
// 连接说明：
//   本文件仅实例化被测模块，不依赖工程顶层、BRAM或外部测试向量。
//
// 时钟与复位：
//   产生100 MHz仿真时钟；激励在下降沿更新，输出在采样上升沿后检查。
//
// 输入格式：
//   使用完整65536点帧和16个4096点分段，所有期望值均由明确分段峰峰值推导。
//
// 输出格式：
//   精确比较32位vpp_out、单周期vpp_valid、vpp_busy和错误脉冲。
//
// 握手时序：
//   覆盖逐周期连续输入和含空拍输入，并验证帧与帧之间无空拍时不会丢点。
//
// 参数说明：
//   被测实例使用默认参数：16位、65536点、16段、每段4096点、两端各裁剪2段。
//
// 错误行为：
//   仿真总超时为20 ms；超时、数值错误或控制时序错误均立即失败。
//
// 使用限制：
//   本测试验证RTL功能，不替代实现后的综合、时序、CDC和板级联合验证。
// ============================================================================

module peak_to_peak_detector_tb;

    localparam int unsigned FRAME_SIZE    = 65536;
    localparam int unsigned SEGMENT_COUNT = 16;
    localparam int unsigned SEGMENT_SIZE  = 4096;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic signed [15:0] sample_data;
    logic               rst;
    logic               sample_valid;
    logic               sample_first;
    logic               sample_last;
    logic [31:0]        vpp_out;
    logic               vpp_valid;
    logic               vpp_busy;
    logic               vpp_error;

    int unsigned result_count = 0;
    int unsigned error_count  = 0;
    logic        previous_vpp_valid;

    peak_to_peak_detector dut (
        .clk          (clk),
        .rst          (rst),
        .sample_data  (sample_data),
        .sample_valid (sample_valid),
        .sample_first (sample_first),
        .sample_last  (sample_last),
        .vpp_out      (vpp_out),
        .vpp_valid    (vpp_valid),
        .vpp_busy     (vpp_busy),
        .vpp_error    (vpp_error)
    );

    always @(posedge clk) begin
        if (rst) begin
            previous_vpp_valid <= 1'b0;
        end else begin
            #1;
            assert (!(vpp_valid && previous_vpp_valid))
                else $fatal(1, "vpp_valid持续超过一个周期：time=%0t", $time);
            if (vpp_valid) begin
                result_count <= result_count + 1;
            end
            if (vpp_error) begin
                error_count <= error_count + 1;
            end
            previous_vpp_valid <= vpp_valid;
        end
    end

    task automatic drive_sample(
        input logic signed [15:0] value,
        input logic               first_flag,
        input logic               last_flag
    );
        begin
            @(negedge clk);
            sample_data  = value;
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
        input logic [31:0] expected_value,
        input string       case_name
    );
        int unsigned wait_cycles;
        begin
            // The integration top removes split_valid immediately after the
            // final FIFO handshake while this module post-processes the frame.
            @(negedge clk);
            sample_valid = 1'b0;
            sample_first = 1'b0;
            sample_last  = 1'b0;
            wait_cycles = 0;
            while (!vpp_valid && (wait_cycles < 128)) begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
            end
            assert (vpp_valid)
                else $fatal(1, "%s未产生vpp_valid：time=%0t", case_name, $time);
            assert (vpp_out == expected_value)
                else $fatal(1, "%s结果错误：actual=%0d expected=%0d",
                            case_name, vpp_out, expected_value);
            assert (!vpp_busy)
                else $fatal(1, "%s结果周期vpp_busy未拉低", case_name);
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge clk);
            rst          = 1'b1;
            sample_data  = 16'sd0;
            sample_valid = 1'b0;
            sample_first = 1'b0;
            sample_last  = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            @(posedge clk);
            #1;
            assert (!vpp_valid && !vpp_busy && !vpp_error && vpp_out == 32'd0)
                else $fatal(1, "复位输出错误：time=%0t", $time);
        end
    endtask

    initial begin : run_tests
        int unsigned frame_index;
        int unsigned segment_number;
        int unsigned segment_sample;
        int unsigned desired_vpp [0:SEGMENT_COUNT-1];
        logic [31:0] held_result;
        logic signed [15:0] driven_value;

        rst          = 1'b1;
        sample_data  = 16'sd0;
        sample_valid = 1'b0;
        sample_first = 1'b0;
        sample_last  = 1'b0;

        reset_dut();

        // 全零输入：所有分段峰峰值均为零。
        for (frame_index = 0; frame_index < FRAME_SIZE; frame_index = frame_index + 1) begin
            drive_sample(16'sd0, frame_index == 0, frame_index == FRAME_SIZE - 1);
        end
        check_result(32'd0, "全零输入");

        // 固定幅值正负方波：每段最小值-1000、最大值2000，结果应为3000。
        for (frame_index = 0; frame_index < FRAME_SIZE; frame_index = frame_index + 1) begin
            driven_value = frame_index[0] ? -16'sd1000 : 16'sd2000;
            drive_sample(driven_value, frame_index == 0, frame_index == FRAME_SIZE - 1);
        end
        check_result(32'd3000, "正负方波");

        // 分段峰峰值为100至1600，删除两端各2项后保留300至1400，平均值为850。
        for (segment_number = 0; segment_number < SEGMENT_COUNT; segment_number = segment_number + 1) begin
            desired_vpp[segment_number] = (segment_number + 1) * 100;
        end
        frame_index = 0;
        for (segment_number = 0; segment_number < SEGMENT_COUNT; segment_number = segment_number + 1) begin
            for (segment_sample = 0; segment_sample < SEGMENT_SIZE; segment_sample = segment_sample + 1) begin
                driven_value = (segment_sample == 1) ? desired_vpp[segment_number] : 0;
                drive_sample(driven_value, frame_index == 0, frame_index == FRAME_SIZE - 1);
                frame_index = frame_index + 1;
            end
        end
        check_result(32'd850, "截尾平均");

        // 有符号边界：每段同时包含-32768与32767，峰峰值必须为65535。
        frame_index = 0;
        for (segment_number = 0; segment_number < SEGMENT_COUNT; segment_number = segment_number + 1) begin
            for (segment_sample = 0; segment_sample < SEGMENT_SIZE; segment_sample = segment_sample + 1) begin
                if (segment_sample == 0) begin
                    driven_value = 16'sh8000;
                end else if (segment_sample == 1) begin
                    driven_value = 16'sh7fff;
                end else begin
                    driven_value = 16'sd0;
                end
                drive_sample(driven_value, frame_index == 0, frame_index == FRAME_SIZE - 1);
                frame_index = frame_index + 1;
            end
        end
        check_result(32'd65535, "有符号边界");

        // 最后一点非零并验证除以12的舍入：截尾后总和12500，结果应为1042。
        for (segment_number = 0; segment_number < SEGMENT_COUNT; segment_number = segment_number + 1) begin
            if (segment_number < 2) begin
                desired_vpp[segment_number] = 0;
            end else if (segment_number < 4) begin
                desired_vpp[segment_number] = 2000;
            end else if (segment_number == SEGMENT_COUNT - 1) begin
                desired_vpp[segment_number] = 1500;
            end else begin
                desired_vpp[segment_number] = 1000;
            end
        end
        frame_index = 0;
        for (segment_number = 0; segment_number < SEGMENT_COUNT; segment_number = segment_number + 1) begin
            for (segment_sample = 0; segment_sample < SEGMENT_SIZE; segment_sample = segment_sample + 1) begin
                if ((segment_number == SEGMENT_COUNT - 1) &&
                    (segment_sample == SEGMENT_SIZE - 1)) begin
                    driven_value = 16'sd1500;
                end else begin
                    driven_value = (segment_sample == 1) ? desired_vpp[segment_number] : 0;
                end
                drive_sample(driven_value, frame_index == 0, frame_index == FRAME_SIZE - 1);
                frame_index = frame_index + 1;
            end
        end
        check_result(32'd1042, "最后一点及舍入");

        // 连续两帧：帧间不插入sample_valid空拍，结果输出期间立即开始下一帧。
        for (frame_index = 0; frame_index < FRAME_SIZE; frame_index = frame_index + 1) begin
            driven_value = frame_index[0] ? 16'sd0 : 16'sd100;
            drive_sample(driven_value, frame_index == 0, frame_index == FRAME_SIZE - 1);
        end
        check_result(32'd100, "连续帧1");
        held_result = vpp_out;

        for (frame_index = 0; frame_index < FRAME_SIZE; frame_index = frame_index + 1) begin
            driven_value = frame_index[0] ? 16'sd0 : 16'sd200;
            drive_sample(driven_value, frame_index == 0, frame_index == FRAME_SIZE - 1);
            if (frame_index == 0) begin
                assert (!vpp_valid && vpp_busy && vpp_out == held_result)
                    else $fatal(1, "连续帧开始时输出保持或busy错误");
            end
        end
        check_result(32'd200, "连续帧2");

        // sample_valid空拍：每段峰峰值400，空拍不得改变样点或分段计数。
        for (frame_index = 0; frame_index < FRAME_SIZE; frame_index = frame_index + 1) begin
            if (frame_index != 0 && (frame_index % 5000) == 0) begin
                insert_gap(3);
            end
            driven_value = frame_index[0] ? 16'sd0 : 16'sd400;
            drive_sample(driven_value, frame_index == 0, frame_index == FRAME_SIZE - 1);
        end
        check_result(32'd400, "valid间断");

        // 缺失sample_first应产生一个错误脉冲，但仍按固定帧长度给出正确结果。
        for (frame_index = 0; frame_index < FRAME_SIZE; frame_index = frame_index + 1) begin
            drive_sample(16'sd0, 1'b0, frame_index == FRAME_SIZE - 1);
        end
        check_result(32'd0, "帧首标志缺失");

        // 运行中复位丢弃部分统计，复位后能够重新计算完整帧。
        drive_sample(16'sd10, 1'b1, 1'b0);
        drive_sample(16'sd20, 1'b0, 1'b0);
        reset_dut();
        for (frame_index = 0; frame_index < FRAME_SIZE; frame_index = frame_index + 1) begin
            drive_sample(16'sd0, frame_index == 0, frame_index == FRAME_SIZE - 1);
        end
        check_result(32'd0, "运行中复位恢复");

        insert_gap(1);
        assert (!vpp_valid && !vpp_busy)
            else $fatal(1, "最后结果后的控制信号未恢复空闲");
        assert (result_count == 10)
            else $fatal(1, "结果帧数量错误：actual=%0d expected=10", result_count);
        assert (error_count == 1)
            else $fatal(1, "帧错误脉冲数量错误：actual=%0d expected=1", error_count);

        $display("TEST PASSED");
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "测试超时");
    end

endmodule

`default_nettype wire
