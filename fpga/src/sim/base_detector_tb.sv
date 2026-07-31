`timescale 1ns/1ps
`default_nettype none

module base_detector_tb;

    localparam int ENERGY_WIDTH = 35;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic [ENERGY_WIDTH-1:0] detect_threshold = 35'd10000;
    logic [ENERGY_WIDTH-1:0] prominence_threshold = 35'd50;

    wire busy;
    wire mem_req;
    wire [10:0] mem_addr;
    logic mem_ready;
    logic mem_rvalid = 1'b0;
    logic [31:0] mem_rdata = 32'd0;

    wire base_valid;
    wire base_done;
    wire [15:0] base_index_500;
    wire [10:0] base_bin;
    wire [ENERGY_WIDTH-1:0] base_energy;

    logic [31:0] memory [0:2047];
    logic model_pending = 1'b0;
    logic [10:0] model_addr = 11'd0;
    logic [1:0] model_delay = 2'd0;
    integer cycle_count = 0;
    integer request_count = 0;
    integer done_count = 0;
    integer second_request_start = 0;
    integer index;

    always #5 clk = ~clk;

    base_detector dut (
        .clk                  (clk),
        .rst                  (rst),
        .start                (start),
        .detect_threshold     (detect_threshold),
        .prominence_threshold (prominence_threshold),
        .busy                 (busy),
        .mem_req              (mem_req),
        .mem_addr             (mem_addr),
        .mem_ready            (mem_ready),
        .mem_rvalid           (mem_rvalid),
        .mem_rdata            (mem_rdata),
        .base_valid           (base_valid),
        .base_done            (base_done),
        .base_index_500       (base_index_500),
        .base_bin             (base_bin),
        .base_energy          (base_energy)
    );

    assign mem_ready = !model_pending && ((cycle_count % 5) != 2);

    task automatic pulse_start;
        begin
            @(negedge clk);
            start <= 1'b1;
            @(negedge clk);
            start <= 1'b0;
        end
    endtask

    task automatic wait_done;
        integer timeout;
        begin
            timeout = 0;
            while (!base_done && timeout < 20000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            assert (base_done)
                else $fatal(1, "Timeout waiting for base_done");
            @(posedge clk);
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            mem_rvalid    <= 1'b0;
            mem_rdata     <= 32'd0;
            model_pending <= 1'b0;
            model_addr    <= 11'd0;
            model_delay   <= 2'd0;
            cycle_count   <= 0;
            request_count <= 0;
            done_count    <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            mem_rvalid  <= 1'b0;

            if (mem_req && mem_ready) begin
                model_pending <= 1'b1;
                model_addr    <= mem_addr;
                model_delay   <= 2'd2;
                request_count <= request_count + 1;
            end

            if (model_pending) begin
                if (model_delay == 2'd1) begin
                    mem_rvalid    <= 1'b1;
                    mem_rdata     <= memory[model_addr];
                    model_pending <= 1'b0;
                    model_delay   <= 2'd0;
                end else begin
                    model_delay <= model_delay - 1'b1;
                end
            end

            if (base_done) begin
                done_count <= done_count + 1;
            end
        end
    end

    initial begin
        for (index = 0; index < 2048; index = index + 1) begin
            memory[index] = 32'd10;
        end

        // 以bin 41为中心构造可重复的Hann型主瓣。
        memory[38] = 32'd100;
        memory[39] = 32'd400;
        memory[40] = 32'd2000;
        memory[41] = 32'd10000;
        memory[42] = 32'd2000;
        memory[43] = 32'd400;
        memory[44] = 32'd100;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst <= 1'b0;

        pulse_start();
        wait_done();

        assert (base_valid)
            else $fatal(1, "Expected a valid base frequency");
        assert (base_bin == 11'd41)
            else $fatal(1, "base_bin mismatch: got %0d expected 41", base_bin);
        assert (base_index_500 == 16'd40)
            else $fatal(
                1, "base_index_500 mismatch: got %0d expected 40",
                base_index_500);
        assert (base_energy == 35'd15000)
            else $fatal(
                1, "base_energy mismatch: got %0d expected 15000",
                base_energy);
        assert (request_count < 100)
            else $fatal(1, "Detector failed to stop after first peak");

        // 第二帧使用纯底噪，验证完整扫描后的未检出结果。
        for (index = 0; index < 2048; index = index + 1) begin
            memory[index] = 32'd10;
        end
        second_request_start = request_count;

        pulse_start();
        wait_done();

        assert (!base_valid)
            else $fatal(1, "Noise-only spectrum should not produce a base");
        assert ((request_count - second_request_start) == (2044 - 17 + 1))
            else $fatal(
                1, "Full-scan request count mismatch: got %0d",
                request_count - second_request_start);
        assert (done_count == 2)
            else $fatal(1, "Expected two base_done pulses, got %0d", done_count);

        $display("TEST PASSED: base_detector");
        $finish;
    end

endmodule

`default_nettype wire
