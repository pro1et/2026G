`timescale 1ns/1ps
`default_nettype none

// 行为级hann_rom_0模型，仅用于快速单元仿真；真实IP仿真时由宏将其排除。
`ifndef USE_REAL_HANN_ROM
module hann_rom_0 (
    input  wire logic        clka,
    input  wire logic        ena,
    input  wire logic [10:0] addra,
    output      logic [15:0] douta
);
    logic [15:0] memory [0:2047];
    integer index;
    real coefficient_real;

    initial begin
        for (index = 0; index < 2048; index = index + 1) begin
            coefficient_real = 0.5 *
                (1.0 - $cos(2.0 * 3.14159265358979323846 * index / 4096.0));
            memory[index] = $rtoi(coefficient_real * 32767.0 + 0.5);
        end
    end

    always_ff @(posedge clka) begin
        if (ena) begin
            douta <= memory[addra];
        end
    end
endmodule
`endif

module hann_window_4096_tb;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic clear_error = 1'b0;

    logic signed [15:0] sample_data = 16'sd0;
    logic               sample_valid = 1'b0;
    wire                sample_ready;
    logic               sample_first = 1'b0;
    logic               sample_last = 1'b0;

    wire signed [15:0] window_data;
    wire               window_valid;
    logic              window_ready = 1'b0;
    wire               window_first;
    wire               window_last;
    wire               protocol_error;

    integer input_count = 0;
    integer output_count = 0;
    integer expected_value;
    integer ready_stall_count = 0;

    always #5 clk = ~clk;

    hann_window_4096 dut (
        .clk            (clk),
        .rst            (rst),
        .clear_error    (clear_error),
        .sample_data    (sample_data),
        .sample_valid   (sample_valid),
        .sample_ready   (sample_ready),
        .sample_first   (sample_first),
        .sample_last    (sample_last),
        .window_data    (window_data),
        .window_valid   (window_valid),
        .window_ready   (window_ready),
        .window_first   (window_first),
        .window_last    (window_last),
        .protocol_error (protocol_error)
    );

    function automatic integer input_sample(input integer sample_number);
        integer value;
        begin
            if (sample_number == 0) begin
                value = -512;
            end else if (sample_number == 2048) begin
                value = 511;
            end else if (sample_number == 4095) begin
                value = -511;
            end else begin
                value = ((sample_number * 73) % 1024) - 512;
            end
            input_sample = value;
        end
    endfunction

    function automatic integer hann_coefficient(input integer sample_number);
        real value;
        begin
            value = 0.5 *
                (1.0 - $cos(2.0 * 3.14159265358979323846 * sample_number /
                            4096.0));
            hann_coefficient = $rtoi(value * 32767.0 + 0.5);
        end
    endfunction

    function automatic integer expected_window(input integer sample_number);
        reg signed [63:0] product;
        reg signed [63:0] rounded;
        begin
            product = input_sample(sample_number) * hann_coefficient(sample_number);
            if (product >= 0) begin
                rounded = product + 64'sd16384;
            end else begin
                rounded = product + 64'sd16383;
            end
            expected_window = rounded >>> 15;
        end
    endfunction

    // 随机制造输出反压；限制连续反压长度，避免无意义地阻塞整个测试。
    always @(negedge clk) begin
        if (rst) begin
            window_ready <= 1'b0;
            ready_stall_count <= 0;
        end else if (ready_stall_count >= 5) begin
            window_ready <= 1'b1;
            ready_stall_count <= 0;
        end else if ($urandom_range(0, 4) == 0) begin
            window_ready <= 1'b0;
            ready_stall_count <= ready_stall_count + 1;
        end else begin
            window_ready <= 1'b1;
            ready_stall_count <= 0;
        end
    end

    always @(posedge clk) begin
        if (!rst && window_valid && window_ready) begin
            expected_value = expected_window(output_count);
            if ($signed(window_data) !== expected_value) begin
                $fatal(1,
                    "Output mismatch at n=%0d: actual=%0d expected=%0d",
                    output_count, $signed(window_data), expected_value);
            end
            if (window_first !== (output_count == 0)) begin
                $fatal(1, "window_first mismatch at n=%0d", output_count);
            end
            if (window_last !== (output_count == 4095)) begin
                $fatal(1, "window_last mismatch at n=%0d", output_count);
            end
            output_count <= output_count + 1;
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // 随机输入空拍并遵守valid-ready保持规则，发送完整4096点帧。
        for (input_count = 0; input_count < 4096; input_count = input_count + 1) begin
            repeat ($urandom_range(0, 3)) @(negedge clk);

            sample_data  = input_sample(input_count);
            sample_first = (input_count == 0);
            sample_last  = (input_count == 4095);
            sample_valid = 1'b1;

            do begin
                @(posedge clk);
            end while (!sample_ready);

            @(negedge clk);
            sample_valid = 1'b0;
            sample_first = 1'b0;
            sample_last  = 1'b0;
        end

        while (output_count < 4096) begin
            @(posedge clk);
        end
        repeat (5) @(posedge clk);

        if (protocol_error) begin
            $fatal(1, "protocol_error asserted during a valid frame");
        end

        // 错误帧标志应锁存错误，clear_error应能在空闲时清除。
        @(negedge clk);
        sample_data  = 16'sd1;
        sample_valid = 1'b1;
        sample_first = 1'b0;
        sample_last  = 1'b0;
        do begin
            @(posedge clk);
        end while (!sample_ready);
        @(negedge clk);
        sample_valid = 1'b0;

        repeat (2) @(posedge clk);
        if (!protocol_error) begin
            $fatal(1, "protocol_error did not latch on a missing first marker");
        end

        @(negedge clk);
        clear_error = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear_error = 1'b0;
        @(posedge clk);
        if (protocol_error) begin
            $fatal(1, "clear_error did not clear protocol_error");
        end

        $display("TEST PASSED: 4096 periodic-Hann samples matched");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "hann_window_4096 simulation timeout");
    end
endmodule

`default_nettype wire
