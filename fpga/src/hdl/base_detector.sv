`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 基频检测器（第一版）
//
// 从MIN_SCAN_BIN到MAX_SCAN_BIN顺序读取U32功率谱，计算7点滑动能量，并选择
// 第一个满足阈值、局部峰和左侧显著性条件的峰。每次只保留一个未完成读请求，
// 因而不依赖固定BRAM延迟，也不需要返回地址。
// ============================================================================
module base_detector #(
    parameter int unsigned POWER_WIDTH  = 32,
    parameter int unsigned ENERGY_WIDTH = POWER_WIDTH + 3,
    parameter int unsigned MIN_SCAN_BIN = 17,
    parameter int unsigned MAX_SCAN_BIN = 2044
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

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_SCAN,
        STATE_DONE
    } state_t;

    state_t state;

    logic [10:0] receive_addr;
    logic [POWER_WIDTH-1:0] power_d0;
    logic [POWER_WIDTH-1:0] power_d1;
    logic [POWER_WIDTH-1:0] power_d2;
    logic [POWER_WIDTH-1:0] power_d3;
    logic [POWER_WIDTH-1:0] power_d4;
    logic [POWER_WIDTH-1:0] power_d5;
    logic [POWER_WIDTH-1:0] power_d6;
    logic [2:0]             window_fill_count;
    logic [ENERGY_WIDTH-1:0] window_energy;

    logic [ENERGY_WIDTH-1:0] energy_left;
    logic [ENERGY_WIDTH-1:0] energy_middle;
    logic [10:0]             middle_bin;
    logic [1:0]              energy_history_count;

    logic [ENERGY_WIDTH:0] first_window_sum_ext;
    logic [ENERGY_WIDTH:0] sliding_sum_ext;
    logic [ENERGY_WIDTH-1:0] new_window_energy;
    logic [10:0]             new_window_center;
    logic                    new_window_valid;
    logic                    peak_detected;
    logic [26:0]             index_500_numerator;

    assign busy = (state != STATE_IDLE);

    initial begin
        assert (POWER_WIDTH == 32)
            else $fatal(1, "base_detector supports POWER_WIDTH=32 only");
        assert (ENERGY_WIDTH == 35)
            else $fatal(1, "base_detector supports ENERGY_WIDTH=35 only");
        assert (MIN_SCAN_BIN >= 3)
            else $fatal(1, "MIN_SCAN_BIN must be at least 3");
        assert (MAX_SCAN_BIN <= 2047)
            else $fatal(1, "MAX_SCAN_BIN must not exceed 2047");
        assert (MAX_SCAN_BIN >= MIN_SCAN_BIN + 8)
            else $fatal(1, "scan range is too short for peak detection");
    end

    always_comb begin
        first_window_sum_ext =
            {{(ENERGY_WIDTH + 1 - POWER_WIDTH){1'b0}}, power_d1} +
            {{(ENERGY_WIDTH + 1 - POWER_WIDTH){1'b0}}, power_d2} +
            {{(ENERGY_WIDTH + 1 - POWER_WIDTH){1'b0}}, power_d3} +
            {{(ENERGY_WIDTH + 1 - POWER_WIDTH){1'b0}}, power_d4} +
            {{(ENERGY_WIDTH + 1 - POWER_WIDTH){1'b0}}, power_d5} +
            {{(ENERGY_WIDTH + 1 - POWER_WIDTH){1'b0}}, power_d6} +
            {{(ENERGY_WIDTH + 1 - POWER_WIDTH){1'b0}}, mem_rdata};

        sliding_sum_ext =
            {1'b0, window_energy} +
            {{(ENERGY_WIDTH + 1 - POWER_WIDTH){1'b0}}, mem_rdata} -
            {{(ENERGY_WIDTH + 1 - POWER_WIDTH){1'b0}}, power_d0};

        new_window_valid  = (window_fill_count == 3'd6);
        new_window_energy = (energy_history_count == 2'd0) ?
                            first_window_sum_ext[ENERGY_WIDTH-1:0] :
                            sliding_sum_ext[ENERGY_WIDTH-1:0];
        new_window_center = receive_addr - 11'd3;

        peak_detected =
            new_window_valid &&
            (energy_history_count == 2'd2) &&
            (energy_middle > detect_threshold) &&
            (energy_middle > energy_left) &&
            (energy_middle >= new_window_energy) &&
            ((energy_middle - energy_left) > prominence_threshold);

        index_500_numerator = (middle_bin * 27'd125) + 27'd64;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state                <= STATE_IDLE;
            mem_req              <= 1'b0;
            mem_addr             <= MIN_SCAN_BIN[10:0];
            receive_addr         <= MIN_SCAN_BIN[10:0];
            base_valid           <= 1'b0;
            base_done            <= 1'b0;
            base_index_500       <= 16'd0;
            base_bin             <= 11'd0;
            base_energy          <= '0;
            power_d0             <= '0;
            power_d1             <= '0;
            power_d2             <= '0;
            power_d3             <= '0;
            power_d4             <= '0;
            power_d5             <= '0;
            power_d6             <= '0;
            window_fill_count    <= 3'd0;
            window_energy        <= '0;
            energy_left          <= '0;
            energy_middle        <= '0;
            middle_bin           <= 11'd0;
            energy_history_count <= 2'd0;
        end else begin
            base_done <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    mem_req         <= 1'b0;
                    if (start) begin
                        state                <= STATE_SCAN;
                        mem_req              <= 1'b1;
                        mem_addr             <= MIN_SCAN_BIN[10:0];
                        receive_addr         <= MIN_SCAN_BIN[10:0];
                        base_valid           <= 1'b0;
                        base_index_500       <= 16'd0;
                        base_bin             <= 11'd0;
                        base_energy          <= '0;
                        power_d0             <= '0;
                        power_d1             <= '0;
                        power_d2             <= '0;
                        power_d3             <= '0;
                        power_d4             <= '0;
                        power_d5             <= '0;
                        power_d6             <= '0;
                        window_fill_count    <= 3'd0;
                        window_energy        <= '0;
                        energy_left          <= '0;
                        energy_middle        <= '0;
                        middle_bin           <= 11'd0;
                        energy_history_count <= 2'd0;
                    end
                end

                STATE_SCAN: begin
                    if (mem_req && mem_ready) begin
                        mem_req         <= 1'b0;
                    end

                    if (mem_rvalid) begin
                        power_d0 <= power_d1;
                        power_d1 <= power_d2;
                        power_d2 <= power_d3;
                        power_d3 <= power_d4;
                        power_d4 <= power_d5;
                        power_d5 <= power_d6;
                        power_d6 <= mem_rdata;

                        if (window_fill_count < 3'd6) begin
                            window_fill_count <= window_fill_count + 1'b1;
                        end else begin
                            window_energy <= new_window_energy;

                            if (energy_history_count == 2'd0) begin
                                energy_left          <= new_window_energy;
                                energy_history_count <= 2'd1;
                            end else if (energy_history_count == 2'd1) begin
                                energy_middle        <= new_window_energy;
                                middle_bin           <= new_window_center;
                                energy_history_count <= 2'd2;
                            end else if (peak_detected) begin
                                base_valid     <= 1'b1;
                                base_bin       <= middle_bin;
                                base_energy    <= energy_middle;
                                base_index_500 <= index_500_numerator[22:7];
                                state          <= STATE_DONE;
                            end else begin
                                energy_left   <= energy_middle;
                                energy_middle <= new_window_energy;
                                middle_bin    <= new_window_center;
                            end
                        end

                        if (!peak_detected) begin
                            if (receive_addr == MAX_SCAN_BIN[10:0]) begin
                                base_valid <= 1'b0;
                                state      <= STATE_DONE;
                            end else begin
                                receive_addr <= receive_addr + 1'b1;
                                mem_addr     <= receive_addr + 1'b1;
                                mem_req      <= 1'b1;
                            end
                        end
                    end
                end

                STATE_DONE: begin
                    mem_req         <= 1'b0;
                    base_done       <= 1'b1;
                    state           <= STATE_IDLE;
                end

                default: begin
                    state           <= STATE_IDLE;
                    mem_req         <= 1'b0;
                    base_valid      <= 1'b0;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
