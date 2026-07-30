`timescale 1ns/1ps
`default_nettype none

// Full ADC -> asynchronous FIFO -> FIR -> three-way measurement pipeline.
// The BRAM writer interface is exported directly; no physical BRAM is needed.
module measurement_timing_pipeline_top #(
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
    output wire logic                       fir_busy,
    output wire logic                       fir_protocol_error,
    output wire logic                       fir_saturation_error,

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
    wire logic               fir_input_valid;
    wire logic               fifo_fir_first;
    wire logic               fifo_fir_last;
    wire logic               fir_frame_done;

    wire logic signed [15:0] filtered_data;
    wire logic               filtered_valid;
    wire logic               filtered_first;
    wire logic               filtered_last;
    wire logic               fir_input_ready;

    wire logic signed [15:0] vpp_stream_data;
    wire logic               vpp_stream_valid;
    wire logic               vpp_stream_first;
    wire logic               vpp_stream_last;
    wire logic signed [15:0] mean_square_stream_data;
    wire logic               mean_square_stream_valid;
    wire logic               mean_square_stream_first;
    wire logic               mean_square_stream_last;
    wire logic signed [15:0] wave_stream_data;
    wire logic               wave_stream_valid;
    wire logic               wave_stream_first_unused;
    wire logic               wave_stream_last;

    wire logic               vpp_busy_unused;
    wire logic               vpp_error;
    wire logic               mean_square_overflow;
    wire logic [31:0]        vpp_result;
    wire logic [31:0]        mean_square_result;
    wire logic               vpp_result_valid;
    wire logic               mean_square_result_valid;
    wire logic               writer_error;
    wire logic               writer_start;

    typedef enum logic [1:0] {
        STATE_WAIT_FIRST,
        STATE_STREAM,
        STATE_WAIT_WRITER
    } pipeline_state_t;
    pipeline_state_t pipeline_state;

    initial begin
        assert (FRAME_SIZE == 65536)
            else $fatal(1, "measurement_timing_pipeline_top requires FRAME_SIZE=65536");
        assert (BRAM_ADDR_WIDTH >= 18)
            else $fatal(1, "measurement_timing_pipeline_top requires BRAM_ADDR_WIDTH>=18");
    end

    assign selected_adc_sample = adc_channel_select ? adc_sample_b : adc_sample_a;

    // Hold the FIFO's FWFT first word for one processing clock while the BRAM
    // writer is armed. FIR input starts on the following clock.
    assign writer_start = (pipeline_state == STATE_WAIT_FIRST)
                       && fifo_fir_valid
                       && fifo_fir_first
                       && fir_input_ready;
    assign fifo_fir_ready = (pipeline_state == STATE_STREAM) && fir_input_ready;
    assign fir_input_valid = (pipeline_state == STATE_STREAM) && fifo_fir_valid;

    assign measurement_error = writer_error
                             | vpp_error
                             | mean_square_overflow
                             | fir_protocol_error
                             | fir_saturation_error;

    always_ff @(posedge processing_clk) begin
        if (processing_rst) begin
            pipeline_state <= STATE_WAIT_FIRST;
        end else begin
            unique case (pipeline_state)
                STATE_WAIT_FIRST: begin
                    if (writer_start) begin
                        pipeline_state <= STATE_STREAM;
                    end
                end
                STATE_STREAM: begin
                    if (wave_stream_valid && wave_stream_last) begin
                        pipeline_state <= STATE_WAIT_WRITER;
                    end
                end
                STATE_WAIT_WRITER: begin
                    if (measurement_frame_done) begin
                        pipeline_state <= STATE_WAIT_FIRST;
                    end
                end
                default: pipeline_state <= STATE_WAIT_FIRST;
            endcase
        end
    end

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
        .fir_frame_done (fir_frame_done),
        .capture_busy   (capture_busy),
        .frame_pending  (frame_pending),
        .fifo_ready     (fifo_ready),
        .wr_error       (fifo_write_error),
        .rd_error       (fifo_read_error)
    );

    fir_wrap #(
        .FRAME_SIZE (FRAME_SIZE)
    ) u_fir_wrap (
        .clk              (processing_clk),
        .rst              (processing_rst),
        .clear_error      (clear_error),
        .fir_data         (fifo_fir_data),
        .fir_valid        (fir_input_valid),
        .fir_ready        (fir_input_ready),
        .fir_first        (fifo_fir_first),
        .fir_last         (fifo_fir_last),
        .sample_data      (filtered_data),
        .sample_valid     (filtered_valid),
        .sample_first     (filtered_first),
        .sample_last      (filtered_last),
        .fir_frame_done   (fir_frame_done),
        .busy             (fir_busy),
        .protocol_error   (fir_protocol_error),
        .saturation_error (fir_saturation_error)
    );

    measurement_stream_splitter u_measurement_stream_splitter (
        .in_data           (filtered_data),
        .in_valid          (filtered_valid),
        .in_first          (filtered_first),
        .in_last           (filtered_last),
        .vpp_data          (vpp_stream_data),
        .vpp_valid         (vpp_stream_valid),
        .vpp_first         (vpp_stream_first),
        .vpp_last          (vpp_stream_last),
        .mean_square_data  (mean_square_stream_data),
        .mean_square_valid (mean_square_stream_valid),
        .mean_square_first (mean_square_stream_first),
        .mean_square_last  (mean_square_stream_last),
        .wave_data         (wave_stream_data),
        .wave_valid        (wave_stream_valid),
        .wave_first        (wave_stream_first_unused),
        .wave_last         (wave_stream_last)
    );

    peak_to_peak_detector #(
        .DATA_WIDTH    (16),
        .FRAME_SIZE    (FRAME_SIZE),
        .SEGMENT_COUNT (16),
        .SEGMENT_SIZE  (4096),
        .TRIM_COUNT    (2)
    ) u_peak_to_peak_detector (
        .clk          (processing_clk),
        .rst          (processing_rst),
        .sample_data  (vpp_stream_data),
        .sample_valid (vpp_stream_valid),
        .sample_first (vpp_stream_first),
        .sample_last  (vpp_stream_last),
        .vpp_out      (vpp_result),
        .vpp_valid    (vpp_result_valid),
        .vpp_busy     (vpp_busy_unused),
        .vpp_error    (vpp_error)
    );

    mean_square_calculator u_mean_square_calculator (
        .clk             (processing_clk),
        .rst             (processing_rst),
        .sample_in       (mean_square_stream_data),
        .sample_valid    (mean_square_stream_valid),
        .sample_first    (mean_square_stream_first),
        .sample_last     (mean_square_stream_last),
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
        .wave_data      (wave_stream_data),
        .wave_valid     (wave_stream_valid),
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
