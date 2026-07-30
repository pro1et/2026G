`timescale 1ns/1ps
`default_nettype none

// Combinational three-way fanout for the filtered measurement stream.
// All consumers are non-blocking, so the splitter does not need ready signals
// or internal storage. Frame markers are duplicated with the valid sample.
module measurement_stream_splitter (
    input  wire logic signed [15:0] in_data,
    input  wire logic               in_valid,
    input  wire logic               in_first,
    input  wire logic               in_last,

    output wire logic signed [15:0] vpp_data,
    output wire logic               vpp_valid,
    output wire logic               vpp_first,
    output wire logic               vpp_last,

    output wire logic signed [15:0] mean_square_data,
    output wire logic               mean_square_valid,
    output wire logic               mean_square_first,
    output wire logic               mean_square_last,

    output wire logic signed [15:0] wave_data,
    output wire logic               wave_valid,
    output wire logic               wave_first,
    output wire logic               wave_last
);

    assign vpp_data          = in_data;
    assign vpp_valid         = in_valid;
    assign vpp_first         = in_first;
    assign vpp_last          = in_last;
    assign mean_square_data  = in_data;
    assign mean_square_valid = in_valid;
    assign mean_square_first = in_first;
    assign mean_square_last  = in_last;
    assign wave_data         = in_data;
    assign wave_valid        = in_valid;
    assign wave_first        = in_first;
    assign wave_last         = in_last;

endmodule

`default_nettype wire
