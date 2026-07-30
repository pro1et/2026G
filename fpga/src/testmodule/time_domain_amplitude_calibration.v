`timescale 1ns / 1ps
`default_nettype none

// ============================================================================
// Module: time_domain_amplitude_calibration
//
// Purpose:
//   Production integration top for the time-domain amplitude path.
//
// Data path:
//   clock_tree -> adc_capture -> fifo_wrap
//              -> peak_to_peak_detector
//              -> mean_square_calculator
//              -> measurement_bram_writer -> TIME_BRAM
//
// Measurement definition:
//   - One acquisition frame contains FRAME_SIZE=65536 signed ADC samples.
//   - Vpp and mean-square are calculated from all 65536 samples.
//   - Only the first BRAM_SAMPLE_COUNT=32768 samples are stored as waveform.
//   - BRAM W0 is Vpp, W1 is mean-square, and W2 onward is packed waveform.
//   - RMS square root and voltage calibration are performed by the PS.
//
// Integration policy:
//   fifo_wrap and the three measurement blocks are not modified here.  This
//   top supplies the first-word hold/start sequence required by
//   measurement_bram_writer and returns frame_done to fifo_wrap only after all
//   enabled BRAM fields have actually been written.
// ============================================================================

module time_domain_amplitude_calibration #(
    parameter integer FRAME_SIZE        = 65536,
    parameter integer BRAM_SAMPLE_COUNT = 32768,
    parameter integer ADC_CHANNEL       = 0
) (
    input  wire        clk_50m,
    input  wire        rst_n,
    input  wire        capture_start,

    input  wire [9:0]  adc_data_a,
    input  wire [9:0]  adc_data_b,
    output wire        adc_clk_a,
    output wire        adc_clk_b,
    output wire        adc_oe_a,
    output wire        adc_oe_b,

    output wire        clk_100m_out,
    output wire        rst_100m_n_out,

    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM CLK" *)
    output wire        time_bram_clk,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME TIME_BRAM, MASTER_TYPE BRAM_CTRL, MEM_ECC NONE, MEM_SIZE 131072, MEM_WIDTH 32, READ_LATENCY 1" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM RST" *)
    output wire        time_bram_rst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM EN" *)
    output wire        time_bram_en,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM WE" *)
    output wire [3:0]  time_bram_we,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM ADDR" *)
    output wire [16:0] time_bram_addr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM DIN" *)
    output wire [31:0] time_bram_din,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM DOUT" *)
    input  wire [31:0] time_bram_dout,

    output wire        capture_ready,
    output wire        capture_busy,
    output wire        capture_done,
    output wire        error,
    output wire        locked
);

    localparam [1:0] PASS_WAIT_FIRST = 2'd0;
    localparam [1:0] PASS_STREAM     = 2'd1;
    localparam [1:0] PASS_WAIT_DONE  = 2'd2;

    wire clk_100m;
    wire clk_32m;
    wire clk_32m_adc;
    wire rst_100m;
    wire rst_32m;
    wire fifo_rst;

    reg  capture_start_d;
    wire capture_start_pulse;
    wire start_cdc_busy;
    wire start_cdc_error;
    wire capture_start_32m;

    wire signed [15:0] adc_sample_a;
    wire signed [15:0] adc_sample_b;
    wire signed [15:0] adc_sample_selected;
    wire               adc_valid;

    wire signed [15:0] fir_data;
    wire               fir_valid;
    wire               fir_ready;
    wire               fir_first;
    wire               fir_last;
    wire               fir_frame_done;

    wire fifo_capture_busy;
    wire fifo_frame_pending;
    wire fifo_ready_32m;
    wire fifo_wr_error_32m;
    wire fifo_rd_error_100m;

    reg  [1:0]         pass_state;
    wire               writer_start;
    wire signed [15:0] split_data;
    wire               split_valid;
    wire               split_first;
    wire               split_last;

    wire [31:0] vpp_result;
    wire        vpp_result_valid;
    wire        vpp_busy_unused;
    wire        vpp_error;

    wire [31:0] mean_square_result;
    wire        mean_square_result_valid;
    wire        mean_square_overflow;

    wire measurement_busy;
    wire measurement_frame_done;
    wire measurement_vpp_done_unused;
    wire measurement_mean_square_done_unused;
    wire measurement_wave_done_unused;
    wire measurement_writer_error;
    wire unused_bram_dout;

    // These are four independent two-flop single-bit CDC chains.  The
    // attributes prevent SRL extraction and keep each meta/sync pair adjacent.
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg fifo_capture_busy_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg fifo_capture_busy_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg fifo_frame_pending_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg fifo_frame_pending_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg fifo_ready_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg fifo_ready_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg fifo_wr_error_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg fifo_wr_error_sync;

    assign clk_100m_out   = clk_100m;
    assign rst_100m_n_out = ~rst_100m;
    assign fifo_rst       = ~rst_n | ~locked;

    assign time_bram_clk = clk_100m;
    assign time_bram_rst = rst_100m;
    assign unused_bram_dout = ^time_bram_dout;

    assign adc_sample_selected =
        (ADC_CHANNEL == 0) ? adc_sample_a : adc_sample_b;

    // capture_start is generated in the 100 MHz measurement-control domain.
    // Convert its rising edge to one event before crossing into the ADC domain.
    always @(posedge clk_100m) begin
        if (rst_100m) begin
            capture_start_d <= 1'b0;
        end else begin
            capture_start_d <= capture_start;
        end
    end

    assign capture_start_pulse = capture_start && !capture_start_d;

    // Synchronize FIFO write-domain status into the 100 MHz control domain.
    always @(posedge clk_100m) begin
        if (rst_100m) begin
            fifo_capture_busy_meta  <= 1'b0;
            fifo_capture_busy_sync  <= 1'b0;
            fifo_frame_pending_meta <= 1'b0;
            fifo_frame_pending_sync <= 1'b0;
            fifo_ready_meta         <= 1'b0;
            fifo_ready_sync         <= 1'b0;
            fifo_wr_error_meta      <= 1'b0;
            fifo_wr_error_sync      <= 1'b0;
        end else begin
            fifo_capture_busy_meta  <= fifo_capture_busy;
            fifo_capture_busy_sync  <= fifo_capture_busy_meta;
            fifo_frame_pending_meta <= fifo_frame_pending;
            fifo_frame_pending_sync <= fifo_frame_pending_meta;
            fifo_ready_meta         <= fifo_ready_32m;
            fifo_ready_sync         <= fifo_ready_meta;
            fifo_wr_error_meta      <= fifo_wr_error_32m;
            fifo_wr_error_sync      <= fifo_wr_error_meta;
        end
    end

    assign capture_busy =
        fifo_capture_busy_sync || fifo_frame_pending_sync ||
        measurement_busy || (pass_state != PASS_WAIT_FIRST);

    assign capture_ready =
        locked && !rst_100m && fifo_ready_sync && !capture_busy &&
        !start_cdc_busy;

    // The PS-visible done event is issued only after Vpp, mean-square and the
    // selected waveform samples have all been committed to TIME_BRAM.
    assign capture_done = measurement_frame_done;
    assign fir_frame_done = measurement_frame_done;

    assign error =
        start_cdc_error || fifo_wr_error_sync || fifo_rd_error_100m ||
        vpp_error || mean_square_overflow || measurement_writer_error;

    clock_tree u_clock_tree (
        .clk_50m     (clk_50m),
        .rst_n       (rst_n),
        .clk_100m    (clk_100m),
        .clk_32m     (clk_32m),
        .clk_32m_adc (clk_32m_adc),
        .rst_100m    (rst_100m),
        .rst_32m     (rst_32m),
        .locked      (locked)
    );

    adc_capture u_adc_capture (
        .clk        (clk_32m),
        .clk_drive  (clk_32m_adc),
        .rst        (rst_32m),
        .adc_data_a (adc_data_a),
        .adc_data_b (adc_data_b),
        .adc_clk_a  (adc_clk_a),
        .adc_clk_b  (adc_clk_b),
        .adc_oe_a   (adc_oe_a),
        .adc_oe_b   (adc_oe_b),
        .data_a     (adc_sample_a),
        .data_b     (adc_sample_b),
        .out_valid  (adc_valid)
    );

    af_cdc u_start_cdc (
        .src_clk            (clk_100m),
        .src_rst            (rst_100m),
        .src_event          (capture_start_pulse),
        .src_busy           (start_cdc_busy),
        .src_protocol_error (start_cdc_error),
        .dst_clk            (clk_32m),
        .dst_rst            (rst_32m),
        .dst_event          (capture_start_32m)
    );

    fifo_wrap #(
        .DATA_WIDTH (16),
        .FRAME_SIZE (FRAME_SIZE)
    ) u_fifo_wrap (
        .wr_clk         (clk_32m),
        .wr_rst         (rst_32m),
        .rd_clk         (clk_100m),
        .rd_rst         (rst_100m),
        .fifo_rst       (fifo_rst),
        .adc_data       (adc_sample_selected),
        .adc_valid      (adc_valid),
        .capture_start  (capture_start_32m),
        .clear_error    (1'b0),
        .fir_data       (fir_data),
        .fir_valid      (fir_valid),
        .fir_ready      (fir_ready),
        .fir_first      (fir_first),
        .fir_last       (fir_last),
        .fir_frame_done (fir_frame_done),
        .capture_busy   (fifo_capture_busy),
        .frame_pending  (fifo_frame_pending),
        .fifo_ready     (fifo_ready_32m),
        .wr_error       (fifo_wr_error_32m),
        .rd_error       (fifo_rd_error_100m)
    );

    // Hold the FIFO's FWFT first word for one cycle while the writer accepts
    // start.  Streaming begins only after measurement_busy becomes active.
    assign writer_start = (pass_state == PASS_WAIT_FIRST) &&
                          fir_valid && fir_first;
    assign fir_ready    = (pass_state == PASS_STREAM) &&
                          measurement_busy;
    assign split_data   = fir_data;
    assign split_valid  = fir_valid && fir_ready;
    assign split_first  = fir_first;
    assign split_last   = fir_last;

    always @(posedge clk_100m) begin
        if (rst_100m) begin
            pass_state <= PASS_WAIT_FIRST;
        end else begin
            case (pass_state)
                PASS_WAIT_FIRST: begin
                    if (writer_start) begin
                        pass_state <= PASS_STREAM;
                    end
                end

                PASS_STREAM: begin
                    if (split_valid && split_last) begin
                        pass_state <= PASS_WAIT_DONE;
                    end
                end

                PASS_WAIT_DONE: begin
                    if (measurement_frame_done) begin
                        pass_state <= PASS_WAIT_FIRST;
                    end
                end

                default: begin
                    pass_state <= PASS_WAIT_FIRST;
                end
            endcase
        end
    end

    peak_to_peak_detector #(
        .DATA_WIDTH    (16),
        .FRAME_SIZE    (FRAME_SIZE),
        .SEGMENT_COUNT (16),
        .SEGMENT_SIZE  (4096),
        .TRIM_COUNT    (2)
    ) u_peak_to_peak_detector (
        .clk          (clk_100m),
        .rst          (rst_100m),
        .sample_data  (split_data),
        .sample_valid (split_valid),
        .sample_first (split_first),
        .sample_last  (split_last),
        .vpp_out      (vpp_result),
        .vpp_valid    (vpp_result_valid),
        .vpp_busy     (vpp_busy_unused),
        .vpp_error    (vpp_error)
    );

    mean_square_calculator u_mean_square_calculator (
        .clk             (clk_100m),
        .rst             (rst_100m),
        .sample_in       (split_data),
        .sample_valid    (split_valid),
        .sample_first    (split_first),
        .sample_last     (split_last),
        .mean_square_out (mean_square_result),
        .result_valid    (mean_square_result_valid),
        .overflow        (mean_square_overflow)
    );

    measurement_bram_writer #(
        .WAVE_SAMPLE_COUNT (BRAM_SAMPLE_COUNT),
        .BRAM_ADDR_WIDTH   (17)
    ) u_measurement_bram_writer (
        .clk            (clk_100m),
        .rst            (rst_100m),
        .start          (writer_start),
        .channel_enable (3'b111),
        .vpp_data       (vpp_result),
        .vpp_valid      (vpp_result_valid),
        .vrms_data      (mean_square_result),
        .vrms_valid     (mean_square_result_valid),
        .wave_data      (split_data),
        .wave_valid     (split_valid),
        .busy           (measurement_busy),
        .frame_done     (measurement_frame_done),
        .vpp_done       (measurement_vpp_done_unused),
        .vrms_done      (measurement_mean_square_done_unused),
        .wave_done      (measurement_wave_done_unused),
        .error          (measurement_writer_error),
        .bram_en        (time_bram_en),
        .bram_we        (time_bram_we),
        .bram_addr      (time_bram_addr),
        .bram_wrdata    (time_bram_din)
    );

    // synthesis translate_off
    initial begin
        if (FRAME_SIZE != 65536) begin
            $error("time_domain_amplitude_calibration: FRAME_SIZE must be 65536");
        end
        if ((BRAM_SAMPLE_COUNT <= 0) ||
            (BRAM_SAMPLE_COUNT > FRAME_SIZE) ||
            ((BRAM_SAMPLE_COUNT % 2) != 0)) begin
            $error("time_domain_amplitude_calibration: invalid BRAM_SAMPLE_COUNT");
        end
        if (BRAM_SAMPLE_COUNT != 32768) begin
            $error("time_domain_amplitude_calibration: current TIME_BRAM contract requires 32768 samples");
        end
        if ((ADC_CHANNEL < 0) || (ADC_CHANNEL > 1)) begin
            $error("time_domain_amplitude_calibration: ADC_CHANNEL must be 0 or 1");
        end
    end
    // synthesis translate_on

endmodule

`default_nettype wire
