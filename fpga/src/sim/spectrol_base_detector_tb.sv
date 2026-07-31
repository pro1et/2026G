`timescale 1ns/1ps
`default_nettype none

module spectrol_base_detector_tb;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic clear_error = 1'b0;
    logic start = 1'b0;

    wire busy;
    wire spectrum_write_done;
    wire frame_done;
    wire protocol_error;

    logic [31:0] power_data = 32'd0;
    logic [10:0] power_bin = 11'd0;
    logic power_valid = 1'b0;
    wire  power_ready;
    logic power_first = 1'b0;
    logic power_last = 1'b0;

    wire base_start;
    wire base_busy;
    wire base_done;
    wire base_valid;
    wire [15:0] base_index_500;
    wire [10:0] base_bin;
    wire [34:0] base_energy;
    wire base_mem_req;
    wire [10:0] base_mem_addr;
    wire base_mem_ready;
    wire base_mem_rvalid;
    wire [31:0] base_mem_rdata;

    wire spectrum_bram_en;
    wire spectrum_bram_we;
    wire [10:0] spectrum_bram_addr;
    wire [31:0] spectrum_bram_din;
    logic [31:0] spectrum_bram_dout = 32'd0;

    logic [31:0] bram_model [0:2047];
    logic read_valid_d1 = 1'b0;
    logic [10:0] read_addr_d1 = 11'd0;

    integer write_count = 0;
    integer read_count = 0;
    integer base_start_count = 0;
    integer frame_done_count = 0;
    integer index;
    integer timeout;

    always #5 clk = ~clk;

    spectrol #(
        .BRAM_RD_LATENCY(2)
    ) u_spectrol (
        .clk                 (clk),
        .rst                 (rst),
        .clear_error         (clear_error),
        .start               (start),
        .busy                (busy),
        .spectrum_write_done (spectrum_write_done),
        .frame_done          (frame_done),
        .protocol_error      (protocol_error),
        .power_data          (power_data),
        .power_bin           (power_bin),
        .power_valid         (power_valid),
        .power_ready         (power_ready),
        .power_first         (power_first),
        .power_last          (power_last),
        .base_start          (base_start),
        .base_done           (base_done),
        .base_valid          (base_valid),
        .base_mem_req        (base_mem_req),
        .base_mem_addr       (base_mem_addr),
        .base_mem_ready      (base_mem_ready),
        .base_mem_rvalid     (base_mem_rvalid),
        .base_mem_rdata      (base_mem_rdata),
        .spectrum_bram_en    (spectrum_bram_en),
        .spectrum_bram_we    (spectrum_bram_we),
        .spectrum_bram_addr  (spectrum_bram_addr),
        .spectrum_bram_din   (spectrum_bram_din),
        .spectrum_bram_dout  (spectrum_bram_dout)
    );

    base_detector u_base_detector (
        .clk                  (clk),
        .rst                  (rst),
        .start                (base_start),
        .detect_threshold     (35'd10000),
        .prominence_threshold (35'd50),
        .busy                 (base_busy),
        .mem_req              (base_mem_req),
        .mem_addr             (base_mem_addr),
        .mem_ready            (base_mem_ready),
        .mem_rvalid           (base_mem_rvalid),
        .mem_rdata            (base_mem_rdata),
        .base_valid           (base_valid),
        .base_done            (base_done),
        .base_index_500       (base_index_500),
        .base_bin             (base_bin),
        .base_energy          (base_energy)
    );

    function automatic logic [31:0] spectrum_value(input integer bin_index);
        begin
            case (bin_index)
                38: spectrum_value = 32'd100;
                39: spectrum_value = 32'd400;
                40: spectrum_value = 32'd2000;
                41: spectrum_value = 32'd10000;
                42: spectrum_value = 32'd2000;
                43: spectrum_value = 32'd400;
                44: spectrum_value = 32'd100;
                default: spectrum_value = 32'd10;
            endcase
        end
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
            @(negedge clk);
            power_data  <= spectrum_value(bin_index);
            power_bin   <= bin_index[10:0];
            power_valid <= 1'b1;
            power_first <= (bin_index == 0);
            power_last  <= (bin_index == 2047);

            do begin
                @(posedge clk);
            end while (!power_ready);
        end
    endtask

    // 双周期读取模型：请求采样后的下一时钟更新dout，与LATENCY=2的rvalid对齐。
    always_ff @(posedge clk) begin
        if (rst) begin
            spectrum_bram_dout <= 32'd0;
            read_valid_d1      <= 1'b0;
            read_addr_d1       <= 11'd0;
            write_count        <= 0;
            read_count         <= 0;
            base_start_count   <= 0;
            frame_done_count   <= 0;
        end else begin
            read_valid_d1 <= spectrum_bram_en && !spectrum_bram_we;

            if (spectrum_bram_en && spectrum_bram_we) begin
                bram_model[spectrum_bram_addr] <= spectrum_bram_din;
                write_count <= write_count + 1;
            end

            if (spectrum_bram_en && !spectrum_bram_we) begin
                read_addr_d1 <= spectrum_bram_addr;
                read_count   <= read_count + 1;
            end

            if (read_valid_d1) begin
                spectrum_bram_dout <= bram_model[read_addr_d1];
            end

            if (base_start) begin
                base_start_count <= base_start_count + 1;
            end

            if (frame_done) begin
                frame_done_count <= frame_done_count + 1;
            end
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst <= 1'b0;

        pulse_start();

        for (index = 0; index < 2048; index = index + 1) begin
            send_power(index);
        end
        @(negedge clk);
        power_valid <= 1'b0;
        power_first <= 1'b0;
        power_last  <= 1'b0;

        timeout = 0;
        while (!frame_done && timeout < 2000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        assert (frame_done)
            else $fatal(1, "Timeout waiting for integrated frame_done");
        @(posedge clk);
        #1;

        assert (write_count == 2048)
            else $fatal(1, "Expected 2048 spectrum writes, got %0d", write_count);
        assert (base_start_count == 1)
            else $fatal(1, "Expected one base_start, got %0d", base_start_count);
        assert (frame_done_count == 1)
            else $fatal(1, "Expected one frame_done, got %0d", frame_done_count);
        assert (base_valid && base_bin == 11'd41)
            else $fatal(
                1, "Integrated base result mismatch: valid=%0b bin=%0d",
                base_valid, base_bin);
        assert (base_index_500 == 16'd40 && base_energy == 35'd15000)
            else $fatal(1, "Integrated base conversion/energy mismatch");
        assert (read_count < 100)
            else $fatal(1, "Integrated detector did not stop at first peak");
        assert (!busy && !base_busy && !protocol_error)
            else $fatal(1, "Integrated pipeline did not return cleanly to idle");

        $display("TEST PASSED: spectrol_base_detector");
        $finish;
    end

endmodule

`default_nettype wire
