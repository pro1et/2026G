`timescale 1ns/1ps
`default_nettype none

module base_detector_tb;

    localparam int ENERGY_WIDTH = 35;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic [ENERGY_WIDTH-1:0] detect_threshold = 35'd1;
    logic [ENERGY_WIDTH-1:0] prominence_threshold = 35'd16;

    wire busy;
    wire mem_req;
    wire [10:0] mem_addr;
    wire mem_ready;
    logic mem_rvalid = 1'b0;
    logic [31:0] mem_rdata = 32'd0;

    wire base_valid;
    wire base_done;
    wire [15:0] base_index_500;
    wire [10:0] base_bin;
    wire [ENERGY_WIDTH-1:0] base_energy;

    logic [31:0] memory [0:2047];

    integer index;
    integer test_count = 0;
    integer done_count = 0;

    always #5 clk = ~clk;

    assign mem_ready = 1'b1;

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

    /*
     * One-cycle read-response model. The DUT deliberately permits only one
     * outstanding request, but may issue the next request while consuming the
     * current response.
     */
    always_ff @(posedge clk) begin
        if (rst) begin
            mem_rvalid <= 1'b0;
            mem_rdata  <= 32'd0;
            done_count <= 0;
        end else begin
            mem_rvalid <= mem_req && mem_ready;
            if (mem_req && mem_ready) begin
                mem_rdata <= memory[mem_addr];
            end
            if (base_done) begin
                done_count <= done_count + 1;
            end
        end
    end

    task automatic clear_spectrum(input logic [31:0] floor_value);
        begin
            for (index = 0; index < 2048; index = index + 1) begin
                memory[index] = floor_value;
            end
        end
    endtask

    task automatic pulse_start;
        begin
            while (busy) begin
                @(posedge clk);
            end
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
            while (!base_done && timeout < 50000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            assert (base_done)
                else $fatal(1, "Timeout waiting for base_done");
            @(posedge clk);
        end
    endtask

    task automatic expect_valid_result(
        input integer expected_bin,
        input integer expected_index_500,
        input integer expected_energy,
        input string  case_name
    );
        begin
            pulse_start();
            wait_done();
            test_count = test_count + 1;

            assert (base_valid)
                else $fatal(1, "%s: expected base_valid", case_name);
            assert (base_bin == expected_bin)
                else $fatal(
                    1, "%s: base_bin=%0d expected=%0d",
                    case_name, base_bin, expected_bin
                );
            assert (base_index_500 == expected_index_500)
                else $fatal(
                    1, "%s: base_index_500=%0d expected=%0d",
                    case_name, base_index_500, expected_index_500
                );
            assert (base_energy == expected_energy)
                else $fatal(
                    1, "%s: base_energy=%0d expected=%0d",
                    case_name, base_energy, expected_energy
                );

            $display(
                "PASS %-30s bin=%0d index500=%0d energy=%0d",
                case_name, base_bin, base_index_500, base_energy
            );
        end
    endtask

    task automatic expect_invalid_result(input string case_name);
        begin
            pulse_start();
            wait_done();
            test_count = test_count + 1;

            assert (!base_valid)
                else $fatal(
                    1, "%s: unexpected base bin %0d",
                    case_name, base_bin
                );
            assert ((base_bin == 0) &&
                    (base_index_500 == 0) &&
                    (base_energy == 0))
                else $fatal(1, "%s: invalid-result outputs not zero", case_name);

            $display("PASS %-30s no valid base", case_name);
        end
    endtask

    initial begin
        clear_spectrum(32'd0);

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst <= 1'b0;

        /*
         * Case 1: a single credible tone has no harmonic support and must use
         * the stricter pure-tone fallback.
         */
        clear_spectrum(32'd0);
        memory[205] = 32'd100;
        expect_valid_result(205, 200, 100, "pure-tone fallback");

        /*
         * Case 2: the fundamental is deliberately weak, while its second and
         * third harmonics are strong. Harmonic-family scoring must recover
         * bin 100 instead of selecting the strongest peak at bin 200.
         */
        clear_spectrum(32'd0);
        memory[100] = 32'd2;
        memory[200] = 32'd40;
        memory[300] = 32'd25;
        expect_valid_result(100, 98, 2, "weak base plus harmonics");

        /*
         * Case 3: a three-bin plateau must be represented by its deterministic
         * center bin. Seven-bin energy is 10 + 10 + 10 = 30.
         */
        clear_spectrum(32'd0);
        memory[300] = 32'd10;
        memory[301] = 32'd10;
        memory[302] = 32'd10;
        expect_valid_result(301, 294, 30, "flat-top center");

        /*
         * Case 4: floor=1 produces adaptive threshold 12*7*1=84. A small
         * isolated peak has seven-bin energy 16 and must be rejected.
         */
        clear_spectrum(32'd1);
        memory[150] = 32'd10;
        expect_invalid_result("adaptive-noise rejection");

        /* Case 5: an empty spectrum must not produce a false base. */
        clear_spectrum(32'd0);
        expect_invalid_result("empty spectrum");

        assert (done_count == test_count)
            else $fatal(
                1, "base_done pulse count=%0d expected=%0d",
                done_count, test_count
            );

        $display(
            "TEST PASSED: base_detector new algorithm (%0d cases)",
            test_count
        );
        $finish;
    end

endmodule

`default_nettype wire
