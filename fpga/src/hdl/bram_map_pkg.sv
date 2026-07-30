`timescale 1ns/1ps
`default_nettype none

package bram_map_pkg;

    localparam int unsigned BRAM_WORD_WIDTH = 32;
    localparam int unsigned TIME_SAMPLE_COUNT = 32768;
    localparam int unsigned SPEC_POINT_COUNT  = 1024;

    // Time BRAM word addresses.
    localparam int unsigned T_VPP_RAW       = 0;
    localparam int unsigned T_VRMS_SQ_RAW   = 1;
    localparam int unsigned T_F1_HZ         = 2;
    localparam int unsigned T_SAMPLE_COUNT  = 3;
    localparam int unsigned T_DATA_BASE     = 4;
    localparam int unsigned T_DATA_WORDS    = TIME_SAMPLE_COUNT / 2;
    localparam int unsigned T_TOTAL_WORDS   = T_DATA_BASE + T_DATA_WORDS;

    // Spectrum BRAM word addresses.
    localparam int unsigned S_PEAK_COUNT      = 0;
    localparam int unsigned S_F1_HZ           = 1;
    localparam int unsigned S_A1_RAW          = 2;
    localparam int unsigned S_F2_HZ           = 3;
    localparam int unsigned S_A2_RAW          = 4;
    localparam int unsigned S_F3_HZ           = 5;
    localparam int unsigned S_A3_RAW          = 6;
    localparam int unsigned S_SPECTRUM_COUNT  = 7;
    localparam int unsigned S_DATA_BASE       = 8;
    localparam int unsigned S_DATA_WORDS      = SPEC_POINT_COUNT / 2;
    localparam int unsigned S_TOTAL_WORDS     = S_DATA_BASE + S_DATA_WORDS;

endpackage

`default_nettype wire
