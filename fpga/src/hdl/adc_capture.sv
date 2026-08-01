`timescale 1ns/1ps
`default_nettype none

// ADS6149 channel-A capture interface.
// The ADC is driven and sampled from the Clock Wizard 32 MHz domain.  Each
// clk_sample edge captures the result launched by an earlier forwarded ADC
// clock edge.  The 14-bit two's-complement sample is shifted left by two bits
// to fill the signed 16-bit processing path.
module adc_capture #(
    parameter int unsigned STARTUP_CYCLES = 8
) (
    input  wire logic               clk_sample,
    input  wire logic               clk_drive,
    input  wire logic               rst,
    input  wire logic [13:0]        adc_data_a,
    output wire logic               adc_clk_a,
    output      logic signed [15:0] data_a,
    output      logic               out_valid_a
);

    localparam int unsigned COUNT_WIDTH =
        (STARTUP_CYCLES <= 1) ? 1 : $clog2(STARTUP_CYCLES + 1);
    localparam logic [COUNT_WIDTH-1:0] STARTUP_LAST =
        COUNT_WIDTH'(STARTUP_CYCLES - 1);

    logic [COUNT_WIDTH-1:0] startup_count_a;

    initial begin
        assert (STARTUP_CYCLES >= 1)
            else $fatal(1, "STARTUP_CYCLES must be at least 1");
    end

    // ADS6149 is configured for 14-bit two's-complement output.  Capturing and
    // appending two zero LSBs implements a signed x4 scale without extra logic:
    // -8192 -> -32768, 0 -> 0, +8191 -> +32764.
    (* IOB = "TRUE" *) always_ff @(posedge clk_sample) begin
        if (rst) begin
            data_a          <= 16'sd0;
            startup_count_a <= '0;
            out_valid_a     <= 1'b0;
        end else begin
            data_a <= $signed({adc_data_a, 2'b00});

            if (!out_valid_a) begin
                if (startup_count_a == STARTUP_LAST) begin
                    out_valid_a <= 1'b1;
                end else begin
                    startup_count_a <= startup_count_a + 1'b1;
                end
            end
        end
    end

    // Forward the 32 MHz clock with an ODDR so the external duty cycle follows
    // the dedicated clock network rather than ordinary fabric logic.
    ODDR #(
        .DDR_CLK_EDGE("OPPOSITE_EDGE"),
        .INIT        (1'b0),
        .SRTYPE      ("ASYNC")
    ) u_oddr_clk_a (
        .Q (adc_clk_a),
        .C (clk_drive),
        .CE(1'b1),
        .D1(1'b1),
        .D2(1'b0),
        .R (rst),
        .S (1'b0)
    );

endmodule

`default_nettype wire
