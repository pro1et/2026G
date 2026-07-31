`timescale 1ns / 1ps
`default_nettype none

// ============================================================================
// Module: fir_measurement_chain
//
// Purpose:
//   Production integration top for the filtered time-domain measurement path.
//
// Data path:
//   clock_tree -> adc_capture -> fifo_wrap -> fir_wrap
//              -> peak_to_peak_detector
//              -> mean_square_calculator
//              -> measurement_bram_writer -> TIME_BRAM
//
// Frame contract:
//   - ADC and FIFO frame length: FRAME_SIZE=65536 samples.
//   - FIR input and output frame length: FRAME_SIZE=65536 samples.
//   - Vpp and mean-square are calculated from all filtered output samples.
//   - Only the first BRAM_SAMPLE_COUNT=32768 filtered samples are stored.
//   - TIME_BRAM W0 is filtered Vpp, W1 is filtered mean-square, and W2
//     onward contains the packed filtered waveform.
//   - RMS square root and voltage calibration are performed by the PS.
//
// Completion contract:
//   The FIFO frame is not released and capture_done is not asserted until
//   measurement_bram_writer has committed Vpp, mean-square, and waveform data.
//   fir_wrap's own completion pulse only marks the last filtered output.
// ============================================================================

module fir_measurement_chain #(
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

    wire signed [15:0] fifo_fir_data;
    wire               fifo_fir_valid;
    wire               fifo_fir_ready;
    wire               fifo_fir_first;
    wire               fifo_fir_last;
    wire               fifo_release_event;

    wire fifo_capture_busy;
    wire fifo_frame_pending;
    wire fifo_ready_32m;
    wire fifo_wr_error_32m;
    wire fifo_rd_error_100m;

    wire signed [15:0] filtered_data;
    wire               filtered_valid;
    wire               filtered_first;
    wire               filtered_last;
    wire               fir_output_frame_done;
    wire               fir_busy;
    wire               fir_protocol_error;
    wire               fir_saturation_error;
    wire               fir_input_fire;
    wire               writer_start;

    // One registered measurement-stream stage breaks the long path from the
    // FIR Compiler output through fir_wrap scaling/saturation and into the
    // peak-to-peak segment accumulation logic. All four fields are delayed
    // together, so the filtered frame boundaries and sample count are kept.
    reg signed [15:0] measurement_data;
    reg               measurement_valid;
    reg               measurement_first;
    reg               measurement_last;

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
    wire unused_fir_output_done;

    // These are four independent two-flop single-bit CDC chains. The
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

    assign time_bram_clk     = clk_100m;
    assign time_bram_rst     = rst_100m;
    assign unused_bram_dout  = ^time_bram_dout;
    assign unused_fir_output_done = fir_output_frame_done;

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

    // Start the BRAM writer when the first raw FIFO sample is accepted by FIR.
    // The configured FIR has ample pipeline latency before its first output,
    // so the writer is busy before filtered_valid can become active.
    assign fir_input_fire = fifo_fir_valid && fifo_fir_ready;
    assign writer_start   = fir_input_fire && fifo_fir_first;

    always @(posedge clk_100m) begin
        if (rst_100m) begin
            measurement_data  <= 16'sd0;
            measurement_valid <= 1'b0;
            measurement_first <= 1'b0;
            measurement_last  <= 1'b0;
        end else begin
            measurement_valid <= filtered_valid;
            measurement_first <= filtered_valid && filtered_first;
            measurement_last  <= filtered_valid && filtered_last;

            if (filtered_valid) begin
                measurement_data <= filtered_data;
            end
        end
    end

    assign capture_busy =
        fifo_capture_busy_sync || fifo_frame_pending_sync ||
        fir_busy || measurement_busy;

    assign capture_ready =
        locked && !rst_100m && fifo_ready_sync && !capture_busy &&
        !start_cdc_busy;

    // PS sees completion only after all enabled TIME_BRAM fields are committed.
    assign capture_done       = measurement_frame_done;
    assign fifo_release_event = measurement_frame_done;

    assign error =
        start_cdc_error || fifo_wr_error_sync || fifo_rd_error_100m ||
        fir_protocol_error || fir_saturation_error ||
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
        .fir_data       (fifo_fir_data),
        .fir_valid      (fifo_fir_valid),
        .fir_ready      (fifo_fir_ready),
        .fir_first      (fifo_fir_first),
        .fir_last       (fifo_fir_last),
        .fir_frame_done (fifo_release_event),
        .capture_busy   (fifo_capture_busy),
        .frame_pending  (fifo_frame_pending),
        .fifo_ready     (fifo_ready_32m),
        .wr_error       (fifo_wr_error_32m),
        .rd_error       (fifo_rd_error_100m)
    );

    fir_wrap #(
        .FRAME_SIZE   (FRAME_SIZE),
        .RESET_CYCLES (3)
    ) u_fir_wrap (
        .clk              (clk_100m),
        .rst              (rst_100m),
        .clear_error      (1'b0),
        .fir_data         (fifo_fir_data),
        .fir_valid        (fifo_fir_valid),
        .fir_ready        (fifo_fir_ready),
        .fir_first        (fifo_fir_first),
        .fir_last         (fifo_fir_last),
        .sample_data      (filtered_data),
        .sample_valid     (filtered_valid),
        .sample_first     (filtered_first),
        .sample_last      (filtered_last),
        .fir_frame_done   (fir_output_frame_done),
        .busy             (fir_busy),
        .protocol_error   (fir_protocol_error),
        .saturation_error (fir_saturation_error)
    );

    peak_to_peak_detector #(
        .DATA_WIDTH    (16),
        .FRAME_SIZE    (FRAME_SIZE),
        .SEGMENT_COUNT (16),
        .SEGMENT_SIZE  (4096),
        .TRIM_COUNT    (2)
    ) u_peak_to_peak_detector (
        .clk          (clk_100m),
        .rst          (rst_100m),
        .sample_data  (measurement_data),
        .sample_valid (measurement_valid),
        .sample_first (measurement_first),
        .sample_last  (measurement_last),
        .vpp_out      (vpp_result),
        .vpp_valid    (vpp_result_valid),
        .vpp_busy     (vpp_busy_unused),
        .vpp_error    (vpp_error)
    );

    mean_square_calculator u_mean_square_calculator (
        .clk             (clk_100m),
        .rst             (rst_100m),
        .sample_in       (measurement_data),
        .sample_valid    (measurement_valid),
        .sample_first    (measurement_first),
        .sample_last     (measurement_last),
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
        .wave_data      (measurement_data),
        .wave_valid     (measurement_valid),
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
            $error("fir_measurement_chain: FRAME_SIZE must be 65536");
        end
        if ((BRAM_SAMPLE_COUNT <= 0) ||
            (BRAM_SAMPLE_COUNT > FRAME_SIZE) ||
            ((BRAM_SAMPLE_COUNT % 2) != 0)) begin
            $error("fir_measurement_chain: invalid BRAM_SAMPLE_COUNT");
        end
        if (BRAM_SAMPLE_COUNT != 32768) begin
            $error("fir_measurement_chain: current TIME_BRAM contract requires 32768 samples");
        end
        if ((ADC_CHANNEL < 0) || (ADC_CHANNEL > 1)) begin
            $error("fir_measurement_chain: ADC_CHANNEL must be 0 or 1");
        end
    end
    // synthesis translate_on

endmodule

`default_nettype wire
