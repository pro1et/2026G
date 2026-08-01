`timescale 1ns/1ps
`default_nettype none

// Calculate the base-wave energy, then scan integer harmonics in ascending
// frequency order.  The first two harmonics that pass both thresholds are
// published as harmonic A and harmonic B.  They are not fixed to orders 2/3.
module energy_calculator #(
    parameter int unsigned POWER_WIDTH               = 32,
    parameter int unsigned ENERGY_ACC_WIDTH          = POWER_WIDTH + 3,
    parameter int unsigned ENERGY_SHIFT              = 3,
    parameter int unsigned INDEX_WIDTH               = 16,
    parameter int unsigned SPECTRUM_ADDR_WIDTH       = 11,
    parameter int unsigned RESULT_ADDR_WIDTH         = 4,
    parameter int unsigned WINDOW_RADIUS             = 3,
    parameter int unsigned MAX_SPECTRUM_BIN          = 2047,
    // Unit: 500 Hz.  1000 includes the 500 kHz measurement boundary.
    parameter int unsigned MAX_MEASUREMENT_INDEX_500 = 1000
) (
    input  wire logic                              clk,
    input  wire logic                              rst,

    input  wire logic                              start,
    output      logic                              busy,
    output      logic                              done,

    input  wire logic                              base_valid,
    input  wire logic [INDEX_WIDTH-1:0]            base_index_500,
    input  wire logic [31:0]                       absolute_threshold,
    input  wire logic [15:0]                       ratio_num,
    input  wire logic [15:0]                       ratio_den,

    output      logic                              mem_req,
    output      logic [SPECTRUM_ADDR_WIDTH-1:0]    mem_addr,
    input  wire logic                              mem_ready,
    input  wire logic                              mem_rvalid,
    input  wire logic [POWER_WIDTH-1:0]            mem_rdata,

    output      logic                              result_bram_en,
    output      logic                              result_bram_we,
    output      logic [RESULT_ADDR_WIDTH-1:0]      result_bram_addr,
    output      logic [31:0]                       result_bram_din,

    // bit0=base, bit1=nearest detected harmonic A, bit2=next harmonic B.
    output      logic [2:0]                        harmonic_present_mask,
    output      logic [2:0]                        position_valid_mask,
    output      logic                              result_valid,
    output      logic                              energy_overflow
);

    localparam int unsigned WINDOW_POINTS = (2 * WINDOW_RADIUS) + 1;
    localparam int unsigned COUNT_WIDTH = $clog2(WINDOW_POINTS + 1);
    localparam int unsigned RATIO_PRODUCT_WIDTH = ENERGY_ACC_WIDTH + 16;
    localparam int unsigned MAX_CENTER_BIN = MAX_SPECTRUM_BIN - WINDOW_RADIUS;

    typedef enum logic [3:0] {
        STATE_IDLE,
        STATE_WRITE_BUSY,
        STATE_PREPARE,
        STATE_DIVIDE,
        STATE_CHECK_POSITION,
        STATE_READ,
        STATE_RATIO_MULTIPLY,
        STATE_CHECK_CANDIDATE,
        STATE_FINALIZE,
        STATE_WRITE_RESULTS,
        STATE_COMMIT
    } state_t;

    state_t state;

    logic                              base_valid_latched;
    logic [INDEX_WIDTH-1:0]            base_index_latched;
    logic [31:0]                       absolute_threshold_latched;
    logic [15:0]                       ratio_num_latched;
    logic [15:0]                       ratio_den_latched;

    // Order 1 is the base.  Orders 2...floor(500 kHz/f0) are scanned.
    logic [7:0]                        candidate_order;
    logic [1:0]                        harmonic_found_count;
    logic [31:0]                       scan_index_500;
    logic [31:0]                       candidate_index_calc;
    logic [39:0]                       candidate_numerator_calc;
    logic [31:0]                       current_candidate_index;
    logic [39:0]                       candidate_bin_reg;
    logic [SPECTRUM_ADDR_WIDTH-1:0]    window_start_addr;

    logic [39:0]                       divide_dividend;
    logic [39:0]                       divide_quotient;
    logic [7:0]                        divide_remainder;
    logic [5:0]                        divide_count;
    logic [7:0]                        divide_trial;
    logic [39:0]                       divide_dividend_next;
    logic [39:0]                       divide_quotient_next;
    logic [7:0]                        divide_remainder_next;

    logic [COUNT_WIDTH-1:0]            issue_count;
    logic [COUNT_WIDTH-1:0]            receive_count;
    logic [ENERGY_ACC_WIDTH-1:0]       energy_acc;
    logic [ENERGY_ACC_WIDTH-1:0]       energy_acc_next;

    logic [ENERGY_ACC_WIDTH-1:0]       base_energy_raw;
    logic [ENERGY_ACC_WIDTH-1:0]       candidate_energy_raw;
    logic [ENERGY_ACC_WIDTH-1:0]       harmonic_a_energy_raw;
    logic [ENERGY_ACC_WIDTH-1:0]       harmonic_b_energy_raw;
    logic [31:0]                       base_energy_out;
    logic [31:0]                       harmonic_a_energy_out;
    logic [31:0]                       harmonic_b_energy_out;
    logic [31:0]                       base_index_out;
    logic [31:0]                       harmonic_a_index;
    logic [31:0]                       harmonic_b_index;
    logic [7:0]                        harmonic_a_order;
    logic [7:0]                        harmonic_b_order;

    logic                              base_invalid;
    logic                              threshold_invalid;
    logic                              read_error;
    logic [RESULT_ADDR_WIDTH-1:0]      write_addr;

    // Datapath-only registers intentionally have no reset.  Each is
    // overwritten before its consuming state, avoiding wide reset fanout.
    logic [RATIO_PRODUCT_WIDTH-1:0]    base_ratio_product;
    logic [RATIO_PRODUCT_WIDTH-1:0]    candidate_ratio_product;
    logic [RATIO_PRODUCT_WIDTH-1:0]    base_ratio_product_calc;
    logic [RATIO_PRODUCT_WIDTH-1:0]    candidate_ratio_product_calc;
    logic [ENERGY_ACC_WIDTH-1:0]       absolute_threshold_ext;

    logic [32:0]                       base_scaled;
    logic [32:0]                       harmonic_a_scaled;
    logic [32:0]                       harmonic_b_scaled;
    logic [31:0]                       status_common;
    logic [31:0]                       status_busy;
    logic [31:0]                       status_final;

    wire logic request_fire;

    initial begin
        assert (POWER_WIDTH > 0)
            else $fatal(1, "POWER_WIDTH must be positive");
        assert (ENERGY_ACC_WIDTH >= POWER_WIDTH + 3)
            else $fatal(1, "ENERGY_ACC_WIDTH is too small for seven bins");
        assert (ENERGY_ACC_WIDTH >= 32)
            else $fatal(1, "ENERGY_ACC_WIDTH must be at least 32");
        assert (ENERGY_SHIFT > 0 && ENERGY_SHIFT <= ENERGY_ACC_WIDTH)
            else $fatal(1, "ENERGY_SHIFT is out of range");
        assert (INDEX_WIDTH > 0 && INDEX_WIDTH <= 32)
            else $fatal(1, "INDEX_WIDTH is out of range");
        assert (SPECTRUM_ADDR_WIDTH > 0 &&
                MAX_SPECTRUM_BIN < (1 << SPECTRUM_ADDR_WIDTH))
            else $fatal(1, "spectrum address width is too small");
        assert (RESULT_ADDR_WIDTH >= 4)
            else $fatal(1, "result address width must be at least four");
        assert (WINDOW_RADIUS == 3 && WINDOW_POINTS == 7)
            else $fatal(1, "this implementation requires a seven-bin window");
        assert (MAX_SPECTRUM_BIN > WINDOW_RADIUS)
            else $fatal(1, "MAX_SPECTRUM_BIN is too small");
        assert (MAX_MEASUREMENT_INDEX_500 > 0)
            else $fatal(1, "measurement frequency limit must be positive");
    end

    function automatic logic [32:0] scale_energy (
        input logic [ENERGY_ACC_WIDTH-1:0] value
    );
        logic [ENERGY_ACC_WIDTH:0] rounded_ext;
        logic [ENERGY_ACC_WIDTH:0] scaled_ext;
        begin
            rounded_ext =
                {1'b0, value} +
                ({{ENERGY_ACC_WIDTH{1'b0}}, 1'b1} << (ENERGY_SHIFT - 1));
            scaled_ext = rounded_ext >> ENERGY_SHIFT;
            if (|scaled_ext[ENERGY_ACC_WIDTH:32]) begin
                scale_energy = {1'b1, 32'hFFFF_FFFF};
            end else begin
                scale_energy = {1'b0, scaled_ext[31:0]};
            end
        end
    endfunction

    always_comb begin
        if (candidate_order == 8'd1) begin
            candidate_index_calc =
                {{(32-INDEX_WIDTH){1'b0}}, base_index_latched};
        end else begin
            candidate_index_calc = scan_index_500;
        end
        candidate_numerator_calc =
            ({8'd0, candidate_index_calc} << 7) + 40'd62;

        // Forty-cycle unsigned division by 125.
        divide_trial = {divide_remainder[6:0], divide_dividend[39]};
        divide_dividend_next = {divide_dividend[38:0], 1'b0};
        divide_quotient_next =
            {divide_quotient[38:0], (divide_trial >= 8'd125)};
        if (divide_trial >= 8'd125) begin
            divide_remainder_next = divide_trial - 8'd125;
        end else begin
            divide_remainder_next = divide_trial;
        end

        energy_acc_next =
            energy_acc +
            {{(ENERGY_ACC_WIDTH - POWER_WIDTH){1'b0}}, mem_rdata};
        absolute_threshold_ext =
            {{(ENERGY_ACC_WIDTH-32){1'b0}}, absolute_threshold_latched};

        base_ratio_product_calc =
            {{16{1'b0}}, base_energy_raw} * ratio_num_latched;
        candidate_ratio_product_calc =
            {{16{1'b0}}, candidate_energy_raw} * ratio_den_latched;

        base_scaled       = scale_energy(base_energy_raw);
        harmonic_a_scaled = scale_energy(harmonic_a_energy_raw);
        harmonic_b_scaled = scale_energy(harmonic_b_energy_raw);

        status_common = 32'd0;
        status_common[2]     = energy_overflow;
        status_common[3]     = base_invalid;
        status_common[4]     = threshold_invalid;
        status_common[5]     = read_error;
        status_common[10:8]  = harmonic_present_mask;
        status_common[13:11] = position_valid_mask;

        status_busy      = status_common;
        status_busy[0]   = 1'b0;
        status_busy[1]   = 1'b1;
        status_final     = status_common;
        status_final[0]  = 1'b1;
        status_final[1]  = 1'b0;
    end

    assign request_fire = mem_req && mem_ready;

    always_comb begin
        mem_req  = 1'b0;
        mem_addr = window_start_addr + issue_count;
        if ((state == STATE_READ) && (issue_count < WINDOW_POINTS)) begin
            mem_req = 1'b1;
        end
    end

    always_comb begin
        result_bram_en   = 1'b0;
        result_bram_we   = 1'b0;
        result_bram_addr = '0;
        result_bram_din  = 32'd0;

        case (state)
            STATE_WRITE_BUSY: begin
                result_bram_en   = 1'b1;
                result_bram_we   = 1'b1;
                result_bram_addr = '0;
                result_bram_din  = status_busy;
            end

            STATE_WRITE_RESULTS: begin
                result_bram_en   = 1'b1;
                result_bram_we   = 1'b1;
                result_bram_addr = write_addr;
                case (write_addr)
                    4'd1:  result_bram_din = base_index_out;
                    4'd2:  result_bram_din = base_energy_out;
                    4'd3:  result_bram_din = harmonic_a_index;
                    4'd4:  result_bram_din = harmonic_a_energy_out;
                    4'd5:  result_bram_din = harmonic_b_index;
                    4'd6:  result_bram_din = harmonic_b_energy_out;
                    4'd7:  result_bram_din = ENERGY_SHIFT;
                    4'd8:  result_bram_din = absolute_threshold_latched;
                    4'd9:  result_bram_din =
                        {ratio_den_latched, ratio_num_latched};
                    4'd10: result_bram_din = {24'd0, harmonic_a_order};
                    4'd11: result_bram_din = {24'd0, harmonic_b_order};
                    default: result_bram_din = 32'd0;
                endcase
            end

            STATE_COMMIT: begin
                result_bram_en   = 1'b1;
                result_bram_we   = 1'b1;
                result_bram_addr = '0;
                result_bram_din  = status_final;
            end

            default: begin
                result_bram_en = 1'b0;
                result_bram_we = 1'b0;
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state                       <= STATE_IDLE;
            busy                        <= 1'b0;
            done                        <= 1'b0;
            base_valid_latched          <= 1'b0;
            base_index_latched          <= '0;
            absolute_threshold_latched  <= 32'd0;
            ratio_num_latched           <= 16'd0;
            ratio_den_latched           <= 16'd0;
            candidate_order             <= 8'd1;
            harmonic_found_count        <= 2'd0;
            scan_index_500              <= 32'd0;
            current_candidate_index     <= 32'd0;
            candidate_bin_reg           <= 40'd0;
            window_start_addr           <= '0;
            divide_dividend             <= 40'd0;
            divide_quotient             <= 40'd0;
            divide_remainder            <= 8'd0;
            divide_count                <= 6'd0;
            issue_count                 <= '0;
            receive_count               <= '0;
            energy_acc                  <= '0;
            base_energy_raw             <= '0;
            candidate_energy_raw        <= '0;
            harmonic_a_energy_raw       <= '0;
            harmonic_b_energy_raw       <= '0;
            base_energy_out             <= 32'd0;
            harmonic_a_energy_out       <= 32'd0;
            harmonic_b_energy_out       <= 32'd0;
            base_index_out              <= 32'd0;
            harmonic_a_index            <= 32'd0;
            harmonic_b_index            <= 32'd0;
            harmonic_a_order            <= 8'd0;
            harmonic_b_order            <= 8'd0;
            harmonic_present_mask       <= 3'b000;
            position_valid_mask         <= 3'b000;
            result_valid                <= 1'b0;
            energy_overflow             <= 1'b0;
            base_invalid                <= 1'b0;
            threshold_invalid           <= 1'b0;
            read_error                  <= 1'b0;
            write_addr                  <= '0;
        end else begin
            done <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy                       <= 1'b1;
                        result_valid               <= 1'b0;
                        base_valid_latched         <= base_valid;
                        base_index_latched         <= base_index_500;
                        absolute_threshold_latched <= absolute_threshold;
                        ratio_num_latched          <= ratio_num;
                        ratio_den_latched          <= ratio_den;
                        candidate_order            <= 8'd1;
                        harmonic_found_count       <= 2'd0;
                        scan_index_500              <= 32'd0;
                        current_candidate_index    <= 32'd0;
                        candidate_bin_reg          <= 40'd0;
                        issue_count                <= '0;
                        receive_count              <= '0;
                        energy_acc                 <= '0;
                        divide_dividend            <= 40'd0;
                        divide_quotient            <= 40'd0;
                        divide_remainder           <= 8'd0;
                        divide_count               <= 6'd0;
                        base_energy_raw            <= '0;
                        candidate_energy_raw       <= '0;
                        harmonic_a_energy_raw      <= '0;
                        harmonic_b_energy_raw      <= '0;
                        base_energy_out            <= 32'd0;
                        harmonic_a_energy_out      <= 32'd0;
                        harmonic_b_energy_out      <= 32'd0;
                        base_index_out             <= 32'd0;
                        harmonic_a_index           <= 32'd0;
                        harmonic_b_index           <= 32'd0;
                        harmonic_a_order           <= 8'd0;
                        harmonic_b_order           <= 8'd0;
                        harmonic_present_mask      <= 3'b000;
                        position_valid_mask        <= 3'b000;
                        energy_overflow            <= 1'b0;
                        base_invalid               <= !base_valid;
                        threshold_invalid          <= (ratio_den == 16'd0);
                        read_error                 <= 1'b0;
                        write_addr                 <= '0;
                        state                      <= STATE_WRITE_BUSY;
                    end
                end

                STATE_WRITE_BUSY: begin
                    if (!base_valid_latched || (base_index_latched == '0)) begin
                        base_invalid <= 1'b1;
                        state        <= STATE_FINALIZE;
                    end else begin
                        state <= STATE_PREPARE;
                    end
                end

                STATE_PREPARE: begin
                    if ((candidate_order != 8'd1) &&
                        ((scan_index_500 > MAX_MEASUREMENT_INDEX_500) ||
                         (harmonic_found_count == 2'd2) ||
                         threshold_invalid)) begin
                        state <= STATE_FINALIZE;
                    end else begin
                        current_candidate_index <= candidate_index_calc;
                        divide_dividend          <= candidate_numerator_calc;
                        divide_quotient          <= 40'd0;
                        divide_remainder         <= 8'd0;
                        divide_count             <= 6'd0;
                        issue_count              <= '0;
                        receive_count            <= '0;
                        energy_acc               <= '0;
                        state                    <= STATE_DIVIDE;
                    end
                end

                STATE_DIVIDE: begin
                    divide_dividend  <= divide_dividend_next;
                    divide_quotient  <= divide_quotient_next;
                    divide_remainder <= divide_remainder_next;
                    if (divide_count == 6'd39) begin
                        candidate_bin_reg <= divide_quotient_next;
                        state             <= STATE_CHECK_POSITION;
                    end else begin
                        divide_count <= divide_count + 1'b1;
                    end
                end

                STATE_CHECK_POSITION: begin
                    if ((candidate_bin_reg >= WINDOW_RADIUS) &&
                        (candidate_bin_reg <= MAX_CENTER_BIN)) begin
                        window_start_addr <=
                            candidate_bin_reg[SPECTRUM_ADDR_WIDTH-1:0] -
                            WINDOW_RADIUS;
                        state <= STATE_READ;
                    end else if (candidate_order == 8'd1) begin
                        base_invalid <= 1'b1;
                        state        <= STATE_FINALIZE;
                    end else begin
                        candidate_order <= candidate_order + 1'b1;
                        scan_index_500  <= scan_index_500 +
                            {{(32-INDEX_WIDTH){1'b0}}, base_index_latched};
                        state <= STATE_PREPARE;
                    end
                end

                STATE_READ: begin
                    if (request_fire) begin
                        issue_count <= issue_count + 1'b1;
                    end

                    if (mem_rvalid) begin
                        if ((receive_count < issue_count) || request_fire) begin
                            if (receive_count == WINDOW_POINTS-1) begin
                                if (candidate_order == 8'd1) begin
                                    base_energy_raw <= energy_acc_next;
                                end else begin
                                    candidate_energy_raw <= energy_acc_next;
                                end
                                energy_acc <= energy_acc_next;
                                state      <= STATE_RATIO_MULTIPLY;
                            end else begin
                                energy_acc    <= energy_acc_next;
                                receive_count <= receive_count + 1'b1;
                            end
                        end else begin
                            read_error <= 1'b1;
                        end
                    end
                end

                STATE_RATIO_MULTIPLY: begin
                    if (candidate_order == 8'd1) begin
                        base_ratio_product <= base_ratio_product_calc;
                    end else begin
                        candidate_ratio_product <= candidate_ratio_product_calc;
                    end
                    state <= STATE_CHECK_CANDIDATE;
                end

                STATE_CHECK_CANDIDATE: begin
                    if (candidate_order == 8'd1) begin
                        base_index_out          <= current_candidate_index;
                        harmonic_present_mask[0] <= 1'b1;
                        position_valid_mask[0]   <= 1'b1;
                        candidate_order          <= 8'd2;
                        scan_index_500           <=
                            ({{(32-INDEX_WIDTH){1'b0}}, base_index_latched} << 1);
                        state                    <= STATE_PREPARE;
                    end else if (
                        !threshold_invalid &&
                        (candidate_energy_raw >= absolute_threshold_ext) &&
                        (candidate_ratio_product >= base_ratio_product)
                    ) begin
                        if (harmonic_found_count == 2'd0) begin
                            harmonic_a_index          <= current_candidate_index;
                            harmonic_a_energy_raw     <= candidate_energy_raw;
                            harmonic_a_order          <= candidate_order;
                            harmonic_present_mask[1]  <= 1'b1;
                            position_valid_mask[1]    <= 1'b1;
                            harmonic_found_count      <= 2'd1;
                            candidate_order           <= candidate_order + 1'b1;
                            scan_index_500            <= scan_index_500 +
                                {{(32-INDEX_WIDTH){1'b0}}, base_index_latched};
                            state                     <= STATE_PREPARE;
                        end else begin
                            harmonic_b_index          <= current_candidate_index;
                            harmonic_b_energy_raw     <= candidate_energy_raw;
                            harmonic_b_order          <= candidate_order;
                            harmonic_present_mask[2]  <= 1'b1;
                            position_valid_mask[2]    <= 1'b1;
                            harmonic_found_count      <= 2'd2;
                            state                     <= STATE_FINALIZE;
                        end
                    end else begin
                        candidate_order <= candidate_order + 1'b1;
                        scan_index_500  <= scan_index_500 +
                            {{(32-INDEX_WIDTH){1'b0}}, base_index_latched};
                        state <= STATE_PREPARE;
                    end
                end

                STATE_FINALIZE: begin
                    base_energy_out       <= base_scaled[31:0];
                    harmonic_a_energy_out <= harmonic_a_scaled[31:0];
                    harmonic_b_energy_out <= harmonic_b_scaled[31:0];
                    energy_overflow <=
                        base_scaled[32] ||
                        harmonic_a_scaled[32] ||
                        harmonic_b_scaled[32];
                    write_addr <= {{(RESULT_ADDR_WIDTH-1){1'b0}}, 1'b1};
                    state      <= STATE_WRITE_RESULTS;
                end

                STATE_WRITE_RESULTS: begin
                    if (write_addr == 4'd15) begin
                        state <= STATE_COMMIT;
                    end else begin
                        write_addr <= write_addr + 1'b1;
                    end
                end

                STATE_COMMIT: begin
                    busy         <= 1'b0;
                    result_valid <= 1'b1;
                    done         <= 1'b1;
                    state        <= STATE_IDLE;
                end

                default: begin
                    state        <= STATE_IDLE;
                    busy         <= 1'b0;
                    result_valid <= 1'b0;
                    read_error   <= 1'b1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
