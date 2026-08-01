`timescale 1ns/1ps
`default_nettype none

module energy_calculator_tb;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic [15:0] base_index_500 = 16'd100;

    wire busy;
    wire done;
    wire mem_req;
    wire [10:0] mem_addr;
    logic mem_rvalid = 1'b0;
    logic [31:0] mem_rdata = 32'd0;
    wire result_bram_en;
    wire result_bram_we;
    wire [3:0] result_bram_addr;
    wire [31:0] result_bram_din;
    wire [2:0] harmonic_present_mask;
    wire [2:0] position_valid_mask;
    wire result_valid;
    wire energy_overflow;

    logic [31:0] spectrum [0:2047];
    logic [31:0] results [0:15];
    logic pending = 1'b0;
    logic [10:0] pending_addr = 11'd0;
    integer i;

    always #5 clk = ~clk;

    energy_calculator dut (
        .clk                   (clk),
        .rst                   (rst),
        .start                 (start),
        .busy                  (busy),
        .done                  (done),
        .base_valid            (1'b1),
        .base_index_500        (base_index_500),
        .absolute_threshold    (32'd100),
        .ratio_num             (16'd1),
        .ratio_den             (16'd100),
        .mem_req               (mem_req),
        .mem_addr              (mem_addr),
        .mem_ready             (!pending),
        .mem_rvalid            (mem_rvalid),
        .mem_rdata             (mem_rdata),
        .result_bram_en        (result_bram_en),
        .result_bram_we        (result_bram_we),
        .result_bram_addr      (result_bram_addr),
        .result_bram_din       (result_bram_din),
        .harmonic_present_mask (harmonic_present_mask),
        .position_valid_mask   (position_valid_mask),
        .result_valid          (result_valid),
        .energy_overflow       (energy_overflow)
    );

    function automatic integer to_bin(input integer index_500);
        to_bin = ((128 * index_500) + 62) / 125;
    endfunction

    task automatic clear_spectrum;
        begin
            for (i = 0; i < 2048; i = i + 1) begin
                spectrum[i] = 32'd0;
            end
        end
    endtask

    task automatic put_energy(
        input integer index_500,
        input logic [31:0] energy
    );
        integer center;
        begin
            center = to_bin(index_500);
            // Put all energy in the last member to check inclusion of return 7.
            spectrum[center + 3] = energy;
        end
    endtask

    task automatic run_frame;
        integer timeout;
        begin
            @(negedge clk);
            start <= 1'b1;
            @(negedge clk);
            start <= 1'b0;
            timeout = 0;
            while (!done && (timeout < 10000)) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            assert (done && result_valid && !energy_overflow)
                else $fatal(1, "generic harmonic scan timed out or failed");
            #1;
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            pending      <= 1'b0;
            pending_addr <= 11'd0;
            mem_rvalid   <= 1'b0;
            mem_rdata    <= 32'd0;
        end else begin
            mem_rvalid <= pending;
            if (pending) begin
                mem_rdata <= spectrum[pending_addr];
                pending   <= 1'b0;
            end
            if (mem_req && !pending) begin
                pending_addr <= mem_addr;
                pending      <= 1'b1;
            end
            if (result_bram_en && result_bram_we) begin
                results[result_bram_addr] <= result_bram_din;
            end
        end
    end

    initial begin
        clear_spectrum();
        for (i = 0; i < 16; i = i + 1) begin
            results[i] = 32'd0;
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst <= 1'b0;

        // 50 kHz base, with only orders 4 and 7 present.  The fixed H2/H3
        // implementation missed both; the generic scanner must return 4/7.
        base_index_500 = 16'd100;
        clear_spectrum();
        put_energy(100, 32'd800);
        put_energy(400, 32'd200);
        put_energy(700, 32'd300);
        run_frame();
        assert (harmonic_present_mask == 3'b111 &&
                position_valid_mask == 3'b111)
            else $fatal(1, "orders 4/7 were not both detected");
        assert (results[1] == 32'd100 && results[2] == 32'd100)
            else $fatal(1, "base result is incorrect");
        assert (results[3] == 32'd400 && results[4] == 32'd25 &&
                results[10] == 32'd4)
            else $fatal(1, "harmonic A is not order 4");
        assert (results[5] == 32'd700 && results[6] == 32'd38 &&
                results[11] == 32'd7)
            else $fatal(1, "harmonic B is not order 7");

        // A 500 kHz order-10 component is inclusive at index_500=1000.
        clear_spectrum();
        put_energy(100, 32'd800);
        put_energy(300, 32'd200);
        put_energy(1000, 32'd240);
        run_frame();
        assert (results[3] == 32'd300 && results[10] == 32'd3)
            else $fatal(1, "nearest harmonic is not order 3");
        assert (results[5] == 32'd1000 && results[6] == 32'd30 &&
                results[11] == 32'd10)
            else $fatal(1, "500 kHz boundary harmonic was not detected");

        $display("TEST PASSED: generic harmonic A/B scan and 500 kHz boundary");
        $finish;
    end

endmodule

`default_nettype wire
