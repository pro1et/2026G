`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：fir_wrap_tb
//
// 主要功能：
//   使用具备AXI反压、固定流水线延迟和复位数据向量行为的fir_compiler_0模型，
//   对fir_wrap执行自检。覆盖输入反压、帧间复位、正负舍入、16位上下饱和、
//   输出帧标志、完成脉冲、错误清除以及输入帧标志异常。
//
// 使用方法：
//   从fpga/work目录运行fpga/scripts/run_fir_wrap_sim.ps1。通过时打印TEST PASSED。
//   本测试的IP模型只验证包装协议和缩放，不替代真实FIR IP的冲激响应仿真。
// ============================================================================

module fir_compiler_0 (
    input  wire logic        aresetn,
    input  wire logic        aclk,
    input  wire logic        s_axis_data_tvalid,
    output      logic        s_axis_data_tready,
    input  wire logic [15:0] s_axis_data_tdata,
    output      logic        m_axis_data_tvalid,
    output      logic [39:0] m_axis_data_tdata
);

    localparam int unsigned MODEL_LATENCY = 5;

    logic [MODEL_LATENCY-1:0] valid_pipe;
    logic signed [39:0] data_pipe [0:MODEL_LATENCY-1];
    int unsigned cycle_count;
    integer index;

    function automatic logic signed [39:0] make_raw(
        input logic signed [15:0] value
    );
        longint signed scaled;
        begin
            // 两个边界码故意制造超范围结果，以验证包装层饱和逻辑。
            if (value == 16'sh7fff) begin
                scaled = 64'sd40000 * 64'sd524288;
            end else if (value == 16'sh8000) begin
                scaled = -64'sd40000 * 64'sd524288;
            end else begin
                scaled = value * 64'sd524288;
            end
            make_raw = scaled[39:0];
        end
    endfunction

    always_comb begin
        // 周期性撤销ready，验证fir_wrap会把反压原样传回fifo_ctrl。
        s_axis_data_tready = aresetn && ((cycle_count % 3) != 1);
        m_axis_data_tvalid = valid_pipe[MODEL_LATENCY-1];
        m_axis_data_tdata  = data_pipe[MODEL_LATENCY-1];
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            valid_pipe <= '0;
            cycle_count <= 0;
            for (index = 0; index < MODEL_LATENCY; index = index + 1) begin
                data_pipe[index] <= '0;
            end
        end else begin
            cycle_count <= cycle_count + 1;
            for (index = MODEL_LATENCY - 1; index > 0; index = index - 1) begin
                valid_pipe[index] <= valid_pipe[index-1];
                data_pipe[index]  <= data_pipe[index-1];
            end
            valid_pipe[0] <= s_axis_data_tvalid && s_axis_data_tready;
            if (s_axis_data_tvalid && s_axis_data_tready) begin
                data_pipe[0] <= make_raw($signed(s_axis_data_tdata));
            end else begin
                data_pipe[0] <= '0;
            end
        end
    end

endmodule

module fir_wrap_tb;

    localparam int unsigned FRAME_SIZE   = 8;
    localparam int unsigned RESET_CYCLES = 3;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic               rst;
    logic               clear_error;
    logic signed [15:0] fir_data;
    logic               fir_valid;
    logic               fir_ready;
    logic               fir_first;
    logic               fir_last;
    logic signed [15:0] sample_data;
    logic               sample_valid;
    logic               sample_first;
    logic               sample_last;
    logic               fir_frame_done;
    logic               busy;
    logic               protocol_error;
    logic               saturation_error;

    logic signed [15:0] expected_data [0:FRAME_SIZE-1];
    int unsigned expected_index;
    int unsigned completed_frames;
    int unsigned ready_stall_count;
    logic        awaiting_done;

    fir_wrap #(
        .FRAME_SIZE   (FRAME_SIZE),
        .RESET_CYCLES (RESET_CYCLES)
    ) dut (
        .clk              (clk),
        .rst              (rst),
        .clear_error      (clear_error),
        .fir_data         (fir_data),
        .fir_valid        (fir_valid),
        .fir_ready        (fir_ready),
        .fir_first        (fir_first),
        .fir_last         (fir_last),
        .sample_data      (sample_data),
        .sample_valid     (sample_valid),
        .sample_first     (sample_first),
        .sample_last      (sample_last),
        .fir_frame_done   (fir_frame_done),
        .busy             (busy),
        .protocol_error   (protocol_error),
        .saturation_error (saturation_error)
    );

    // 在下降沿检查已经稳定的输出电平；有效样点将在下一个上升沿被下游接收。
    always @(negedge clk) begin
        if (rst) begin
            expected_index <= 0;
            completed_frames <= 0;
            awaiting_done <= 1'b0;
        end else begin
            if (sample_valid) begin
                assert (sample_data === expected_data[expected_index])
                    else $fatal(1,
                        "输出错误：frame=%0d index=%0d actual=%0d expected=%0d",
                        completed_frames, expected_index, sample_data,
                        expected_data[expected_index]);
                assert (sample_first == (expected_index == 0))
                    else $fatal(1, "sample_first错误：index=%0d", expected_index);
                assert (sample_last == (expected_index == FRAME_SIZE - 1))
                    else $fatal(1, "sample_last错误：index=%0d", expected_index);

                if (expected_index == FRAME_SIZE - 1) begin
                    expected_index <= 0;
                    awaiting_done  <= 1'b1;
                end else begin
                    expected_index <= expected_index + 1;
                end
            end

            if (fir_frame_done) begin
                assert (awaiting_done)
                    else $fatal(1, "fir_frame_done未跟随最后一个输出");
                awaiting_done   <= 1'b0;
                completed_frames <= completed_frames + 1;
            end

            assert (!(fir_frame_done && sample_valid))
                else $fatal(1, "当前实现约定frame_done在末输出接收后的下一周期产生");
        end
    end

    task automatic drive_frame(
        input logic signed [15:0] value0,
        input logic signed [15:0] value1,
        input logic               omit_first
    );
        logic signed [15:0] value;
        int unsigned index;
        begin
            ready_stall_count = 0;
            for (index = 0; index < FRAME_SIZE; index = index + 1) begin
                case (index)
                    0: value = value0;
                    1: value = value1;
                    2: value = 16'sh7fff;
                    3: value = 16'sh8000;
                    4: value = 16'sd1;
                    5: value = -16'sd1;
                    6: value = 16'sd0;
                    default: value = 16'sd1234;
                endcase

                expected_data[index] = value;
                if (value == 16'sh7fff) expected_data[index] = 16'sh7fff;
                if (value == 16'sh8000) expected_data[index] = 16'sh8000;

                @(negedge clk);
                fir_data  = value;
                fir_valid = 1'b1;
                fir_first = (index == 0) && !omit_first;
                fir_last  = (index == FRAME_SIZE - 1);

                while (!fir_ready) begin
                    ready_stall_count = ready_stall_count + 1;
                    @(negedge clk);
                end
                @(posedge clk);
            end

            @(negedge clk);
            fir_valid = 1'b0;
            fir_first = 1'b0;
            fir_last  = 1'b0;

            assert (ready_stall_count > 0)
                else $fatal(1, "测试未覆盖输入反压");
        end
    endtask

    task automatic wait_frame_done(input int unsigned expected_total);
        int unsigned timeout;
        begin
            timeout = 0;
            while ((completed_frames < expected_total) && (timeout < 300)) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            assert (completed_frames == expected_total)
                else $fatal(1, "等待frame_done超时：actual=%0d expected=%0d",
                            completed_frames, expected_total);
        end
    endtask

    task automatic clear_sticky_errors;
        begin
            @(negedge clk);
            clear_error = 1'b1;
            @(posedge clk);
            @(negedge clk);
            clear_error = 1'b0;
        end
    endtask

    initial begin : run_tests
        rst          = 1'b1;
        clear_error  = 1'b0;
        fir_data     = 16'sd0;
        fir_valid    = 1'b0;
        fir_first    = 1'b0;
        fir_last     = 1'b0;
        expected_index  = 0;
        completed_frames = 0;
        awaiting_done = 1'b0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // 第一帧验证正常标志、反压、正负数据和上下饱和。
        drive_frame(16'sd100, -16'sd100, 1'b0);
        wait_frame_done(1);
        assert (!protocol_error)
            else $fatal(1, "正常帧错误地置位protocol_error");
        assert (saturation_error)
            else $fatal(1, "上下饱和未锁存saturation_error");

        clear_sticky_errors();
        assert (!protocol_error && !saturation_error)
            else $fatal(1, "clear_error未清除粘滞错误");

        // 第二帧证明帧间复位后仍可重新启动，并检查缺失first标志。
        drive_frame(16'sd321, -16'sd654, 1'b1);
        wait_frame_done(2);
        assert (protocol_error)
            else $fatal(1, "缺失fir_first未锁存protocol_error");
        assert (saturation_error)
            else $fatal(1, "第二帧饱和未重新锁存错误");

        assert (expected_index == 0 && !awaiting_done)
            else $fatal(1, "最终输出计数未回到帧边界");

        $display("TEST PASSED");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "测试超时");
    end

endmodule

`default_nettype wire
