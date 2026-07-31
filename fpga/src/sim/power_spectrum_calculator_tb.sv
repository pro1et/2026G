`timescale 1ns/1ps
`default_nettype none

module power_spectrum_calculator_tb;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic clear_error = 1'b0;

    logic signed [19:0] fft_re;
    logic signed [19:0] fft_im;
    logic        [11:0] fft_bin;
    logic               fft_valid;
    wire                fft_ready;
    logic               fft_first;
    logic               fft_last;

    wire        [31:0] power_data;
    wire        [10:0] power_bin;
    wire               power_valid;
    logic              power_ready;
    wire               power_first;
    wire               power_last;

    wire fft_frame_done;
    wire power_frame_done;
    wire protocol_error;

    logic [31:0] expected_power [0:2047];
    integer output_count;
    integer cycle_count;
    integer fft_done_count;
    integer power_done_count;
    logic   stop_output_check = 1'b0;

    logic        stalled_last_cycle;
    logic [31:0] held_power_data;
    logic [10:0] held_power_bin;
    logic        held_power_first;
    logic        held_power_last;

    always #5 clk = ~clk;

    power_spectrum_calculator dut (
        .clk              (clk),
        .rst              (rst),
        .clear_error      (clear_error),
        .fft_re           (fft_re),
        .fft_im           (fft_im),
        .fft_bin          (fft_bin),
        .fft_valid        (fft_valid),
        .fft_ready        (fft_ready),
        .fft_first        (fft_first),
        .fft_last         (fft_last),
        .power_data       (power_data),
        .power_bin        (power_bin),
        .power_valid      (power_valid),
        .power_ready      (power_ready),
        .power_first      (power_first),
        .power_last       (power_last),
        .fft_frame_done   (fft_frame_done),
        .power_frame_done (power_frame_done),
        .protocol_error   (protocol_error)
    );

    function automatic logic signed [19:0] make_re (
        input integer index
    );
        integer signed value;
        begin
            case (index)
                0: value = 0;
                1: value = -524288;
                2: value = 524287;
                3: value = 11;
                4: value = 12;
                5: value = -12;
                default:
                    value = ((index * 7919) % 1048576) - 524288;
            endcase
            make_re = value[19:0];
        end
    endfunction

    function automatic logic signed [19:0] make_im (
        input integer index
    );
        integer signed value;
        begin
            case (index)
                0: value = 0;
                1: value = -524288;
                2: value = 524287;
                3: value = 0;
                4: value = 0;
                5: value = 0;
                default:
                    value = ((index * 3571 + 12345) % 1048576) - 524288;
            endcase
            make_im = value[19:0];
        end
    endfunction

    function automatic logic [31:0] calculate_expected_power (
        input logic signed [19:0] re_value,
        input logic signed [19:0] im_value
    );
        longint signed   re_wide;
        longint signed   im_wide;
        longint unsigned raw_power;
        longint unsigned scaled_power;
        begin
            re_wide = re_value;
            im_wide = im_value;
            raw_power =
                (re_wide * re_wide) +
                (im_wide * im_wide);
            scaled_power = (raw_power + 64'd128) >> 8;

            if (scaled_power > 64'hFFFF_FFFF) begin
                calculate_expected_power = 32'hFFFF_FFFF;
            end else begin
                calculate_expected_power = scaled_power[31:0];
            end
        end
    endfunction

    task automatic send_fft_sample (
        input integer index,
        input logic   first_value,
        input logic   last_value
    );
        begin
            // 可重复的输入空拍，覆盖非连续TVALID。
            if ((index % 13) == 6) begin
                @(negedge clk);
                fft_valid = 1'b0;
                repeat (2) @(posedge clk);
            end

            @(negedge clk);
            fft_re    = make_re(index);
            fft_im    = make_im(index);
            fft_bin   = index[11:0];
            fft_first = first_value;
            fft_last  = last_value;
            fft_valid = 1'b1;

            do begin
                @(posedge clk);
            end while (!fft_ready);

            if (index <= 2047) begin
                expected_power[index] =
                    calculate_expected_power(make_re(index), make_im(index));
            end
        end
    endtask

    // 周期性反压，保证仿真可重复。
    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            power_ready <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            power_ready <= ((cycle_count % 9) != 4) &&
                           ((cycle_count % 9) != 5);
        end
    end

    // 检查输出反压期间所有流接口信号保持不变。
    always_ff @(posedge clk) begin
        if (rst) begin
            stalled_last_cycle <= 1'b0;
            held_power_data    <= 32'd0;
            held_power_bin     <= 11'd0;
            held_power_first   <= 1'b0;
            held_power_last    <= 1'b0;
        end else begin
            if (stalled_last_cycle) begin
                assert (power_valid)
                    else $fatal(1, "power_valid dropped during backpressure");
                assert (power_data == held_power_data)
                    else $fatal(1, "power_data changed during backpressure");
                assert (power_bin == held_power_bin)
                    else $fatal(1, "power_bin changed during backpressure");
                assert (power_first == held_power_first)
                    else $fatal(1, "power_first changed during backpressure");
                assert (power_last == held_power_last)
                    else $fatal(1, "power_last changed during backpressure");
            end

            stalled_last_cycle <= power_valid && !power_ready;
            if (power_valid && !power_ready) begin
                held_power_data  <= power_data;
                held_power_bin   <= power_bin;
                held_power_first <= power_first;
                held_power_last  <= power_last;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            output_count    <= 0;
            fft_done_count  <= 0;
            power_done_count <= 0;
        end else begin
            if (power_valid && power_ready && !stop_output_check) begin
                assert (output_count < 2048)
                    else $fatal(1, "More than 2048 power outputs");
                assert (power_bin == output_count[10:0])
                    else $fatal(1,
                        "power_bin mismatch: got %0d expected %0d",
                        power_bin, output_count);
                assert (power_data == expected_power[output_count])
                    else $fatal(1,
                        "power mismatch at bin %0d: got %0u expected %0u",
                        output_count, power_data,
                        expected_power[output_count]);
                assert (power_first == (output_count == 0))
                    else $fatal(1,
                        "power_first mismatch at bin %0d", output_count);
                assert (power_last == (output_count == 2047))
                    else $fatal(1,
                        "power_last mismatch at bin %0d", output_count);
                output_count <= output_count + 1;
            end

            if (fft_frame_done) begin
                fft_done_count <= fft_done_count + 1;
            end
            if (power_frame_done) begin
                power_done_count <= power_done_count + 1;
            end
        end
    end

    initial begin
        integer index;

        fft_re    = 20'sd0;
        fft_im    = 20'sd0;
        fft_bin   = 12'd0;
        fft_valid = 1'b0;
        fft_first = 1'b0;
        fft_last  = 1'b0;

        repeat (5) @(posedge clk);
        rst = 1'b0;

        for (index = 0; index < 4096; index++) begin
            send_fft_sample(
                index,
                (index == 0),
                (index == 4095)
            );
        end

        @(negedge clk);
        fft_valid = 1'b0;
        fft_first = 1'b0;
        fft_last  = 1'b0;

        wait (output_count == 2048);
        repeat (5) @(posedge clk);

        assert (!protocol_error)
            else $fatal(1, "Unexpected protocol_error in valid frame");
        assert (fft_done_count == 1)
            else $fatal(1, "fft_frame_done count mismatch: %0d",
                        fft_done_count);
        assert (power_done_count == 1)
            else $fatal(1, "power_frame_done count mismatch: %0d",
                        power_done_count);

        // 注入一个错误帧首，检查粘滞错误及clear_error。
        stop_output_check = 1'b1;
        send_fft_sample(0, 1'b0, 1'b0);
        @(negedge clk);
        fft_valid = 1'b0;
        repeat (2) @(posedge clk);
        assert (protocol_error)
            else $fatal(1, "Protocol error was not detected");

        @(negedge clk);
        clear_error = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear_error = 1'b0;
        @(posedge clk);
        assert (!protocol_error)
            else $fatal(1, "clear_error did not clear protocol_error");

        $display("TEST PASSED: power_spectrum_calculator");
        $finish;
    end

    initial begin
        #3_000_000;
        $fatal(1, "TEST TIMEOUT");
    end

endmodule

`default_nettype wire
