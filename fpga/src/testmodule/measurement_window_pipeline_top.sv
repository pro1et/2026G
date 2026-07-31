`timescale 1ns/1ps
`default_nettype none

// ADC capture -> asynchronous FIFO -> FIR -> four-way measurement fanout.
// Three branches feed Vpp, mean-square and waveform BRAM aggregation.  The
// fourth branch performs fixed 16:1 decimation and a 4096-point periodic Hann
// window, whose ready/valid stream is exported for the future FFT input path.
module measurement_window_pipeline_top #(
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

    output wire logic signed [15:0]         window_data,
    output wire logic                       window_valid,
    input  wire logic                       window_ready,
    output wire logic                       window_first,
    output wire logic                       window_last,

    output wire logic [31:0]                vpp_result,
    output wire logic [31:0]                mean_square_result,
    output wire logic                       vpp_result_valid,
    output wire logic                       mean_square_result_valid,
    output wire logic                       capture_busy,
    output wire logic                       frame_pending,
    output wire logic                       fifo_ready,
    output wire logic                       measurement_frame_done,
    output wire logic                       frequency_frame_valid,
    output wire logic                       pipeline_error
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
    wire logic               fir_input_valid;
    wire logic               fir_input_ready;
    wire logic               fir_frame_done;

    wire logic signed [15:0] filtered_data;
    wire logic               filtered_valid;
    wire logic               filtered_first;
    wire logic               filtered_last;

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
    wire logic signed [15:0] spectrum_stream_data;
    wire logic               spectrum_stream_valid;
    wire logic               spectrum_stream_first;
    wire logic               spectrum_stream_last;

    wire logic signed [15:0] decim_data;
    wire logic               decim_valid;
    wire logic               decim_ready;
    wire logic               decim_first;
    wire logic               decim_last;
    wire logic               decim_busy;
    wire logic               decim_input_frame_done;
    wire logic               decim_frame_done;
    wire logic               decim_protocol_error;
    wire logic               decim_overrun_error;
    wire logic               hann_protocol_error;

    wire logic               fifo_write_error;
    wire logic               fifo_read_error;
    wire logic               fir_busy;
    wire logic               fir_protocol_error;
    wire logic               fir_saturation_error;
    wire logic               vpp_busy_unused;
    wire logic               vpp_error;
    wire logic               mean_square_overflow;
    wire logic               writer_error;
    wire logic               measurement_busy;
    wire logic               measurement_vpp_done;
    wire logic               measurement_mean_square_done;
    wire logic               measurement_wave_done;
    wire logic               writer_start;
    wire logic               bram_en_unused;
    wire logic [3:0]         bram_we_unused;
    wire logic [BRAM_ADDR_WIDTH-1:0] bram_addr_unused;
    wire logic [31:0]        bram_wrdata_unused;

    typedef enum logic [1:0] {
        STATE_WAIT_FIRST,
        STATE_STREAM,
        STATE_WAIT_WRITER
    } pipeline_state_t;
    pipeline_state_t pipeline_state;

    initial begin
        assert (FRAME_SIZE == 65536)
            else $fatal(1, "measurement_window_pipeline_top requires FRAME_SIZE=65536");
        assert (BRAM_ADDR_WIDTH >= 18)
            else $fatal(1, "measurement_window_pipeline_top requires BRAM_ADDR_WIDTH>=18");
    end

    assign selected_adc_sample = adc_channel_select ? adc_sample_b : adc_sample_a;
    assign writer_start = (pipeline_state == STATE_WAIT_FIRST)
                       && fifo_fir_valid && fifo_fir_first && fir_input_ready;
    assign fifo_fir_ready = (pipeline_state == STATE_STREAM) && fir_input_ready;
    assign fir_input_valid = (pipeline_state == STATE_STREAM) && fifo_fir_valid;
    assign pipeline_error = fifo_write_error | fifo_read_error |
                            fir_protocol_error | fir_saturation_error |
                            vpp_error | mean_square_overflow | writer_error |
                            decim_protocol_error | decim_overrun_error |
                            hann_protocol_error;

    always_ff @(posedge processing_clk) begin
        if (processing_rst) begin
            pipeline_state <= STATE_WAIT_FIRST;
        end else begin
            unique case (pipeline_state)
                STATE_WAIT_FIRST: if (writer_start) pipeline_state <= STATE_STREAM;
                STATE_STREAM: begin
                    if (wave_stream_valid && wave_stream_last)
                        pipeline_state <= STATE_WAIT_WRITER;
                end
                STATE_WAIT_WRITER: begin
                    if (measurement_frame_done)
                        pipeline_state <= STATE_WAIT_FIRST;
                end
                default: pipeline_state <= STATE_WAIT_FIRST;
            endcase
        end
    end

    adc_capture u_adc_capture (
        .clk(adc_clk), .clk_drive(adc_clk_drive), .rst(adc_rst),
        .adc_data_a(adc_data_a), .adc_data_b(adc_data_b),
        .adc_clk_a(adc_clk_a), .adc_clk_b(adc_clk_b),
        .adc_oe_a(adc_oe_a), .adc_oe_b(adc_oe_b),
        .data_a(adc_sample_a), .data_b(adc_sample_b), .out_valid(adc_valid)
    );

    fifo_wrap #(.DATA_WIDTH(16), .FRAME_SIZE(FRAME_SIZE)) u_fifo_wrap (
        .wr_clk(adc_clk), .wr_rst(adc_rst),
        .rd_clk(processing_clk), .rd_rst(processing_rst), .fifo_rst(fifo_rst),
        .adc_data(selected_adc_sample), .adc_valid(adc_valid),
        .capture_start(capture_start), .clear_error(clear_error),
        .fir_data(fifo_fir_data), .fir_valid(fifo_fir_valid),
        .fir_ready(fifo_fir_ready), .fir_first(fifo_fir_first),
        .fir_last(fifo_fir_last), .fir_frame_done(fir_frame_done),
        .capture_busy(capture_busy), .frame_pending(frame_pending),
        .fifo_ready(fifo_ready), .wr_error(fifo_write_error),
        .rd_error(fifo_read_error)
    );

    fir_wrap #(.FRAME_SIZE(FRAME_SIZE)) u_fir_wrap (
        .clk(processing_clk), .rst(processing_rst), .clear_error(clear_error),
        .fir_data(fifo_fir_data), .fir_valid(fir_input_valid),
        .fir_ready(fir_input_ready), .fir_first(fifo_fir_first),
        .fir_last(fifo_fir_last), .sample_data(filtered_data),
        .sample_valid(filtered_valid), .sample_first(filtered_first),
        .sample_last(filtered_last), .fir_frame_done(fir_frame_done),
        .busy(fir_busy), .protocol_error(fir_protocol_error),
        .saturation_error(fir_saturation_error)
    );

    measurement_stream_splitter u_measurement_stream_splitter (
        .in_data(filtered_data), .in_valid(filtered_valid),
        .in_first(filtered_first), .in_last(filtered_last),
        .vpp_data(vpp_stream_data), .vpp_valid(vpp_stream_valid),
        .vpp_first(vpp_stream_first), .vpp_last(vpp_stream_last),
        .mean_square_data(mean_square_stream_data),
        .mean_square_valid(mean_square_stream_valid),
        .mean_square_first(mean_square_stream_first),
        .mean_square_last(mean_square_stream_last),
        .wave_data(wave_stream_data), .wave_valid(wave_stream_valid),
        .wave_first(wave_stream_first_unused), .wave_last(wave_stream_last),
        .spectrum_data(spectrum_stream_data),
        .spectrum_valid(spectrum_stream_valid),
        .spectrum_first(spectrum_stream_first),
        .spectrum_last(spectrum_stream_last)
    );

    peak_to_peak_detector #(
        .DATA_WIDTH(16), .FRAME_SIZE(FRAME_SIZE), .SEGMENT_COUNT(16),
        .SEGMENT_SIZE(4096), .TRIM_COUNT(2)
    ) u_peak_to_peak_detector (
        .clk(processing_clk), .rst(processing_rst),
        .sample_data(vpp_stream_data), .sample_valid(vpp_stream_valid),
        .sample_first(vpp_stream_first), .sample_last(vpp_stream_last),
        .vpp_out(vpp_result), .vpp_valid(vpp_result_valid),
        .vpp_busy(vpp_busy_unused), .vpp_error(vpp_error)
    );

    mean_square_calculator u_mean_square_calculator (
        .clk(processing_clk), .rst(processing_rst),
        .sample_in(mean_square_stream_data),
        .sample_valid(mean_square_stream_valid),
        .sample_first(mean_square_stream_first),
        .sample_last(mean_square_stream_last),
        .mean_square_out(mean_square_result),
        .result_valid(mean_square_result_valid), .overflow(mean_square_overflow)
    );

    measurement_bram_writer #(
        .WAVE_SAMPLE_COUNT(FRAME_SIZE), .BRAM_ADDR_WIDTH(BRAM_ADDR_WIDTH)
    ) u_measurement_bram_writer (
        .clk(processing_clk), .rst(processing_rst), .start(writer_start),
        .channel_enable(3'b111), .vpp_data(vpp_result),
        .vpp_valid(vpp_result_valid), .vrms_data(mean_square_result),
        .vrms_valid(mean_square_result_valid), .wave_data(wave_stream_data),
        .wave_valid(wave_stream_valid), .busy(measurement_busy),
        .frame_done(measurement_frame_done), .vpp_done(measurement_vpp_done),
        .vrms_done(measurement_mean_square_done), .wave_done(measurement_wave_done),
        .error(writer_error), .bram_en(bram_en_unused), .bram_we(bram_we_unused),
        .bram_addr(bram_addr_unused), .bram_wrdata(bram_wrdata_unused)
    );

    downsampler_16 u_downsampler_16 (
        .clk(processing_clk), .rst(processing_rst), .clear_error(clear_error),
        .fir_data(spectrum_stream_data), .fir_valid(spectrum_stream_valid),
        .fir_first(spectrum_stream_first), .fir_last(spectrum_stream_last),
        .decim_data(decim_data), .decim_valid(decim_valid),
        .decim_ready(decim_ready), .decim_first(decim_first),
        .decim_last(decim_last), .busy(decim_busy),
        .input_frame_done(decim_input_frame_done),
        .decim_frame_done(decim_frame_done), .frame_valid(frequency_frame_valid),
        .protocol_error(decim_protocol_error), .overrun_error(decim_overrun_error)
    );

    hann_window_4096 u_hann_window_4096 (
        .clk(processing_clk), .rst(processing_rst), .clear_error(clear_error),
        .sample_data(decim_data), .sample_valid(decim_valid),
        .sample_ready(decim_ready), .sample_first(decim_first),
        .sample_last(decim_last), .window_data(window_data),
        .window_valid(window_valid), .window_ready(window_ready),
        .window_first(window_first), .window_last(window_last),
        .protocol_error(hann_protocol_error)
    );

endmodule

`default_nettype wire
