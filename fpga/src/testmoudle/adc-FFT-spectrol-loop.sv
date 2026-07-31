`timescale 1ns/1ps
`default_nettype none

// Complete single-channel measurement loop:
// ADC -> FIFO -> FIR -> four-way splitter
//   1) peak-to-peak detector
//   2) mean-square calculator
//   3) waveform path to measurement_bram_writer
//   4) decimator -> Hann -> FFT -> power spectrum -> spectrol
// spectrol read service -> base detector -> energy calculator.
//
// The energy calculator result-BRAM write port is deliberately exported.  The
// top level does not instantiate a result BRAM, so these writes are also the
// final result interface requested by the system integration.
module \adc-FFT-spectrol-loop #(
    parameter int unsigned FRAME_SIZE                  = 65536,
    parameter int unsigned MEASUREMENT_BRAM_ADDR_WIDTH = 18,
    parameter int unsigned SPECTRUM_BRAM_RD_LATENCY    = 2,
    parameter logic [34:0] BASE_DETECT_THRESHOLD       = 35'd500,
    parameter logic [34:0] BASE_PROMINENCE_THRESHOLD   = 35'd0,
    parameter logic [31:0] ENERGY_ABSOLUTE_THRESHOLD   = 32'd0,
    parameter logic [15:0] ENERGY_RATIO_NUM            = 16'd1,
    parameter logic [15:0] ENERGY_RATIO_DEN            = 16'd100
) (
    input  wire logic         adc_clk,
    input  wire logic         adc_clk_drive,
    input  wire logic         processing_clk,
    input  wire logic         adc_rst,
    input  wire logic         processing_rst,
    input  wire logic         fifo_rst,
    input  wire logic         capture_start,
    input  wire logic         clear_error,
    input  wire logic         adc_channel_select,
    input  wire logic [9:0]   adc_data_a,
    input  wire logic [9:0]   adc_data_b,

    output wire logic         adc_clk_a,
    output wire logic         adc_clk_b,
    output wire logic         adc_oe_a,
    output wire logic         adc_oe_b,

    // External spectrum BRAM port used by spectrol.
    output wire logic         spectrum_bram_en,
    output wire logic         spectrum_bram_we,
    output wire logic [10:0]  spectrum_bram_addr,
    output wire logic [31:0]  spectrum_bram_din,
    input  wire logic [31:0]  spectrum_bram_dout,

    // Final energy-calculator result stream (word address and 32-bit data).
    output wire logic         energy_result_en,
    output wire logic         energy_result_we,
    output wire logic [3:0]   energy_result_addr,
    output wire logic [31:0]  energy_result_data,
    output wire logic         energy_result_valid,
    output wire logic         energy_done,
    output wire logic [2:0]   harmonic_present_mask,
    output wire logic [2:0]   position_valid_mask,
    output wire logic         energy_overflow,

    output wire logic         base_valid,
    output wire logic [15:0]  base_index_500,
    output wire logic [10:0]  base_bin,
    output wire logic [34:0]  base_energy,
    output wire logic [31:0]  vpp_result,
    output wire logic [31:0]  mean_square_result,
    output wire logic         measurement_frame_done,
    output wire logic         spectrum_frame_done,
    output wire logic         capture_busy,
    output wire logic         frame_pending,
    output wire logic         fifo_ready,
    output wire logic         fft_channel_halt_status,
    output wire logic         pipeline_error
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
    wire logic               wave_stream_first;
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
    wire logic               frequency_frame_valid;

    wire logic signed [15:0] window_data;
    wire logic               window_valid;
    wire logic               window_ready;
    wire logic               window_first;
    wire logic               window_last;

    wire logic signed [19:0] fft_re;
    wire logic signed [19:0] fft_im;
    wire logic [11:0]        fft_bin;
    wire logic               fft_valid;
    wire logic               fft_ready;
    wire logic               fft_first;
    wire logic               fft_last;

    wire logic [31:0] power_data;
    wire logic [10:0] power_bin;
    wire logic        power_valid;
    wire logic        power_ready;
    wire logic        power_first;
    wire logic        power_last;

    wire logic vpp_result_valid;
    wire logic mean_square_result_valid;
    wire logic writer_start;
    wire logic measurement_busy;
    wire logic measurement_vpp_done;
    wire logic measurement_mean_square_done;
    wire logic measurement_wave_done;
    wire logic measurement_writer_error;

    wire logic spectrol_start;
    wire logic spectrol_busy;
    wire logic spectrum_write_done;
    wire logic spectrol_base_start;
    wire logic spectrol_protocol_error;

    wire logic base_busy;
    wire logic base_done;
    wire logic base_mem_req;
    wire logic [10:0] base_mem_addr;
    wire logic energy_busy;
    wire logic energy_mem_req;
    wire logic [10:0] energy_mem_addr;
    wire logic shared_mem_req;
    wire logic [10:0] shared_mem_addr;
    wire logic shared_mem_ready;
    wire logic shared_mem_rvalid;
    wire logic [31:0] shared_mem_rdata;
    wire logic energy_access;

    wire logic fifo_write_error;
    wire logic fifo_read_error;
    wire logic fir_busy;
    wire logic fir_protocol_error;
    wire logic fir_saturation_error;
    wire logic vpp_busy;
    wire logic vpp_error;
    wire logic mean_square_overflow;
    wire logic decim_protocol_error;
    wire logic decim_overrun_error;
    wire logic hann_protocol_error;
    wire logic fft_config_done;
    wire logic fft_protocol_error;
    wire logic fft_channel_halt;
    wire logic fft_frame_done;
    wire logic power_frame_done;
    wire logic power_protocol_error;

    wire logic measurement_bram_en_unused;
    wire logic [3:0] measurement_bram_we_unused;
    wire logic [MEASUREMENT_BRAM_ADDR_WIDTH-1:0]
        measurement_bram_addr_unused;
    wire logic [31:0] measurement_bram_data_unused;

    typedef enum logic [1:0] {
        PIPE_WAIT_FIRST,
        PIPE_STREAM,
        PIPE_WAIT_WRITER
    } pipe_state_t;
    pipe_state_t pipe_state;

    initial begin
        assert (FRAME_SIZE == 65536)
            else $fatal(1, "adc-FFT-spectrol-loop requires FRAME_SIZE=65536");
        assert (MEASUREMENT_BRAM_ADDR_WIDTH >= 18)
            else $fatal(1, "measurement BRAM address width must be at least 18");
    end

    assign selected_adc_sample =
        adc_channel_select ? adc_sample_b : adc_sample_a;

    // The FIFO holds its first word until both the FIR and frame controller are
    // ready.  This same accepted frame-start event opens the result writer and
    // spectrol write window before any FFT result can arrive.
    assign writer_start = (pipe_state == PIPE_WAIT_FIRST) &&
                          fifo_fir_valid && fifo_fir_first &&
                          fir_input_ready;
    assign spectrol_start = writer_start;
    assign fifo_fir_ready = (pipe_state == PIPE_STREAM) && fir_input_ready;
    assign fir_input_valid = (pipe_state == PIPE_STREAM) && fifo_fir_valid;

    always_ff @(posedge processing_clk) begin
        if (processing_rst) begin
            pipe_state <= PIPE_WAIT_FIRST;
        end else begin
            unique case (pipe_state)
                PIPE_WAIT_FIRST: begin
                    if (writer_start)
                        pipe_state <= PIPE_STREAM;
                end
                PIPE_STREAM: begin
                    if (wave_stream_valid && wave_stream_last)
                        pipe_state <= PIPE_WAIT_WRITER;
                end
                PIPE_WAIT_WRITER: begin
                    if (measurement_frame_done)
                        pipe_state <= PIPE_WAIT_FIRST;
                end
                default: pipe_state <= PIPE_WAIT_FIRST;
            endcase
        end
    end

    // spectrol has one request/response read service.  Keep it in its
    // WAIT_BASE phase until energy_done, and switch the client after base_done.
    assign energy_access = energy_busy || base_done;
    assign shared_mem_req = energy_access ? energy_mem_req : base_mem_req;
    assign shared_mem_addr = energy_access ? energy_mem_addr : base_mem_addr;
    assign fft_channel_halt_status = fft_channel_halt;

    // channel_halt is exported separately.  In the configured Non-Realtime
    // FFT it is a backpressure diagnostic, not a frame/protocol failure.
    assign pipeline_error =
        fifo_write_error | fifo_read_error |
        fir_protocol_error | fir_saturation_error |
        vpp_error | mean_square_overflow | measurement_writer_error |
        decim_protocol_error | decim_overrun_error | hann_protocol_error |
        fft_protocol_error | power_protocol_error |
        spectrol_protocol_error;

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
        .wave_first(wave_stream_first), .wave_last(wave_stream_last),
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
        .vpp_busy(vpp_busy), .vpp_error(vpp_error)
    );

    mean_square_calculator u_mean_square_calculator (
        .clk(processing_clk), .rst(processing_rst),
        .sample_in(mean_square_stream_data),
        .sample_valid(mean_square_stream_valid),
        .sample_first(mean_square_stream_first),
        .sample_last(mean_square_stream_last),
        .mean_square_out(mean_square_result),
        .result_valid(mean_square_result_valid),
        .overflow(mean_square_overflow)
    );

    measurement_bram_writer #(
        .WAVE_SAMPLE_COUNT(FRAME_SIZE),
        .BRAM_ADDR_WIDTH(MEASUREMENT_BRAM_ADDR_WIDTH)
    ) u_measurement_bram_writer (
        .clk(processing_clk), .rst(processing_rst), .start(writer_start),
        .channel_enable(3'b111),
        .vpp_data(vpp_result), .vpp_valid(vpp_result_valid),
        .vrms_data(mean_square_result),
        .vrms_valid(mean_square_result_valid),
        .wave_data(wave_stream_data), .wave_valid(wave_stream_valid),
        .busy(measurement_busy), .frame_done(measurement_frame_done),
        .vpp_done(measurement_vpp_done),
        .vrms_done(measurement_mean_square_done),
        .wave_done(measurement_wave_done), .error(measurement_writer_error),
        .bram_en(measurement_bram_en_unused),
        .bram_we(measurement_bram_we_unused),
        .bram_addr(measurement_bram_addr_unused),
        .bram_wrdata(measurement_bram_data_unused)
    );

    downsampler_16 u_downsampler_16 (
        .clk(processing_clk), .rst(processing_rst), .clear_error(clear_error),
        .fir_data(spectrum_stream_data), .fir_valid(spectrum_stream_valid),
        .fir_first(spectrum_stream_first), .fir_last(spectrum_stream_last),
        .decim_data(decim_data), .decim_valid(decim_valid),
        .decim_ready(decim_ready), .decim_first(decim_first),
        .decim_last(decim_last), .busy(decim_busy),
        .input_frame_done(decim_input_frame_done),
        .decim_frame_done(decim_frame_done),
        .frame_valid(frequency_frame_valid),
        .protocol_error(decim_protocol_error),
        .overrun_error(decim_overrun_error)
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

    fft_4096_wrapper u_fft_4096_wrapper (
        .clk(processing_clk), .rst(processing_rst), .clear_error(clear_error),
        .window_data(window_data), .window_valid(window_valid),
        .window_ready(window_ready), .window_first(window_first),
        .window_last(window_last), .fft_re(fft_re), .fft_im(fft_im),
        .fft_bin(fft_bin), .fft_valid(fft_valid), .fft_ready(fft_ready),
        .fft_first(fft_first), .fft_last(fft_last),
        .config_done(fft_config_done), .protocol_error(fft_protocol_error),
        .channel_halt(fft_channel_halt)
    );

    power_spectrum_calculator u_power_spectrum_calculator (
        .clk(processing_clk), .rst(processing_rst), .clear_error(clear_error),
        .fft_re(fft_re), .fft_im(fft_im), .fft_bin(fft_bin),
        .fft_valid(fft_valid), .fft_ready(fft_ready),
        .fft_first(fft_first), .fft_last(fft_last),
        .power_data(power_data), .power_bin(power_bin),
        .power_valid(power_valid), .power_ready(power_ready),
        .power_first(power_first), .power_last(power_last),
        .fft_frame_done(fft_frame_done),
        .power_frame_done(power_frame_done),
        .protocol_error(power_protocol_error)
    );

    spectrol #(
        .POWER_WIDTH(32),
        .BRAM_RD_LATENCY(SPECTRUM_BRAM_RD_LATENCY)
    ) u_spectrol (
        .clk(processing_clk), .rst(processing_rst), .clear_error(clear_error),
        .start(spectrol_start), .busy(spectrol_busy),
        .spectrum_write_done(spectrum_write_done),
        .frame_done(spectrum_frame_done),
        .protocol_error(spectrol_protocol_error),
        .power_data(power_data), .power_bin(power_bin),
        .power_valid(power_valid), .power_ready(power_ready),
        .power_first(power_first), .power_last(power_last),
        .base_start(spectrol_base_start),
        .base_done(energy_done), .base_valid(base_valid),
        .base_mem_req(shared_mem_req), .base_mem_addr(shared_mem_addr),
        .base_mem_ready(shared_mem_ready),
        .base_mem_rvalid(shared_mem_rvalid),
        .base_mem_rdata(shared_mem_rdata),
        .spectrum_bram_en(spectrum_bram_en),
        .spectrum_bram_we(spectrum_bram_we),
        .spectrum_bram_addr(spectrum_bram_addr),
        .spectrum_bram_din(spectrum_bram_din),
        .spectrum_bram_dout(spectrum_bram_dout)
    );

    base_detector u_base_detector (
        .clk(processing_clk), .rst(processing_rst),
        .start(spectrol_base_start),
        .detect_threshold(BASE_DETECT_THRESHOLD),
        .prominence_threshold(BASE_PROMINENCE_THRESHOLD),
        .busy(base_busy), .mem_req(base_mem_req), .mem_addr(base_mem_addr),
        .mem_ready(shared_mem_ready && !energy_access),
        .mem_rvalid(shared_mem_rvalid && !energy_access),
        .mem_rdata(shared_mem_rdata), .base_valid(base_valid),
        .base_done(base_done), .base_index_500(base_index_500),
        .base_bin(base_bin), .base_energy(base_energy)
    );

    energy_calculator u_energy_calculator (
        .clk(processing_clk), .rst(processing_rst), .start(base_done),
        .busy(energy_busy), .done(energy_done), .base_valid(base_valid),
        .base_index_500(base_index_500),
        .absolute_threshold(ENERGY_ABSOLUTE_THRESHOLD),
        .ratio_num(ENERGY_RATIO_NUM), .ratio_den(ENERGY_RATIO_DEN),
        .mem_req(energy_mem_req), .mem_addr(energy_mem_addr),
        .mem_ready(shared_mem_ready && energy_access),
        .mem_rvalid(shared_mem_rvalid && energy_access),
        .mem_rdata(shared_mem_rdata),
        .result_bram_en(energy_result_en),
        .result_bram_we(energy_result_we),
        .result_bram_addr(energy_result_addr),
        .result_bram_din(energy_result_data),
        .harmonic_present_mask(harmonic_present_mask),
        .position_valid_mask(position_valid_mask),
        .result_valid(energy_result_valid),
        .energy_overflow(energy_overflow)
    );

endmodule

`default_nettype wire
