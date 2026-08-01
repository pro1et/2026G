`timescale 1ns/1ps
`default_nettype none

// Minimal ADS6149 channel-A acquisition top for Vivado ILA verification.
//
// This module intentionally excludes FIFO, FIR, FFT, BRAM and PS control.
// The external ADC is driven by the Clock Wizard 32 MHz clock, while its
// 14-bit parallel output is captured by adc_capture on the same internal
// 32 MHz clock domain.  The debug ports are intended to connect directly to
// an ILA instantiated in a Block Design.
module adc_ila_test_top (
    input  wire        clk_50m,
    input  wire        rst_n,
    input  wire [13:0] adc_data_a,

    output wire        adc_clk_a,

    output wire        ila_clk,
    output wire [13:0] ila_adc_raw,
    output wire [15:0] ila_adc_sample,
    output wire        ila_adc_valid,
    output wire        ila_reset,
    output wire        ila_locked
);

    wire               clk_100m_unused;
    wire               clk_32m;
    wire               clk_32m_adc;
    wire               rst_100m_unused;
    wire               rst_32m;
    wire               clock_locked;
    wire signed [15:0] adc_sample;
    wire               adc_valid;
    reg  [13:0]        adc_raw_debug;

    clock_tree u_clock_tree (
        .clk_50m     (clk_50m),
        .rst_n       (rst_n),
        .clk_100m    (clk_100m_unused),
        .clk_32m     (clk_32m),
        .clk_32m_adc (clk_32m_adc),
        .rst_100m    (rst_100m_unused),
        .rst_32m     (rst_32m),
        .locked      (clock_locked)
    );

    adc_capture u_adc_capture (
        .clk_sample  (clk_32m),
        .clk_drive   (clk_32m_adc),
        .rst         (rst_32m),
        .adc_data_a  (adc_data_a),
        .adc_clk_a   (adc_clk_a),
        .data_a      (adc_sample),
        .out_valid_a (adc_valid)
    );

    // Register a second copy of the raw bus so ila_adc_raw and ila_adc_sample
    // describe the same sample when the ILA captures both on its next edge.
    always @(posedge clk_32m) begin
        if (rst_32m) begin
            adc_raw_debug <= 14'd0;
        end else begin
            adc_raw_debug <= adc_data_a;
        end
    end

    // ILA clock and probes. For every valid sample, the expected relationship
    // is ila_adc_sample == signed(ila_adc_raw) * 4.
    assign ila_clk        = clk_32m;
    assign ila_adc_raw    = adc_raw_debug;
    assign ila_adc_sample = adc_sample;
    assign ila_adc_valid  = adc_valid;
    assign ila_reset      = rst_32m;
    assign ila_locked     = clock_locked;

endmodule

`default_nettype wire
