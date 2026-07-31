`timescale 1ns/1ps
`default_nettype none

module spectrol_tb;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic clear_error = 1'b0;

    logic start = 1'b0;
    wire  busy;
    wire  frame_done;
    wire  protocol_error;

    logic [31:0] power_data = 32'd0;
    logic [10:0] power_bin = 11'd0;
    logic        power_valid = 1'b0;
    wire         power_ready;
    logic        power_first = 1'b0;
    logic        power_last = 1'b0;

    wire        spectrum_bram_en;
    wire        spectrum_bram_we;
    wire [10:0] spectrum_bram_addr;
    wire [31:0] spectrum_bram_din;

    logic [31:0] bram_model [0:2047];
    integer write_count = 0;
    integer done_count = 0;
    integer cycle_count = 0;
    integer index;

    always #5 clk = ~clk;

    spectrol dut (
        .clk                (clk),
        .rst                (rst),
        .clear_error        (clear_error),
        .start              (start),
        .busy               (busy),
        .frame_done         (frame_done),
        .protocol_error     (protocol_error),
        .power_data         (power_data),
        .power_bin          (power_bin),
        .power_valid        (power_valid),
        .power_ready        (power_ready),
        .power_first        (power_first),
        .power_last         (power_last),
        .spectrum_bram_en   (spectrum_bram_en),
        .spectrum_bram_we   (spectrum_bram_we),
        .spectrum_bram_addr (spectrum_bram_addr),
        .spectrum_bram_din  (spectrum_bram_din)
    );

    function automatic logic [31:0] expected_data(input integer bin_index);
        expected_data = 32'h1357_0000 ^ (bin_index * 32'd2654435761);
    endfunction

    task automatic pulse_start;
        begin
            @(negedge clk);
            start <= 1'b1;
            @(negedge clk);
            start <= 1'b0;
        end
    endtask

    task automatic send_power(input integer bin_index);
        begin
            // 确定性地插入valid空泡，验证BRAM只在握手周期写入。
            if ((bin_index % 13) == 5) begin
                @(negedge clk);
                power_valid <= 1'b0;
            end

            @(negedge clk);
            power_data  <= expected_data(bin_index);
            power_bin   <= bin_index[10:0];
            power_first <= (bin_index == 0);
            power_last  <= (bin_index == 2047);
            power_valid <= 1'b1;

            do begin
                @(posedge clk);
            end while (!power_ready);

            @(negedge clk);
            power_valid <= 1'b0;
            power_first <= 1'b0;
            power_last  <= 1'b0;
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            write_count <= 0;
            done_count  <= 0;
            cycle_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;

            assert (spectrum_bram_en == spectrum_bram_we)
                else $fatal(1, "BRAM en/we mismatch");

            if (spectrum_bram_en) begin
                assert (busy)
                    else $fatal(1, "BRAM write while spectrol is idle");
                assert (spectrum_bram_addr == write_count[10:0])
                    else $fatal(
                        1, "BRAM address mismatch: got %0d expected %0d",
                        spectrum_bram_addr, write_count);
                assert (spectrum_bram_din == expected_data(write_count))
                    else $fatal(1, "BRAM data mismatch at bin %0d", write_count);

                bram_model[spectrum_bram_addr] <= spectrum_bram_din;
                write_count <= write_count + 1;
            end

            if (frame_done) begin
                done_count <= done_count + 1;
                assert (write_count == 2048)
                    else $fatal(
                        1, "frame_done before all writes: count=%0d",
                        write_count);
            end

            if (cycle_count > 10000) begin
                $fatal(1, "Timeout");
            end
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst <= 1'b0;

        // 空闲时不得接收或写入。
        power_valid <= 1'b1;
        power_bin   <= 11'd0;
        power_data  <= expected_data(0);
        power_first <= 1'b1;
        repeat (2) @(posedge clk);
        assert (!power_ready && !spectrum_bram_en && !busy)
            else $fatal(1, "Idle interface is not quiescent");
        @(negedge clk);
        power_valid <= 1'b0;
        power_first <= 1'b0;

        pulse_start();
        assert (busy && power_ready)
            else $fatal(1, "Spectrol did not enter WRITE state");

        for (index = 0; index < 2048; index = index + 1) begin
            send_power(index);
        end

        @(posedge clk);
        #1;
        assert (!busy && !power_ready)
            else $fatal(1, "Spectrol did not return to IDLE");
        assert (write_count == 2048)
            else $fatal(1, "Expected 2048 writes, got %0d", write_count);
        assert (done_count == 1)
            else $fatal(1, "Expected one frame_done pulse, got %0d", done_count);
        assert (!protocol_error)
            else $fatal(1, "Unexpected protocol_error after valid frame");

        for (index = 0; index < 2048; index = index + 1) begin
            assert (bram_model[index] == expected_data(index))
                else $fatal(1, "Stored BRAM data mismatch at bin %0d", index);
        end

        // 注入错误首点：bin不是0。错误数据不得写入BRAM，当前帧必须中止。
        pulse_start();
        @(negedge clk);
        power_valid <= 1'b1;
        power_bin   <= 11'd1;
        power_data  <= 32'hDEAD_BEEF;
        power_first <= 1'b0;
        power_last  <= 1'b0;
        @(posedge clk);
        @(negedge clk);
        power_valid <= 1'b0;

        @(posedge clk);
        #1;
        assert (protocol_error && !busy)
            else $fatal(1, "Malformed frame was not rejected");
        assert (write_count == 2048)
            else $fatal(1, "Malformed sample unexpectedly wrote BRAM");

        @(negedge clk);
        clear_error <= 1'b1;
        @(negedge clk);
        clear_error <= 1'b0;
        @(posedge clk);
        #1;
        assert (!protocol_error)
            else $fatal(1, "clear_error failed");

        $display("TEST PASSED: spectrol");
        $finish;
    end

endmodule

`default_nettype wire
