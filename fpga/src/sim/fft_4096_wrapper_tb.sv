`timescale 1ns/1ps
`default_nettype none

module fft_4096_wrapper_tb;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic clear_error = 1'b0;

    logic signed [15:0] window_data;
    logic               window_valid;
    wire                window_ready;
    logic               window_first;
    logic               window_last;

    wire signed [19:0] fft_re;
    wire signed [19:0] fft_im;
    wire        [11:0] fft_bin;
    wire               fft_valid;
    logic              fft_ready;
    wire               fft_first;
    wire               fft_last;
    wire               config_done;
    wire               protocol_error;
    wire               channel_halt;

    integer output_count;
    integer cycle_count;
    integer expected_re;
    integer expected_im;
    logic   test_done;

    always #5 clk = ~clk;

    fft_4096_wrapper dut (
        .clk            (clk),
        .rst            (rst),
        .clear_error    (clear_error),
        .window_data    (window_data),
        .window_valid   (window_valid),
        .window_ready   (window_ready),
        .window_first   (window_first),
        .window_last    (window_last),
        .fft_re         (fft_re),
        .fft_im         (fft_im),
        .fft_bin        (fft_bin),
        .fft_valid      (fft_valid),
        .fft_ready      (fft_ready),
        .fft_first      (fft_first),
        .fft_last       (fft_last),
        .config_done    (config_done),
        .protocol_error (protocol_error),
        .channel_halt   (channel_halt)
    );

    // 周期性施加输出反压，检查bin和量化结果在握手条件下推进。
    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            fft_ready   <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            fft_ready   <= ((cycle_count % 7) != 3);
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            output_count <= 0;
            expected_re  <= 0;
            expected_im  <= 0;
            test_done    <= 1'b0;
        end else if (fft_valid && fft_ready) begin
            case (output_count)
                0: begin
                    expected_re = 0;       // +0.5收敛到偶数0
                    expected_im = 0;       // -0.5收敛到偶数0
                end
                1: begin
                    expected_re = 2;       // +1.5收敛到偶数2
                    expected_im = -2;
                end
                2: begin
                    expected_re = 2;       // +2.5收敛到偶数2
                    expected_im = -2;
                end
                3: begin
                    expected_re = 4;       // 大于+3.5时向4舍入
                    expected_im = -4;
                end
                4094: begin
                    expected_re = 524287;  // 正向S20饱和
                    expected_im = -524288;
                end
                4095: begin
                    expected_re = -524288; // S29最小值量化
                    expected_im = -524288;
                end
                default: begin
                    expected_re = output_count;
                    expected_im = -output_count;
                end
            endcase

            assert (fft_bin == output_count[11:0])
                else $fatal(1, "FFT bin mismatch: got %0d expected %0d",
                            fft_bin, output_count);
            assert (fft_re == expected_re)
                else $fatal(1, "FFT real mismatch at bin %0d: got %0d",
                            output_count, fft_re);
            assert (fft_im == expected_im)
                else $fatal(1, "FFT imag mismatch at bin %0d: got %0d",
                            output_count, fft_im);
            assert (fft_first == (output_count == 0))
                else $fatal(1, "fft_first mismatch at bin %0d", output_count);
            assert (fft_last == (output_count == 4095))
                else $fatal(1, "fft_last mismatch at bin %0d", output_count);

            if (output_count == 4095) begin
                test_done <= 1'b1;
            end
            output_count <= output_count + 1;
        end
    end

    initial begin
        integer sample_index;

        window_data  = 16'sd0;
        window_valid = 1'b0;
        window_first = 1'b0;
        window_last  = 1'b0;

        repeat (5) @(posedge clk);
        rst = 1'b0;

        wait (config_done);
        @(posedge clk);

        for (sample_index = 0; sample_index < 4096; sample_index++) begin
            @(negedge clk);
            window_data  = sample_index[15:0];
            window_valid = 1'b1;
            window_first = (sample_index == 0);
            window_last  = (sample_index == 4095);

            do begin
                @(posedge clk);
            end while (!window_ready);
        end

        @(negedge clk);
        window_valid = 1'b0;
        window_first = 1'b0;
        window_last  = 1'b0;

        wait (test_done);
        repeat (5) @(posedge clk);

        assert (!protocol_error)
            else $fatal(1, "Unexpected protocol_error");
        assert (!channel_halt)
            else $fatal(1, "Unexpected channel_halt");

        $display("TEST PASSED: fft_4096_wrapper");
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "TEST TIMEOUT");
    end

endmodule

// xfft_0的轻量行为模型：只用于验证封装接口、握手、计数和S29到S20量化。
// 它不替代真实FFT IP的算法仿真。
module xfft_0 (
    input  wire logic        aclk,
    input  wire logic        aresetn,

    input  wire logic [7:0]  s_axis_config_tdata,
    input  wire logic        s_axis_config_tvalid,
    output wire logic        s_axis_config_tready,

    input  wire logic [31:0] s_axis_data_tdata,
    input  wire logic        s_axis_data_tvalid,
    output wire logic        s_axis_data_tready,
    input  wire logic        s_axis_data_tlast,

    output      logic [63:0] m_axis_data_tdata,
    output      logic        m_axis_data_tvalid,
    input  wire logic        m_axis_data_tready,
    output      logic        m_axis_data_tlast,

    output wire logic        event_frame_started,
    output wire logic        event_tlast_unexpected,
    output wire logic        event_tlast_missing,
    output wire logic        event_status_channel_halt,
    output wire logic        event_data_in_channel_halt,
    output wire logic        event_data_out_channel_halt
);

    wire logic signed [15:0] input_re =
        $signed(s_axis_data_tdata[15:0]);
    wire logic signed [28:0] input_re_ext =
        {{13{input_re[15]}}, input_re};
    function automatic logic signed [28:0] make_generated_re (
        input logic signed [15:0] sample
    );
        begin
            case (sample)
                16'sd0:
                    make_generated_re = 29'sd256;
                16'sd1:
                    make_generated_re = 29'sd768;
                16'sd2:
                    make_generated_re = 29'sd1280;
                16'sd3:
                    make_generated_re = 29'sd1793;
                16'sd4094:
                    make_generated_re = 29'sh0FFFFFFF;
                16'sd4095:
                    make_generated_re = $signed(29'h10000000);
                default:
                    make_generated_re = input_re_ext <<< 9;
            endcase
        end
    endfunction

    wire logic signed [28:0] generated_re =
        make_generated_re(input_re);
    wire logic signed [28:0] generated_im = -generated_re;

    assign s_axis_config_tready = 1'b1;
    assign s_axis_data_tready = !m_axis_data_tvalid ||
                               m_axis_data_tready;

    assign event_frame_started         = 1'b0;
    assign event_tlast_unexpected      = 1'b0;
    assign event_tlast_missing         = 1'b0;
    assign event_status_channel_halt   = 1'b0;
    assign event_data_in_channel_halt  = 1'b0;
    assign event_data_out_channel_halt = 1'b0;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_data_tdata  <= 64'd0;
            m_axis_data_tvalid <= 1'b0;
            m_axis_data_tlast  <= 1'b0;
        end else if (s_axis_data_tready) begin
            m_axis_data_tvalid <= s_axis_data_tvalid;
            if (s_axis_data_tvalid) begin
                m_axis_data_tdata <= {
                    3'd0, generated_im,
                    3'd0, generated_re
                };
                m_axis_data_tlast <= s_axis_data_tlast;
            end
        end
    end

    // 防止测试模型中的配置输入被优化为未使用而隐藏接口错误。
    always_ff @(posedge aclk) begin
        if (aresetn && s_axis_config_tvalid) begin
            assert (s_axis_config_tdata == 8'h01)
                else $fatal(1, "Unexpected FFT config word");
        end
    end

endmodule

`default_nettype wire
