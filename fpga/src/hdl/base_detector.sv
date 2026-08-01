`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// Base-frequency detector
//
// Algorithm:
//   1. Estimate the noise floor from the quietest complete 64-bin block.
//   2. Locate peaks on raw P[k], including flat-topped peaks.
//   3. Measure every peak with a seven-bin energy sum.
//   4. Keep the 24 strongest credible peaks.
//   5. Score every possible base by integer-harmonic support.
//   6. If no harmonic family exists, allow a stricter pure-tone fallback.
//
// The memory interface deliberately keeps only one request outstanding.  The
// implementation is multi-cycle and optimized for deterministic behavior and
// modest logic depth rather than minimum latency.
//
// Compatibility note:
//   detect_threshold     = absolute candidate-energy floor (normally 1)
//   prominence_threshold = pure-tone fallback energy floor (normally 16)
// ============================================================================
module base_detector #(
    parameter int unsigned POWER_WIDTH             = 32,
    parameter int unsigned ENERGY_WIDTH            = POWER_WIDTH + 3,
    parameter int unsigned MIN_SCAN_BIN            = 20,
    parameter int unsigned MAX_SCAN_BIN            = 1024,
    parameter int unsigned MAX_CANDIDATES           = 24,
    parameter int unsigned NOISE_BLOCK_SIZE         = 64,
    parameter int unsigned NOISE_MULTIPLIER         = 12,
    parameter int unsigned MINIMUM_BASE_ENERGY      = 2,
    parameter int unsigned STRONG_SUPPORT_ENERGY    = 16
) (
    input  wire logic                         clk,
    input  wire logic                         rst,

    input  wire logic                         start,
    input  wire logic [ENERGY_WIDTH-1:0]      detect_threshold,
    input  wire logic [ENERGY_WIDTH-1:0]      prominence_threshold,
    output wire logic                         busy,

    output      logic                         mem_req,
    output      logic [10:0]                  mem_addr,
    input  wire logic                         mem_ready,
    input  wire logic                         mem_rvalid,
    input  wire logic [POWER_WIDTH-1:0]       mem_rdata,

    output      logic                         base_valid,
    output      logic                         base_done,
    output      logic [15:0]                  base_index_500,
    output      logic [10:0]                  base_bin,
    output      logic [ENERGY_WIDTH-1:0]      base_energy
);

    localparam int unsigned NOISE_COMPLETE_BINS =
        ((MAX_SCAN_BIN - MIN_SCAN_BIN + 1) / NOISE_BLOCK_SIZE) *
        NOISE_BLOCK_SIZE;
    localparam int unsigned NOISE_END_BIN =
        MIN_SCAN_BIN + NOISE_COMPLETE_BINS - 1;
    localparam int unsigned RAW_START_BIN = MIN_SCAN_BIN - 1;
    localparam int unsigned RAW_END_BIN   = MAX_SCAN_BIN + 1;
    localparam int unsigned BLOCK_SUM_WIDTH = POWER_WIDTH + 6;
    localparam int unsigned SUPPORT_ENERGY_WIDTH = ENERGY_WIDTH + 6;

    typedef enum logic [4:0] {
        STATE_IDLE,
        STATE_NOISE_SCAN,
        STATE_NOISE_FINISH,
        STATE_RAW_SCAN,
        STATE_ENERGY_READ,
        STATE_INSERT_FIND,
        STATE_INSERT_SHIFT,
        STATE_INSERT_WRITE,
        STATE_EVAL_INIT,
        STATE_EVAL_CANDIDATE_INIT,
        STATE_EVAL_ORDER_CHECK,
        STATE_EVAL_MATCH_FETCH,
        STATE_EVAL_MATCH_DIFF,
        STATE_EVAL_MATCH_UPDATE,
        STATE_EVAL_ORDER_DONE,
        STATE_EVAL_CANDIDATE_DONE,
        STATE_SELECT_DONE,
        STATE_CONVERT_INDEX_A,
        STATE_CONVERT_INDEX_B,
        STATE_DONE
    } state_t;

    state_t state;

    logic [10:0] read_addr;

    logic [5:0] noise_block_count;
    logic [BLOCK_SUM_WIDTH-1:0] noise_block_sum;
    logic [BLOCK_SUM_WIDTH-1:0] quiet_block_sum;
    logic quiet_block_valid;
    logic [ENERGY_WIDTH-1:0] candidate_threshold;

    logic raw_run_valid;
    logic [POWER_WIDTH-1:0] raw_run_left_value;
    logic [POWER_WIDTH-1:0] raw_run_value;
    logic [10:0] raw_run_start;
    logic [10:0] raw_run_length;
    logic [10:0] raw_next_addr;
    logic raw_scan_finished;

    logic [10:0] pending_peak_bin;
    logic [2:0] energy_read_index;
    logic [ENERGY_WIDTH-1:0] energy_accumulator;
    logic [ENERGY_WIDTH-1:0] pending_peak_energy;

    logic [10:0] candidate_bin [0:MAX_CANDIDATES-1];
    logic [ENERGY_WIDTH-1:0]
        candidate_energy [0:MAX_CANDIDATES-1];
    logic [$clog2(MAX_CANDIDATES+1)-1:0] candidate_count;
    logic [$clog2(MAX_CANDIDATES+1)-1:0] insert_search_index;
    logic [$clog2(MAX_CANDIDATES)-1:0] insert_position;
    logic [$clog2(MAX_CANDIDATES)-1:0] insert_shift_index;

    logic [$clog2(MAX_CANDIDATES)-1:0] eval_base_index;
    logic [$clog2(MAX_CANDIDATES)-1:0] eval_match_index;
    logic [5:0] eval_order;
    logic [5:0] eval_support_count;
    logic [SUPPORT_ENERGY_WIDTH-1:0] eval_support_energy;
    logic eval_order_match_valid;
    logic [ENERGY_WIDTH-1:0] eval_order_match_energy;
    logic [16:0] eval_expected_bin_reg;
    logic [5:0] eval_tolerance_reg;
    logic [10:0] eval_match_bin_reg;
    logic [ENERGY_WIDTH-1:0] eval_match_energy_reg;
    logic [16:0] eval_match_difference_reg;

    logic best_valid;
    logic [5:0] best_support_count;
    logic [SUPPORT_ENERGY_WIDTH-1:0] best_total_energy;
    logic [10:0] best_bin;
    logic [ENERGY_WIDTH-1:0] best_energy;
    logic [18:0] index_partial;

    logic [BLOCK_SUM_WIDTH:0] completed_block_sum_ext;
    logic [BLOCK_SUM_WIDTH-1:0] completed_block_sum;
    logic [BLOCK_SUM_WIDTH-1:0] quiet_block_next;
    logic [BLOCK_SUM_WIDTH+6:0] noise_threshold_product;
    logic [BLOCK_SUM_WIDTH:0] noise_threshold_scaled;
    logic [ENERGY_WIDTH-1:0] adaptive_threshold;

    logic [11:0] raw_center_ext;
    logic [10:0] raw_center;
    logic raw_peak_complete;

    logic [ENERGY_WIDTH:0] energy_total_ext;
    logic [ENERGY_WIDTH-1:0] energy_total;

    logic eval_match_in_range;
    logic [SUPPORT_ENERGY_WIDTH-1:0] eval_total_energy;
    logic eval_candidate_valid;

    integer reset_index;

    function automatic logic [5:0] harmonic_tolerance(
        input logic [5:0] order_value
    );
        logic [5:0] scaled_tolerance;
        begin
            scaled_tolerance = (order_value + 6'd2) >> 1;
            harmonic_tolerance =
                (scaled_tolerance < 6'd2) ? 6'd2 : scaled_tolerance;
        end
    endfunction

    assign busy = (state != STATE_IDLE);

    initial begin
        assert (POWER_WIDTH == 32)
            else $fatal(1, "base_detector supports POWER_WIDTH=32 only");
        assert (ENERGY_WIDTH == 35)
            else $fatal(1, "base_detector supports ENERGY_WIDTH=35 only");
        assert (MIN_SCAN_BIN >= 3)
            else $fatal(1, "MIN_SCAN_BIN must be at least 3");
        assert (MAX_SCAN_BIN <= 2044)
            else $fatal(1, "MAX_SCAN_BIN must not exceed 2044");
        assert (MAX_SCAN_BIN > MIN_SCAN_BIN)
            else $fatal(1, "invalid scan range");
        assert (MAX_CANDIDATES >= 2)
            else $fatal(1, "MAX_CANDIDATES must be at least 2");
        assert (NOISE_BLOCK_SIZE == 64)
            else $fatal(1, "noise estimator requires 64-bin blocks");
        assert (NOISE_COMPLETE_BINS >= NOISE_BLOCK_SIZE)
            else $fatal(1, "scan range has no complete noise block");
    end

    always_comb begin
        completed_block_sum_ext =
            {1'b0, noise_block_sum} +
            {{(BLOCK_SUM_WIDTH + 1 - POWER_WIDTH){1'b0}}, mem_rdata};
        completed_block_sum =
            completed_block_sum_ext[BLOCK_SUM_WIDTH-1:0];

        if (!quiet_block_valid ||
            (completed_block_sum < quiet_block_sum)) begin
            quiet_block_next = completed_block_sum;
        end else begin
            quiet_block_next = quiet_block_sum;
        end

        noise_threshold_product =
            quiet_block_sum * (NOISE_MULTIPLIER * 7);
        noise_threshold_scaled = noise_threshold_product >> 6;
        if (|noise_threshold_scaled[BLOCK_SUM_WIDTH:ENERGY_WIDTH]) begin
            adaptive_threshold = {ENERGY_WIDTH{1'b1}};
        end else if (
            noise_threshold_scaled[ENERGY_WIDTH-1:0] >
            detect_threshold
        ) begin
            adaptive_threshold =
                noise_threshold_scaled[ENERGY_WIDTH-1:0];
        end else begin
            adaptive_threshold = detect_threshold;
        end

        raw_center_ext =
            {1'b0, raw_run_start} +
            (({1'b0, raw_run_length} - 12'd1) >> 1);
        raw_center = raw_center_ext[10:0];
        raw_peak_complete =
            raw_run_valid &&
            (mem_rdata != raw_run_value) &&
            (raw_run_value > raw_run_left_value) &&
            (raw_run_value > mem_rdata) &&
            (raw_center >= MIN_SCAN_BIN[10:0]) &&
            (raw_center <= MAX_SCAN_BIN[10:0]);

        energy_total_ext =
            {1'b0, energy_accumulator} +
            {{(ENERGY_WIDTH + 1 - POWER_WIDTH){1'b0}}, mem_rdata};
        energy_total = energy_total_ext[ENERGY_WIDTH-1:0];

        eval_match_in_range =
            (eval_match_difference_reg <=
             {11'd0, eval_tolerance_reg});

        eval_total_energy = eval_support_energy;
        if (eval_base_index < MAX_CANDIDATES) begin
            eval_total_energy =
                eval_support_energy +
                {{(SUPPORT_ENERGY_WIDTH-ENERGY_WIDTH){1'b0}},
                 candidate_energy[eval_base_index]};
        end

        eval_candidate_valid = 1'b0;
        if (eval_base_index < MAX_CANDIDATES) begin
            eval_candidate_valid =
                (eval_support_count != 6'd0) &&
                (candidate_energy[eval_base_index] >=
                 MINIMUM_BASE_ENERGY) &&
                !((candidate_energy[eval_base_index] < 35'd3) &&
                  (eval_support_energy < STRONG_SUPPORT_ENERGY));
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state                   <= STATE_IDLE;
            mem_req                 <= 1'b0;
            mem_addr                <= 11'd0;
            read_addr               <= 11'd0;
            base_valid              <= 1'b0;
            base_done               <= 1'b0;
            base_index_500          <= 16'd0;
            base_bin                <= 11'd0;
            base_energy             <= '0;
            noise_block_count       <= 6'd0;
            noise_block_sum         <= '0;
            quiet_block_sum         <= '0;
            quiet_block_valid       <= 1'b0;
            candidate_threshold     <= '0;
            raw_run_valid           <= 1'b0;
            raw_run_left_value      <= '0;
            raw_run_value           <= '0;
            raw_run_start           <= 11'd0;
            raw_run_length          <= 11'd0;
            raw_next_addr           <= 11'd0;
            raw_scan_finished       <= 1'b0;
            pending_peak_bin        <= 11'd0;
            energy_read_index       <= 3'd0;
            energy_accumulator      <= '0;
            pending_peak_energy     <= '0;
            candidate_count         <= '0;
            insert_search_index     <= '0;
            insert_position         <= '0;
            insert_shift_index      <= '0;
            eval_base_index         <= '0;
            eval_match_index        <= '0;
            eval_order              <= 6'd2;
            eval_support_count      <= 6'd0;
            eval_support_energy     <= '0;
            eval_order_match_valid  <= 1'b0;
            eval_order_match_energy <= '0;
            eval_expected_bin_reg   <= 17'd0;
            eval_tolerance_reg      <= 6'd0;
            eval_match_bin_reg      <= 11'd0;
            eval_match_energy_reg   <= '0;
            eval_match_difference_reg <= 17'd0;
            best_valid              <= 1'b0;
            best_support_count      <= 6'd0;
            best_total_energy       <= '0;
            best_bin                <= 11'd0;
            best_energy             <= '0;
            index_partial           <= 19'd0;
            for (reset_index = 0;
                 reset_index < MAX_CANDIDATES;
                 reset_index = reset_index + 1) begin
                candidate_bin[reset_index]    <= 11'd0;
                candidate_energy[reset_index] <= '0;
            end
        end else begin
            base_done <= 1'b0;

            if (mem_req && mem_ready) begin
                mem_req   <= 1'b0;
                read_addr <= mem_addr;
            end

            case (state)
                STATE_IDLE: begin
                    mem_req <= 1'b0;
                    if (start) begin
                        base_valid          <= 1'b0;
                        base_index_500      <= 16'd0;
                        base_bin            <= 11'd0;
                        base_energy         <= '0;
                        noise_block_count   <= 6'd0;
                        noise_block_sum     <= '0;
                        quiet_block_sum     <= '0;
                        quiet_block_valid   <= 1'b0;
                        candidate_threshold <= '0;
                        candidate_count     <= '0;
                        best_valid          <= 1'b0;
                        mem_addr            <= MIN_SCAN_BIN[10:0];
                        mem_req             <= 1'b1;
                        state               <= STATE_NOISE_SCAN;
                    end
                end

                STATE_NOISE_SCAN: begin
                    if (mem_rvalid) begin
                        if (noise_block_count == 6'd63) begin
                            quiet_block_sum   <= quiet_block_next;
                            quiet_block_valid <= 1'b1;
                            noise_block_sum   <= '0;
                            noise_block_count <= 6'd0;
                        end else begin
                            noise_block_sum <= completed_block_sum;
                            noise_block_count <=
                                noise_block_count + 1'b1;
                        end

                        if (read_addr == NOISE_END_BIN[10:0]) begin
                            state <= STATE_NOISE_FINISH;
                        end else begin
                            mem_addr <= read_addr + 1'b1;
                            mem_req  <= 1'b1;
                        end
                    end
                end

                STATE_NOISE_FINISH: begin
                    candidate_threshold <= adaptive_threshold;
                    raw_run_valid      <= 1'b0;
                    raw_run_left_value <= '0;
                    raw_run_value      <= '0;
                    raw_run_start      <= 11'd0;
                    raw_run_length     <= 11'd0;
                    mem_addr           <= RAW_START_BIN[10:0];
                    mem_req            <= 1'b1;
                    state              <= STATE_RAW_SCAN;
                end

                STATE_RAW_SCAN: begin
                    if (mem_rvalid) begin
                        if (!raw_run_valid) begin
                            raw_run_valid      <= 1'b1;
                            raw_run_left_value <= '0;
                            raw_run_value      <= mem_rdata;
                            raw_run_start      <= read_addr;
                            raw_run_length     <= 11'd1;

                            if (read_addr == RAW_END_BIN[10:0]) begin
                                state <= STATE_EVAL_INIT;
                            end else begin
                                mem_addr <= read_addr + 1'b1;
                                mem_req  <= 1'b1;
                            end
                        end else if (mem_rdata == raw_run_value) begin
                            raw_run_length <= raw_run_length + 1'b1;

                            if (read_addr == RAW_END_BIN[10:0]) begin
                                state <= STATE_EVAL_INIT;
                            end else begin
                                mem_addr <= read_addr + 1'b1;
                                mem_req  <= 1'b1;
                            end
                        end else begin
                            raw_run_left_value <= raw_run_value;
                            raw_run_value      <= mem_rdata;
                            raw_run_start      <= read_addr;
                            raw_run_length     <= 11'd1;

                            if (raw_peak_complete) begin
                                pending_peak_bin  <= raw_center;
                                energy_read_index <= 3'd0;
                                energy_accumulator <= '0;
                                raw_scan_finished <=
                                    (read_addr == RAW_END_BIN[10:0]);
                                raw_next_addr <= read_addr + 1'b1;
                                mem_addr <= raw_center - 11'd3;
                                mem_req  <= 1'b1;
                                state    <= STATE_ENERGY_READ;
                            end else if (
                                read_addr == RAW_END_BIN[10:0]
                            ) begin
                                state <= STATE_EVAL_INIT;
                            end else begin
                                mem_addr <= read_addr + 1'b1;
                                mem_req  <= 1'b1;
                            end
                        end
                    end
                end

                STATE_ENERGY_READ: begin
                    if (mem_rvalid) begin
                        if (energy_read_index == 3'd6) begin
                            if (energy_total > candidate_threshold) begin
                                pending_peak_energy <= energy_total;
                                insert_search_index <= '0;
                                state <= STATE_INSERT_FIND;
                            end else if (raw_scan_finished) begin
                                state <= STATE_EVAL_INIT;
                            end else begin
                                mem_addr <= raw_next_addr;
                                mem_req  <= 1'b1;
                                state    <= STATE_RAW_SCAN;
                            end
                        end else begin
                            energy_accumulator <= energy_total;
                            energy_read_index <= energy_read_index + 1'b1;
                            mem_addr <= pending_peak_bin - 11'd2 +
                                        energy_read_index;
                            mem_req <= 1'b1;
                        end
                    end
                end

                STATE_INSERT_FIND: begin
                    if (insert_search_index >= candidate_count) begin
                        if (candidate_count < MAX_CANDIDATES) begin
                            insert_position <=
                                insert_search_index[
                                    $clog2(MAX_CANDIDATES)-1:0
                                ];
                            insert_shift_index <=
                                candidate_count[
                                    $clog2(MAX_CANDIDATES)-1:0
                                ];
                            state <= STATE_INSERT_SHIFT;
                        end else if (raw_scan_finished) begin
                            state <= STATE_EVAL_INIT;
                        end else begin
                            mem_addr <= raw_next_addr;
                            mem_req  <= 1'b1;
                            state    <= STATE_RAW_SCAN;
                        end
                    end else if (
                        pending_peak_energy >
                        candidate_energy[insert_search_index]
                    ) begin
                        insert_position <=
                            insert_search_index[
                                $clog2(MAX_CANDIDATES)-1:0
                            ];
                        if (candidate_count < MAX_CANDIDATES) begin
                            insert_shift_index <=
                                candidate_count[
                                    $clog2(MAX_CANDIDATES)-1:0
                                ];
                        end else begin
                            insert_shift_index <= MAX_CANDIDATES-1;
                        end
                        state <= STATE_INSERT_SHIFT;
                    end else begin
                        insert_search_index <= insert_search_index + 1'b1;
                    end
                end

                STATE_INSERT_SHIFT: begin
                    if (insert_shift_index > insert_position) begin
                        candidate_bin[insert_shift_index] <=
                            candidate_bin[insert_shift_index-1'b1];
                        candidate_energy[insert_shift_index] <=
                            candidate_energy[insert_shift_index-1'b1];
                        insert_shift_index <= insert_shift_index - 1'b1;
                    end else begin
                        state <= STATE_INSERT_WRITE;
                    end
                end

                STATE_INSERT_WRITE: begin
                    candidate_bin[insert_position] <= pending_peak_bin;
                    candidate_energy[insert_position] <=
                        pending_peak_energy;
                    if (candidate_count < MAX_CANDIDATES) begin
                        candidate_count <= candidate_count + 1'b1;
                    end

                    if (raw_scan_finished) begin
                        state <= STATE_EVAL_INIT;
                    end else begin
                        mem_addr <= raw_next_addr;
                        mem_req  <= 1'b1;
                        state    <= STATE_RAW_SCAN;
                    end
                end

                STATE_EVAL_INIT: begin
                    best_valid          <= 1'b0;
                    best_support_count  <= 6'd0;
                    best_total_energy   <= '0;
                    best_bin            <= 11'd0;
                    best_energy         <= '0;
                    eval_base_index     <= '0;
                    eval_order          <= 6'd2;
                    eval_support_count  <= 6'd0;
                    eval_support_energy <= '0;
                    if (candidate_count == 0) begin
                        state <= STATE_SELECT_DONE;
                    end else begin
                        state <= STATE_EVAL_CANDIDATE_INIT;
                    end
                end

                STATE_EVAL_CANDIDATE_INIT: begin
                    eval_order          <= 6'd2;
                    eval_support_count  <= 6'd0;
                    eval_support_energy <= '0;
                    eval_expected_bin_reg <=
                        {5'd0, candidate_bin[eval_base_index], 1'b0};
                    eval_tolerance_reg <= harmonic_tolerance(6'd2);
                    state <= STATE_EVAL_ORDER_CHECK;
                end

                STATE_EVAL_ORDER_CHECK: begin
                    if (eval_expected_bin_reg >
                        (17'd1024 + {11'd0, eval_tolerance_reg})) begin
                        state <= STATE_EVAL_CANDIDATE_DONE;
                    end else begin
                        eval_match_index        <= '0;
                        eval_order_match_valid  <= 1'b0;
                        eval_order_match_energy <= '0;
                        state <= STATE_EVAL_MATCH_FETCH;
                    end
                end

                STATE_EVAL_MATCH_FETCH: begin
                    eval_match_bin_reg <=
                        candidate_bin[eval_match_index];
                    eval_match_energy_reg <=
                        candidate_energy[eval_match_index];
                    state <= STATE_EVAL_MATCH_DIFF;
                end

                STATE_EVAL_MATCH_DIFF: begin
                    if ({6'd0, eval_match_bin_reg} >=
                        eval_expected_bin_reg) begin
                        eval_match_difference_reg <=
                            {6'd0, eval_match_bin_reg} -
                            eval_expected_bin_reg;
                    end else begin
                        eval_match_difference_reg <=
                            eval_expected_bin_reg -
                            {6'd0, eval_match_bin_reg};
                    end
                    state <= STATE_EVAL_MATCH_UPDATE;
                end

                STATE_EVAL_MATCH_UPDATE: begin
                    if (eval_match_in_range &&
                        (!eval_order_match_valid ||
                         (eval_match_energy_reg >
                          eval_order_match_energy))) begin
                        eval_order_match_valid  <= 1'b1;
                        eval_order_match_energy <=
                            eval_match_energy_reg;
                    end

                    if (eval_match_index == candidate_count - 1'b1) begin
                        state <= STATE_EVAL_ORDER_DONE;
                    end else begin
                        eval_match_index <= eval_match_index + 1'b1;
                        state <= STATE_EVAL_MATCH_FETCH;
                    end
                end

                STATE_EVAL_ORDER_DONE: begin
                    if (eval_order_match_valid) begin
                        eval_support_count <= eval_support_count + 1'b1;
                        eval_support_energy <=
                            eval_support_energy +
                            {{(SUPPORT_ENERGY_WIDTH-ENERGY_WIDTH){1'b0}},
                             eval_order_match_energy};
                    end
                    eval_order <= eval_order + 1'b1;
                    eval_expected_bin_reg <=
                        eval_expected_bin_reg +
                        {6'd0, candidate_bin[eval_base_index]};
                    eval_tolerance_reg <=
                        harmonic_tolerance(eval_order + 1'b1);
                    state <= STATE_EVAL_ORDER_CHECK;
                end

                STATE_EVAL_CANDIDATE_DONE: begin
                    if (eval_candidate_valid &&
                        (!best_valid ||
                         (eval_support_count > best_support_count) ||
                         ((eval_support_count == best_support_count) &&
                          (eval_total_energy > best_total_energy)) ||
                         ((eval_support_count == best_support_count) &&
                          (eval_total_energy == best_total_energy) &&
                          (candidate_bin[eval_base_index] < best_bin)))) begin
                        best_valid         <= 1'b1;
                        best_support_count <= eval_support_count;
                        best_total_energy  <= eval_total_energy;
                        best_bin           <= candidate_bin[eval_base_index];
                        best_energy        <=
                            candidate_energy[eval_base_index];
                    end

                    if (eval_base_index == candidate_count - 1'b1) begin
                        state <= STATE_SELECT_DONE;
                    end else begin
                        eval_base_index <= eval_base_index + 1'b1;
                        state <= STATE_EVAL_CANDIDATE_INIT;
                    end
                end

                STATE_SELECT_DONE: begin
                    if (best_valid) begin
                        base_valid     <= 1'b1;
                        base_bin       <= best_bin;
                        base_energy    <= best_energy;
                        state          <= STATE_CONVERT_INDEX_A;
                    end else if (
                        (candidate_count != 0) &&
                        (candidate_energy[0] >= prominence_threshold)
                    ) begin
                        base_valid     <= 1'b1;
                        base_bin       <= candidate_bin[0];
                        base_energy    <= candidate_energy[0];
                        state          <= STATE_CONVERT_INDEX_A;
                    end else begin
                        base_valid     <= 1'b0;
                        base_bin       <= 11'd0;
                        base_energy    <= '0;
                        base_index_500 <= 16'd0;
                        state          <= STATE_DONE;
                    end
                end

                STATE_CONVERT_INDEX_A: begin
                    index_partial <=
                        ({8'd0, base_bin} << 7) -
                        ({8'd0, base_bin} << 1);
                    state <= STATE_CONVERT_INDEX_B;
                end

                STATE_CONVERT_INDEX_B: begin
                    base_index_500 <=
                        (index_partial -
                         {8'd0, base_bin} +
                         19'd64) >> 7;
                    state <= STATE_DONE;
                end

                STATE_DONE: begin
                    mem_req   <= 1'b0;
                    base_done <= 1'b1;
                    state     <= STATE_IDLE;
                end

                default: begin
                    state      <= STATE_IDLE;
                    mem_req    <= 1'b0;
                    base_valid <= 1'b0;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
