`timescale 1ns/1ps
`default_nettype none

module adc_fft_spectrol_loop_tb;
    localparam int FRAME_SIZE = 65536;

    logic adc_clk = 1'b0;
    logic processing_clk = 1'b0;
    always #15.625 adc_clk = ~adc_clk;
    always #5.000 processing_clk = ~processing_clk;

    logic adc_rst = 1'b1;
    logic processing_rst = 1'b1;
    logic fifo_rst = 1'b1;
    logic capture_start = 1'b0;
    logic clear_error = 1'b0;
    logic adc_channel_select = 1'b0;
    logic [9:0] adc_data_a = 10'd512;
    logic [9:0] adc_data_b = 10'd512;

    wire adc_clk_a;
    wire adc_clk_b;
    wire adc_oe_a;
    wire adc_oe_b;
    wire spectrum_bram_en;
    wire spectrum_bram_we;
    wire [10:0] spectrum_bram_addr;
    wire [31:0] spectrum_bram_din;
    logic [31:0] spectrum_bram_dout = 32'd0;
    wire energy_result_en;
    wire energy_result_we;
    wire [3:0] energy_result_addr;
    wire [31:0] energy_result_data;
    wire energy_result_valid;
    wire energy_done;
    wire [2:0] harmonic_present_mask;
    wire [2:0] position_valid_mask;
    wire energy_overflow;
    wire base_valid;
    wire [15:0] base_index_500;
    wire [10:0] base_bin;
    wire [34:0] base_energy;
    wire [31:0] vpp_result;
    wire [31:0] mean_square_result;
    wire measurement_frame_done;
    wire spectrum_frame_done;
    wire capture_busy;
    wire frame_pending;
    wire fifo_ready;
    wire fft_channel_halt_status;
    wire pipeline_error;

    logic [9:0] adc_memory [0:FRAME_SIZE-1];
    logic [31:0] spectrum_memory [0:2047];
    logic [31:0] result_memory [0:15];
    logic read_valid_d1 = 1'b0;
    logic [10:0] read_addr_d1 = 11'd0;

    integer adc_drive_index = 0;
    integer spectrum_write_count = 0;
    integer spectrum_read_count = 0;
    integer energy_write_count = 0;
    integer cycle_count = 0;
    integer index;
    integer energy_file;
    integer spectrum_file;
    integer summary_file;
    string adc_mem_path;
    string energy_output_path;
    string spectrum_output_path;
    string summary_output_path;

    \adc-FFT-spectrol-loop #(
        .BASE_DETECT_THRESHOLD(35'd500),
        .BASE_PROMINENCE_THRESHOLD(35'd0),
        .ENERGY_ABSOLUTE_THRESHOLD(32'd0),
        .ENERGY_RATIO_NUM(16'd1),
        .ENERGY_RATIO_DEN(16'd100)
    ) dut (
        .adc_clk(adc_clk), .adc_clk_drive(adc_clk),
        .processing_clk(processing_clk), .adc_rst(adc_rst),
        .processing_rst(processing_rst), .fifo_rst(fifo_rst),
        .capture_start(capture_start), .clear_error(clear_error),
        .adc_channel_select(adc_channel_select),
        .adc_data_a(adc_data_a), .adc_data_b(adc_data_b),
        .adc_clk_a(adc_clk_a), .adc_clk_b(adc_clk_b),
        .adc_oe_a(adc_oe_a), .adc_oe_b(adc_oe_b),
        .spectrum_bram_en(spectrum_bram_en),
        .spectrum_bram_we(spectrum_bram_we),
        .spectrum_bram_addr(spectrum_bram_addr),
        .spectrum_bram_din(spectrum_bram_din),
        .spectrum_bram_dout(spectrum_bram_dout),
        .energy_result_en(energy_result_en),
        .energy_result_we(energy_result_we),
        .energy_result_addr(energy_result_addr),
        .energy_result_data(energy_result_data),
        .energy_result_valid(energy_result_valid),
        .energy_done(energy_done),
        .harmonic_present_mask(harmonic_present_mask),
        .position_valid_mask(position_valid_mask),
        .energy_overflow(energy_overflow),
        .base_valid(base_valid), .base_index_500(base_index_500),
        .base_bin(base_bin), .base_energy(base_energy),
        .vpp_result(vpp_result),
        .mean_square_result(mean_square_result),
        .measurement_frame_done(measurement_frame_done),
        .spectrum_frame_done(spectrum_frame_done),
        .capture_busy(capture_busy), .frame_pending(frame_pending),
        .fifo_ready(fifo_ready),
        .fft_channel_halt_status(fft_channel_halt_status),
        .pipeline_error(pipeline_error)
    );

    // Present the next ADC code before its rising-edge capture.
    always @(negedge adc_clk) begin
        if (adc_rst) begin
            adc_drive_index = 0;
            adc_data_a = adc_memory[0];
        end else if (capture_busy && adc_drive_index < FRAME_SIZE-1) begin
            adc_drive_index = adc_drive_index + 1;
            adc_data_a = adc_memory[adc_drive_index];
        end
    end

    // Two-cycle synchronous BRAM model matching spectrol's configured latency.
    always_ff @(posedge processing_clk) begin
        if (processing_rst) begin
            spectrum_bram_dout <= 32'd0;
            read_valid_d1 <= 1'b0;
            read_addr_d1 <= 11'd0;
            spectrum_write_count <= 0;
            spectrum_read_count <= 0;
            energy_write_count <= 0;
            cycle_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            read_valid_d1 <= spectrum_bram_en && !spectrum_bram_we;

            if (spectrum_bram_en && spectrum_bram_we) begin
                spectrum_memory[spectrum_bram_addr] <= spectrum_bram_din;
                spectrum_write_count <= spectrum_write_count + 1;
                $fdisplay(spectrum_file, "%0d,%0d,%08x,%0d",
                          cycle_count, spectrum_bram_addr,
                          spectrum_bram_din, spectrum_bram_din);
            end

            if (spectrum_bram_en && !spectrum_bram_we) begin
                read_addr_d1 <= spectrum_bram_addr;
                spectrum_read_count <= spectrum_read_count + 1;
            end

            if (read_valid_d1)
                spectrum_bram_dout <= spectrum_memory[read_addr_d1];

            if (energy_result_en && energy_result_we) begin
                result_memory[energy_result_addr] <= energy_result_data;
                energy_write_count <= energy_write_count + 1;
                $fdisplay(energy_file, "%0d,%0t,%0d,%08x,%0d",
                          cycle_count, $time, energy_result_addr,
                          energy_result_data, energy_result_data);
            end
        end
    end

    initial begin
        if (!$value$plusargs("ADC_MEM=%s", adc_mem_path))
            adc_mem_path = "../src/sim/simdata/adc_input_u10.mem";
        if (!$value$plusargs("ENERGY_OUT=%s", energy_output_path))
            energy_output_path =
                "../sim_results/adc_fft_spectrol_loop_energy_writes.csv";
        if (!$value$plusargs("SPECTRUM_OUT=%s", spectrum_output_path))
            spectrum_output_path =
                "../sim_results/adc_fft_spectrol_loop_spectrum.csv";
        if (!$value$plusargs("SUMMARY_OUT=%s", summary_output_path))
            summary_output_path =
                "../sim_results/adc_fft_spectrol_loop_summary.txt";

        $readmemh(adc_mem_path, adc_memory);
        energy_file = $fopen(energy_output_path, "w");
        spectrum_file = $fopen(spectrum_output_path, "w");
        if (!energy_file || !spectrum_file)
            $fatal(1, "Cannot open simulation result files");
        $fdisplay(energy_file,
                  "cycle,time_ns,address,data_hex,data_unsigned");
        $fdisplay(spectrum_file,
                  "cycle,bin,power_hex,power_unsigned");

        for (index = 0; index < 2048; index = index + 1)
            spectrum_memory[index] = 32'd0;
        for (index = 0; index < 16; index = index + 1)
            result_memory[index] = 32'hA5A5_A5A5;

        adc_data_a = adc_memory[0];
        repeat (10) @(posedge adc_clk);
        fifo_rst = 1'b0;
        repeat (4) @(posedge adc_clk);
        @(negedge adc_clk) adc_rst = 1'b0;
        @(negedge processing_clk) processing_rst = 1'b0;

        wait (fifo_ready);
        repeat (8) @(posedge adc_clk);
        @(negedge adc_clk) capture_start = 1'b1;
        @(negedge adc_clk) capture_start = 1'b0;

        wait (energy_done);
        @(posedge processing_clk);
        #1;

        $display(
            "DIAGNOSTICS fw=%0b fr=%0b firp=%0b firs=%0b vpp=%0b ms=%0b mw=%0b decp=%0b deco=%0b hann=%0b fftp=%0b ffth=%0b power=%0b spectrol=%0b",
            dut.fifo_write_error, dut.fifo_read_error,
            dut.fir_protocol_error, dut.fir_saturation_error,
            dut.vpp_error, dut.mean_square_overflow,
            dut.measurement_writer_error, dut.decim_protocol_error,
            dut.decim_overrun_error, dut.hann_protocol_error,
            dut.fft_protocol_error, dut.fft_channel_halt,
            dut.power_protocol_error, dut.spectrol_protocol_error);

        if (!energy_result_valid)
            $fatal(1, "energy_result_valid was not asserted");
        if (!base_valid)
            $fatal(1, "base detector did not find a valid base frequency");
        if (pipeline_error)
            $fatal(1, "pipeline_error asserted");
        if (spectrum_write_count != 2048)
            $fatal(1, "spectrum write count=%0d", spectrum_write_count);
        if (energy_write_count != 17)
            $fatal(1, "energy write count=%0d", energy_write_count);

        summary_file = $fopen(summary_output_path, "w");
        if (!summary_file)
            $fatal(1, "Cannot open simulation summary");
        $fdisplay(summary_file, "base_valid=%0d", base_valid);
        $fdisplay(summary_file, "base_index_500=%0d", base_index_500);
        $fdisplay(summary_file, "base_bin=%0d", base_bin);
        $fdisplay(summary_file, "base_energy_raw35=%0d", base_energy);
        $fdisplay(summary_file, "harmonic_present_mask=%03b",
                  harmonic_present_mask);
        $fdisplay(summary_file, "position_valid_mask=%03b",
                  position_valid_mask);
        $fdisplay(summary_file, "energy_overflow=%0d", energy_overflow);
        $fdisplay(summary_file, "vpp=%0d", vpp_result);
        $fdisplay(summary_file, "mean_square=%0d", mean_square_result);
        $fdisplay(summary_file, "spectrum_write_count=%0d",
                  spectrum_write_count);
        $fdisplay(summary_file, "spectrum_read_count=%0d",
                  spectrum_read_count);
        $fdisplay(summary_file, "energy_write_count=%0d",
                  energy_write_count);
        $fdisplay(summary_file, "pipeline_error=%0d", pipeline_error);
        for (index = 0; index < 16; index = index + 1)
            $fdisplay(summary_file, "W%0d=0x%08x (%0d)",
                      index, result_memory[index], result_memory[index]);
        $fclose(summary_file);
        $fclose(energy_file);
        $fclose(spectrum_file);

        $display(
            "TEST PASSED: base_index_500=%0d base_bin=%0d W2=%0d W4=%0d W6=%0d",
            base_index_500, base_bin, result_memory[2],
            result_memory[4], result_memory[6]);
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "adc_fft_spectrol_loop simulation timeout");
    end

endmodule

`default_nettype wire
