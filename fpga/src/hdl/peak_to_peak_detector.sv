`timescale 1ns/1ps
`default_nettype none

// Peak-to-peak detector with frame-end multi-cycle post-processing.
//
// Samples are divided into fixed-size segments.  The segment peak-to-peak
// values are stored while the frame is received.  After the last sample, the
// module scans those values, removes TRIM_COUNT values at each end, rounds the
// retained average, and performs the constant division serially.  Moving this
// work out of the last-sample cycle keeps the 100 MHz sample path short.
module peak_to_peak_detector #(
    parameter int unsigned DATA_WIDTH    = 16,
    parameter int unsigned FRAME_SIZE    = 65536,
    parameter int unsigned SEGMENT_COUNT = 16,
    parameter int unsigned SEGMENT_SIZE  = 4096,
    parameter int unsigned TRIM_COUNT    = 2
) (
    input  wire logic                         clk,
    input  wire logic                         rst,

    input  wire logic signed [DATA_WIDTH-1:0] sample_data,
    input  wire logic                         sample_valid,
    input  wire logic                         sample_first,
    input  wire logic                         sample_last,

    output      logic [31:0]                  vpp_out,
    output      logic                         vpp_valid,
    output      logic                         vpp_busy,
    output      logic                         vpp_error
);

    localparam int unsigned VPP_WIDTH = DATA_WIDTH;
    localparam int unsigned SUM_WIDTH = DATA_WIDTH + $clog2(SEGMENT_COUNT);
    localparam int unsigned SEGMENT_SAMPLE_INDEX_WIDTH =
        (SEGMENT_SIZE <= 1) ? 1 : $clog2(SEGMENT_SIZE);
    localparam int unsigned SEGMENT_INDEX_WIDTH =
        (SEGMENT_COUNT <= 1) ? 1 : $clog2(SEGMENT_COUNT);
    localparam int unsigned TRIM_INDEX_WIDTH =
        (TRIM_COUNT <= 1) ? 1 : $clog2(TRIM_COUNT);
    localparam int unsigned RETAINED_COUNT = SEGMENT_COUNT - (2 * TRIM_COUNT);
    localparam int unsigned DIV_WIDTH = SUM_WIDTH + 1;
    localparam int unsigned DIV_COUNT_WIDTH =
        (DIV_WIDTH <= 1) ? 1 : $clog2(DIV_WIDTH + 1);

    localparam logic [SEGMENT_SAMPLE_INDEX_WIDTH-1:0] LAST_SEGMENT_SAMPLE =
        SEGMENT_SAMPLE_INDEX_WIDTH'(SEGMENT_SIZE - 1);
    localparam logic [SEGMENT_INDEX_WIDTH-1:0] LAST_SEGMENT =
        SEGMENT_INDEX_WIDTH'(SEGMENT_COUNT - 1);
    localparam logic [TRIM_INDEX_WIDTH-1:0] LAST_TRIM_INDEX =
        TRIM_INDEX_WIDTH'(TRIM_COUNT - 1);
    localparam logic [DIV_WIDTH:0] DIVISOR_VALUE =
        (DIV_WIDTH + 1)'(RETAINED_COUNT);

    typedef enum logic [2:0] {
        STATE_COLLECT,
        STATE_SCAN,
        STATE_TRIM_INIT,
        STATE_TRIM,
        STATE_ROUND,
        STATE_DIV_INIT,
        STATE_DIVIDE
    } state_t;

    state_t state;

    logic [SEGMENT_SAMPLE_INDEX_WIDTH-1:0] segment_sample_index;
    logic [SEGMENT_INDEX_WIDTH-1:0]        segment_index;
    logic signed [DATA_WIDTH-1:0]          segment_max;
    logic signed [DATA_WIDTH-1:0]          segment_min;

    logic [VPP_WIDTH-1:0] segment_vpp [0:SEGMENT_COUNT-1];
    logic [SUM_WIDTH-1:0] vpp_sum;
    logic [SUM_WIDTH-1:0] total_sum_reg;

    logic [SEGMENT_INDEX_WIDTH-1:0] scan_index;
    logic [TRIM_INDEX_WIDTH-1:0]    trim_index;
    logic [VPP_WIDTH-1:0] largest_vpp  [0:TRIM_COUNT-1];
    logic [VPP_WIDTH-1:0] smallest_vpp [0:TRIM_COUNT-1];
    logic [VPP_WIDTH-1:0] largest_next  [0:TRIM_COUNT-1];
    logic [VPP_WIDTH-1:0] smallest_next [0:TRIM_COUNT-1];

    logic [SUM_WIDTH-1:0] trimmed_sum_reg;
    logic [DIV_WIDTH-1:0] rounded_numerator;

    logic [DIV_WIDTH-1:0] divide_dividend;
    logic [DIV_WIDTH-1:0] divide_quotient;
    logic [DIV_WIDTH:0]   divide_remainder;
    logic [DIV_COUNT_WIDTH-1:0] divide_count;

    logic signed [DATA_WIDTH-1:0] segment_max_with_sample;
    logic signed [DATA_WIDTH-1:0] segment_min_with_sample;
    logic signed [DATA_WIDTH:0]   segment_difference;
    logic [VPP_WIDTH-1:0]         completed_segment_vpp;
    logic [SUM_WIDTH-1:0]         total_sum_with_segment;
    logic                         marker_fault;

    logic [VPP_WIDTH-1:0] scan_value;
    logic [VPP_WIDTH-1:0] largest_carry;
    logic [VPP_WIDTH-1:0] smallest_carry;
    logic [VPP_WIDTH-1:0] largest_swap;
    logic [VPP_WIDTH-1:0] smallest_swap;
    logic [SUM_WIDTH-1:0] trim_subtract_value;

    logic [DIV_WIDTH:0]   divide_trial;
    logic [DIV_WIDTH:0]   divide_remainder_next;
    logic [DIV_WIDTH-1:0] divide_quotient_next;

    integer comb_index;
    integer seq_index;

    initial begin
        assert (DATA_WIDTH >= 2 && DATA_WIDTH <= 32)
            else $fatal(1, "DATA_WIDTH must be between 2 and 32");
        assert (SEGMENT_COUNT > 0 && SEGMENT_SIZE > 0)
            else $fatal(1, "SEGMENT_COUNT and SEGMENT_SIZE must be positive");
        assert (TRIM_COUNT > 0 && SEGMENT_COUNT > (2 * TRIM_COUNT))
            else $fatal(1, "SEGMENT_COUNT must be greater than 2*TRIM_COUNT");
        assert (FRAME_SIZE == SEGMENT_COUNT * SEGMENT_SIZE)
            else $fatal(1, "FRAME_SIZE must equal SEGMENT_COUNT*SEGMENT_SIZE");
    end

    // The per-sample path contains only max/min selection, one subtraction and
    // one sum.  None of the trimmed-average or division logic feeds the sample
    // registers or vpp_out in this cycle.
    always_comb begin
        if (segment_sample_index == '0) begin
            segment_max_with_sample = sample_data;
            segment_min_with_sample = sample_data;
        end else begin
            segment_max_with_sample =
                (sample_data > segment_max) ? sample_data : segment_max;
            segment_min_with_sample =
                (sample_data < segment_min) ? sample_data : segment_min;
        end

        segment_difference =
            {segment_max_with_sample[DATA_WIDTH-1], segment_max_with_sample}
          - {segment_min_with_sample[DATA_WIDTH-1], segment_min_with_sample};
        completed_segment_vpp = segment_difference[VPP_WIDTH-1:0];
        total_sum_with_segment =
            vpp_sum + SUM_WIDTH'(completed_segment_vpp);

        marker_fault =
            (sample_first != ((segment_index == '0) &&
                              (segment_sample_index == '0))) ||
            (sample_last  != ((segment_index == LAST_SEGMENT) &&
                              (segment_sample_index == LAST_SEGMENT_SAMPLE)));
    end

    // Insert one stored segment value into the retained extreme lists.  This
    // runs after the frame and is limited to TRIM_COUNT compare/swap stages.
    always_comb begin
        scan_value = segment_vpp[scan_index];

        for (comb_index = 0; comb_index < TRIM_COUNT;
             comb_index = comb_index + 1) begin
            largest_next[comb_index]  = largest_vpp[comb_index];
            smallest_next[comb_index] = smallest_vpp[comb_index];
        end

        largest_carry = scan_value;
        largest_swap  = '0;
        for (comb_index = 0; comb_index < TRIM_COUNT;
             comb_index = comb_index + 1) begin
            if (largest_carry > largest_next[comb_index]) begin
                largest_swap                  = largest_next[comb_index];
                largest_next[comb_index]       = largest_carry;
                largest_carry                  = largest_swap;
            end
        end

        smallest_carry = scan_value;
        smallest_swap  = '0;
        for (comb_index = 0; comb_index < TRIM_COUNT;
             comb_index = comb_index + 1) begin
            if (smallest_carry < smallest_next[comb_index]) begin
                smallest_swap                  = smallest_next[comb_index];
                smallest_next[comb_index]       = smallest_carry;
                smallest_carry                  = smallest_swap;
            end
        end

        trim_subtract_value =
            trimmed_sum_reg
          - SUM_WIDTH'(largest_vpp[trim_index])
          - SUM_WIDTH'(smallest_vpp[trim_index]);
    end

    // One restoring-division step per clock.  Division occurs once per frame,
    // so the small latency is preferable to a deep constant-divider network.
    always_comb begin
        divide_trial =
            {divide_remainder[DIV_WIDTH-1:0],
             divide_dividend[DIV_WIDTH-1]};
        divide_quotient_next =
            {divide_quotient[DIV_WIDTH-2:0], 1'b0};
        divide_remainder_next = divide_trial;

        if (divide_trial >= DIVISOR_VALUE) begin
            divide_remainder_next = divide_trial - DIVISOR_VALUE;
            divide_quotient_next[0] = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state                <= STATE_COLLECT;
            segment_sample_index <= '0;
            segment_index        <= '0;
            segment_max          <= '0;
            segment_min          <= '0;
            vpp_sum              <= '0;
            total_sum_reg        <= '0;
            scan_index           <= '0;
            trim_index           <= '0;
            trimmed_sum_reg      <= '0;
            rounded_numerator    <= '0;
            divide_dividend      <= '0;
            divide_quotient      <= '0;
            divide_remainder     <= '0;
            divide_count         <= '0;
            vpp_out              <= 32'd0;
            vpp_valid            <= 1'b0;
            vpp_busy             <= 1'b0;
            vpp_error            <= 1'b0;

            for (seq_index = 0; seq_index < SEGMENT_COUNT;
                 seq_index = seq_index + 1) begin
                segment_vpp[seq_index] <= '0;
            end
            for (seq_index = 0; seq_index < TRIM_COUNT;
                 seq_index = seq_index + 1) begin
                largest_vpp[seq_index]  <= '0;
                smallest_vpp[seq_index] <= {VPP_WIDTH{1'b1}};
            end
        end else begin
            vpp_valid <= 1'b0;
            vpp_error <= 1'b0;

            unique case (state)
                STATE_COLLECT: begin
                    if (sample_valid) begin
                        vpp_error <= marker_fault;

                        if ((segment_index == '0) &&
                            (segment_sample_index == '0)) begin
                            vpp_busy <= 1'b1;
                        end

                        if (segment_sample_index == LAST_SEGMENT_SAMPLE) begin
                            segment_vpp[segment_index] <= completed_segment_vpp;
                            segment_sample_index       <= '0;
                            segment_max                <= '0;
                            segment_min                <= '0;

                            if (segment_index == LAST_SEGMENT) begin
                                total_sum_reg <= total_sum_with_segment;
                                vpp_sum       <= '0;
                                segment_index <= '0;
                                scan_index    <= '0;

                                for (seq_index = 0; seq_index < TRIM_COUNT;
                                     seq_index = seq_index + 1) begin
                                    largest_vpp[seq_index]  <= '0;
                                    smallest_vpp[seq_index] <=
                                        {VPP_WIDTH{1'b1}};
                                end
                                state <= STATE_SCAN;
                            end else begin
                                segment_index <= segment_index + 1'b1;
                                vpp_sum       <= total_sum_with_segment;
                            end
                        end else begin
                            segment_sample_index <=
                                segment_sample_index + 1'b1;
                            segment_max <= segment_max_with_sample;
                            segment_min <= segment_min_with_sample;
                        end
                    end
                end

                STATE_SCAN: begin
                    if (sample_valid) begin
                        vpp_error <= 1'b1;
                    end

                    for (seq_index = 0; seq_index < TRIM_COUNT;
                         seq_index = seq_index + 1) begin
                        largest_vpp[seq_index]  <= largest_next[seq_index];
                        smallest_vpp[seq_index] <= smallest_next[seq_index];
                    end

                    if (scan_index == LAST_SEGMENT) begin
                        scan_index <= '0;
                        state      <= STATE_TRIM_INIT;
                    end else begin
                        scan_index <= scan_index + 1'b1;
                    end
                end

                STATE_TRIM_INIT: begin
                    if (sample_valid) begin
                        vpp_error <= 1'b1;
                    end
                    trimmed_sum_reg <= total_sum_reg;
                    trim_index      <= '0;
                    state           <= STATE_TRIM;
                end

                STATE_TRIM: begin
                    if (sample_valid) begin
                        vpp_error <= 1'b1;
                    end
                    trimmed_sum_reg <= trim_subtract_value;
                    if (trim_index == LAST_TRIM_INDEX) begin
                        trim_index <= '0;
                        state      <= STATE_ROUND;
                    end else begin
                        trim_index <= trim_index + 1'b1;
                    end
                end

                STATE_ROUND: begin
                    if (sample_valid) begin
                        vpp_error <= 1'b1;
                    end
                    rounded_numerator <=
                        {1'b0, trimmed_sum_reg} + (RETAINED_COUNT / 2);
                    state <= STATE_DIV_INIT;
                end

                STATE_DIV_INIT: begin
                    if (sample_valid) begin
                        vpp_error <= 1'b1;
                    end
                    divide_dividend  <= rounded_numerator;
                    divide_quotient  <= '0;
                    divide_remainder <= '0;
                    divide_count     <= DIV_COUNT_WIDTH'(DIV_WIDTH);
                    state            <= STATE_DIVIDE;
                end

                STATE_DIVIDE: begin
                    if (sample_valid) begin
                        vpp_error <= 1'b1;
                    end

                    divide_dividend <=
                        {divide_dividend[DIV_WIDTH-2:0], 1'b0};
                    divide_quotient  <= divide_quotient_next;
                    divide_remainder <= divide_remainder_next;

                    if (divide_count == DIV_COUNT_WIDTH'(1)) begin
                        vpp_out   <= divide_quotient_next;
                        vpp_valid <= 1'b1;
                        vpp_busy  <= 1'b0;
                        state     <= STATE_COLLECT;
                    end else begin
                        divide_count <= divide_count - 1'b1;
                    end
                end

                default: begin
                    state                <= STATE_COLLECT;
                    segment_sample_index <= '0;
                    segment_index        <= '0;
                    vpp_sum              <= '0;
                    vpp_busy             <= 1'b0;
                    vpp_error            <= 1'b1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
