`timescale 1ns/1ps
`default_nettype none

// ADC -> frame FIFO -> temporary FIR pass-through -> three-way measurement fanout.
// The temporary FIR performs no arithmetic.  It only delays the first FIFO
// handshake by one cycle so measurement_bram_writer can be started safely.
module measurement_pipeline_top #(
    parameter int unsigned FRAME_SIZE      = 65536,
    parameter int unsigned BRAM_ADDR_WIDTH = 18
) (
    input  wire logic                       adc_clk,
    input  wire logic                       adc_clk_drive,
    input  wire logic                       processing_clk,
    input  wire logic                       adc_rst,
    input  wire logic                       processing_rst,
    input  wire logic                       fifo_rst,
    input  wire logic                       capture_start,
    input  wire logic                       clear_error,
    input  wire logic                       adc_channel_select,
    input  wire logic [9:0]                 adc_data_a,
    input  wire logic [9:0]                 adc_data_b,

    output wire logic                       adc_clk_a,
    output wire logic                       adc_clk_b,
    output wire logic                       adc_oe_a,
    output wire logic                       adc_oe_b,

    output wire logic                       capture_busy,
    output wire logic                       frame_pending,
    output wire logic                       fifo_ready,
    output wire logic                       fifo_write_error,
    output wire logic                       fifo_read_error,
    output wire logic [31:0]                vpp_result,
    output wire logic [31:0]                mean_square_result,
    output wire logic                       vpp_result_valid,
    output wire logic                       mean_square_result_valid,
    output wire logic                       measurement_busy,
    output wire logic                       measurement_frame_done,
    output wire logic                       measurement_vpp_done,
    output wire logic                       measurement_mean_square_done,
    output wire logic                       measurement_wave_done,
    output wire logic                       measurement_error,
    output wire logic                       bram_en,
    output wire logic [3:0]                 bram_we,
    output wire logic [BRAM_ADDR_WIDTH-1:0] bram_addr,
    output wire logic [31:0]                bram_wrdata
);

    wire logic signed [15:0] adc_sample_a;
    wire logic signed [15:0] adc_sample_b;
    wire logic signed [15:0] selected_adc_sample;
    wire logic               adc_valid;

    wire logic signed [15:0] fifo_fir_data;
    wire logic               fifo_fir_valid;
    wire logic               fifo_fir_ready;
    wire logic               fifo_fir_first;
    wire logic               fifo_fir_last;
    wire logic               fifo_fir_frame_done;

    wire logic signed [15:0] split_data;
    wire logic               split_valid;
    wire logic               split_first;
    wire logic               split_last;
    wire logic               vpp_busy_unused;
    wire logic               vpp_error;
    wire logic               mean_square_overflow;
    wire logic               writer_error;

    typedef enum logic [1:0] {
        PASS_WAIT_FIRST,
        PASS_STREAM,
        PASS_WAIT_DONE
    } pass_state_t;
    pass_state_t pass_state;

    wire logic writer_start;

    initial begin
        assert (FRAME_SIZE == 65536)
            else $fatal(1, "The current peak and mean-square blocks require FRAME_SIZE=65536");
        assert (BRAM_ADDR_WIDTH >= 18)
            else $fatal(1, "A full 65536-sample waveform requires an 18-bit byte address");
    end

    assign selected_adc_sample = adc_channel_select ? adc_sample_b : adc_sample_a;

    adc_capture u_adc_capture (
        .clk        (adc_clk),
        .clk_drive  (adc_clk_drive),
        .rst        (adc_rst),
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

    fifo_wrap #(
        .DATA_WIDTH (16),
        .FRAME_SIZE (FRAME_SIZE)
    ) u_fifo_wrap (
        .wr_clk         (adc_clk),
        .wr_rst         (adc_rst),
        .rd_clk         (processing_clk),
        .rd_rst         (processing_rst),
        .fifo_rst       (fifo_rst),
        .adc_data       (selected_adc_sample),
        .adc_valid      (adc_valid),
        .capture_start  (capture_start),
        .clear_error    (clear_error),
        .fir_data       (fifo_fir_data),
        .fir_valid      (fifo_fir_valid),
        .fir_ready      (fifo_fir_ready),
        .fir_first      (fifo_fir_first),
        .fir_last       (fifo_fir_last),
        .fir_frame_done (fifo_fir_frame_done),
        .capture_busy   (capture_busy),
        .frame_pending  (frame_pending),
        .fifo_ready     (fifo_ready),
        .wr_error       (fifo_write_error),
        .rd_error       (fifo_read_error)
    );

    // Temporary FIR control.  The FIFO holds its first FWFT word while ready=0.
    // In that cycle writer_start arms all three destinations.  Subsequent
    // handshakes are broadcast without modifying the sample value.
    assign writer_start   = (pass_state == PASS_WAIT_FIRST) &&
                            fifo_fir_valid && fifo_fir_first;
    assign fifo_fir_ready = (pass_state == PASS_STREAM) && measurement_busy;
    assign split_data     = fifo_fir_data;
    assign split_valid    = fifo_fir_valid && fifo_fir_ready;
    assign split_first    = fifo_fir_first;
    assign split_last     = fifo_fir_last;
    assign fifo_fir_frame_done = measurement_frame_done;
    assign measurement_error = writer_error | vpp_error | mean_square_overflow;

    always_ff @(posedge processing_clk) begin
        if (processing_rst) begin
            pass_state <= PASS_WAIT_FIRST;
        end else begin
            unique case (pass_state)
                PASS_WAIT_FIRST: if (writer_start) pass_state <= PASS_STREAM;
                PASS_STREAM: begin
                    if (split_valid && split_last) pass_state <= PASS_WAIT_DONE;
                end
                PASS_WAIT_DONE: begin
                    if (measurement_frame_done) pass_state <= PASS_WAIT_FIRST;
                end
                default: pass_state <= PASS_WAIT_FIRST;
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
        .clk          (processing_clk),
        .rst          (processing_rst),
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
        .clk             (processing_clk),
        .rst             (processing_rst),
        .sample_in       (split_data),
        .sample_valid    (split_valid),
        .sample_first    (split_first),
        .sample_last     (split_last),
        .mean_square_out (mean_square_result),
        .result_valid    (mean_square_result_valid),
        .overflow        (mean_square_overflow)
    );

    measurement_bram_writer #(
        .WAVE_SAMPLE_COUNT (FRAME_SIZE),
        .BRAM_ADDR_WIDTH   (BRAM_ADDR_WIDTH)
    ) u_measurement_bram_writer (
        .clk            (processing_clk),
        .rst            (processing_rst),
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
        .vpp_done       (measurement_vpp_done),
        .vrms_done      (measurement_mean_square_done),
        .wave_done      (measurement_wave_done),
        .error          (writer_error),
        .bram_en        (bram_en),
        .bram_we        (bram_we),
        .bram_addr      (bram_addr),
        .bram_wrdata    (bram_wrdata)
    );

endmodule

`default_nettype wire
