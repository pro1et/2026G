`timescale 1ns/1ps
`default_nettype none

// Mean-square calculator for one 65536-sample signed frame.
//
// The signed square is registered in a DSP-oriented input stage.  The
// accumulator consumes that registered result on the following clock, and the
// frame result is rounded in a separate output stage.  The pipeline still
// accepts one input sample per clock.
module mean_square_calculator (
    input  wire logic               clk,
    input  wire logic               rst,

    input  wire logic signed [15:0] sample_in,
    input  wire logic               sample_valid,
    input  wire logic               sample_first,
    input  wire logic               sample_last,

    output      logic [31:0]        mean_square_out,
    output      logic               result_valid,
    output      logic               overflow
);

    localparam logic [48:0] ROUNDING_BIAS = 49'd32768;

    // Vivado can absorb this register into the DSP48 PREG, removing the
    // multiplier from the FIFO-output-to-accumulator timing path.
    (* use_dsp = "yes" *)
    logic [31:0] sample_square_pipe;
    logic        sample_valid_pipe;
    logic        sample_first_pipe;
    logic        sample_last_pipe;

    logic [47:0] square_sum;
    logic [15:0] sample_count;
    logic        frame_fault;

    logic [48:0] sum_with_sample;
    logic        marker_fault;

    logic [48:0] final_sum_reg;
    logic        final_fault_reg;
    logic        final_pending;
    logic [48:0] rounded_final_sum;

    always_comb begin
        sum_with_sample =
            {1'b0, square_sum} + {17'd0, sample_square_pipe};
        marker_fault =
            (sample_first_pipe != (sample_count == 16'h0000)) ||
            (sample_last_pipe  != (sample_count == 16'hffff));
        rounded_final_sum = final_sum_reg + ROUNDING_BIAS;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sample_square_pipe <= 32'd0;
            sample_valid_pipe  <= 1'b0;
            sample_first_pipe  <= 1'b0;
            sample_last_pipe   <= 1'b0;
            square_sum         <= 48'd0;
            sample_count       <= 16'd0;
            frame_fault        <= 1'b0;
            final_sum_reg      <= 49'd0;
            final_fault_reg    <= 1'b0;
            final_pending      <= 1'b0;
            mean_square_out    <= 32'd0;
            result_valid       <= 1'b0;
            overflow           <= 1'b0;
        end else begin
            // Signed multiplication directly covers -32768 without a
            // magnitude/negation path in front of the DSP.
            sample_square_pipe <= $signed(sample_in) * $signed(sample_in);
            sample_valid_pipe  <= sample_valid;
            sample_first_pipe  <= sample_first;
            sample_last_pipe   <= sample_last;

            result_valid  <= final_pending;
            final_pending <= 1'b0;

            if (final_pending) begin
                mean_square_out <= rounded_final_sum[47:16];
                overflow <= final_fault_reg || rounded_final_sum[48];
            end

            if (sample_valid_pipe) begin
                if (sample_count == 16'hffff) begin
                    // Capture the complete frame sum first.  Rounding and
                    // output occur on the next clock from this register.
                    final_sum_reg   <= sum_with_sample;
                    final_fault_reg <= frame_fault || marker_fault ||
                                       sum_with_sample[48];
                    final_pending   <= 1'b1;

                    square_sum   <= 48'd0;
                    sample_count <= 16'd0;
                    frame_fault  <= 1'b0;
                end else begin
                    square_sum   <= sum_with_sample[47:0];
                    sample_count <= sample_count + 1'b1;
                    frame_fault  <= frame_fault || marker_fault ||
                                    sum_with_sample[48];
                end
            end
        end
    end

endmodule

`default_nettype wire
