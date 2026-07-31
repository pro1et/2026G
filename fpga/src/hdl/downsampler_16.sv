`timescale 1ns/1ps
`default_nettype none

// Fixed 16:1 decimator for one 65536-sample FIR frame.  The FIR source cannot
// be backpressured, so a one-entry output holding register reports overrun if
// the downstream fails to accept a retained sample before the next one arrives.
module downsampler_16 #(
    parameter int unsigned DATA_WIDTH        = 16,
    parameter int unsigned INPUT_FRAME_SIZE  = 65536,
    parameter int unsigned DECIMATION_FACTOR = 16
) (
    input  wire logic                         clk,
    input  wire logic                         rst,
    input  wire logic                         clear_error,

    input  wire logic signed [DATA_WIDTH-1:0] fir_data,
    input  wire logic                         fir_valid,
    input  wire logic                         fir_first,
    input  wire logic                         fir_last,

    output      logic signed [DATA_WIDTH-1:0] decim_data,
    output      logic                         decim_valid,
    input  wire logic                         decim_ready,
    output      logic                         decim_first,
    output      logic                         decim_last,

    output      logic                         busy,
    output      logic                         input_frame_done,
    output      logic                         decim_frame_done,
    output      logic                         frame_valid,
    output      logic                         protocol_error,
    output      logic                         overrun_error
);

    localparam int unsigned INPUT_INDEX_WIDTH = $clog2(INPUT_FRAME_SIZE);
    localparam int unsigned OUTPUT_FRAME_SIZE = INPUT_FRAME_SIZE / DECIMATION_FACTOR;
    localparam int unsigned OUTPUT_INDEX_WIDTH = $clog2(OUTPUT_FRAME_SIZE);
    localparam logic [INPUT_INDEX_WIDTH-1:0] LAST_INPUT_INDEX =
        INPUT_INDEX_WIDTH'(INPUT_FRAME_SIZE - 1);
    localparam logic [OUTPUT_INDEX_WIDTH-1:0] LAST_OUTPUT_INDEX =
        OUTPUT_INDEX_WIDTH'(OUTPUT_FRAME_SIZE - 1);

    logic [INPUT_INDEX_WIDTH-1:0]  input_index;
    logic [3:0]                    phase_count;
    logic [OUTPUT_INDEX_WIDTH-1:0] output_index;
    logic                          frame_error;

    wire logic output_fire = decim_valid && decim_ready;
    wire logic start_sample = !busy && fir_valid && fir_first;
    wire logic selected_sample = start_sample ||
        (busy && fir_valid && (phase_count == 4'd0));
    wire logic output_slot_available = !decim_valid || decim_ready;
    wire logic selection_overrun = selected_sample && !output_slot_available;
    wire logic input_marker_error = busy && fir_valid &&
        (fir_first || (fir_last != (input_index == LAST_INPUT_INDEX)));

    initial begin
        assert (DATA_WIDTH == 16)
            else $fatal(1, "downsampler_16 supports DATA_WIDTH=16 only");
        assert (INPUT_FRAME_SIZE == 65536)
            else $fatal(1, "downsampler_16 supports INPUT_FRAME_SIZE=65536 only");
        assert (DECIMATION_FACTOR == 16)
            else $fatal(1, "downsampler_16 supports DECIMATION_FACTOR=16 only");
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            input_index      <= '0;
            phase_count      <= 4'd0;
            output_index     <= '0;
            frame_error      <= 1'b0;
            decim_data       <= '0;
            decim_valid      <= 1'b0;
            decim_first      <= 1'b0;
            decim_last       <= 1'b0;
            busy             <= 1'b0;
            input_frame_done <= 1'b0;
            decim_frame_done <= 1'b0;
            frame_valid      <= 1'b0;
            protocol_error   <= 1'b0;
            overrun_error    <= 1'b0;
        end else begin
            input_frame_done <= 1'b0;
            decim_frame_done <= output_fire && decim_last;
            frame_valid      <= 1'b0;

            if (clear_error) begin
                protocol_error <= 1'b0;
                overrun_error  <= 1'b0;
            end

            if (output_fire) begin
                decim_valid <= 1'b0;
                decim_first <= 1'b0;
                decim_last  <= 1'b0;
            end

            if (!busy) begin
                if (fir_valid && !fir_first) begin
                    protocol_error <= 1'b1;
                end

                if (start_sample) begin
                    busy         <= 1'b1;
                    input_index  <= INPUT_INDEX_WIDTH'(1);
                    phase_count  <= 4'd1;
                    output_index <= OUTPUT_INDEX_WIDTH'(1);
                    frame_error  <= fir_last;

                    if (fir_last) begin
                        protocol_error <= 1'b1;
                    end

                    if (output_slot_available) begin
                        decim_data  <= fir_data;
                        decim_valid <= 1'b1;
                        decim_first <= 1'b1;
                        decim_last  <= (OUTPUT_FRAME_SIZE == 1);
                    end else begin
                        frame_error   <= 1'b1;
                        overrun_error <= 1'b1;
                    end
                end
            end else if (fir_valid) begin
                if (input_marker_error) begin
                    frame_error    <= 1'b1;
                    protocol_error <= 1'b1;
                end

                if (phase_count == 4'd15) begin
                    phase_count <= 4'd0;
                end else begin
                    phase_count <= phase_count + 1'b1;
                end

                if (selected_sample) begin
                    if (output_slot_available) begin
                        decim_data  <= fir_data;
                        decim_valid <= 1'b1;
                        decim_first <= 1'b0;
                        decim_last  <= (output_index == LAST_OUTPUT_INDEX);
                    end else begin
                        frame_error   <= 1'b1;
                        overrun_error <= 1'b1;
                    end

                    if (output_index != LAST_OUTPUT_INDEX) begin
                        output_index <= output_index + 1'b1;
                    end
                end

                if (input_index == LAST_INPUT_INDEX) begin
                    busy             <= 1'b0;
                    input_index      <= '0;
                    phase_count      <= 4'd0;
                    output_index     <= '0;
                    input_frame_done <= 1'b1;
                    frame_valid      <= !(frame_error || input_marker_error ||
                                          selection_overrun);
                    frame_error      <= 1'b0;
                end else begin
                    input_index <= input_index + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
