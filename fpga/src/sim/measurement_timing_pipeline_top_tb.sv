`timescale 1ns/1ps
`default_nettype none

module measurement_timing_pipeline_top_tb;
    localparam int FRAME_SIZE = 65536;
    localparam int BRAM_ADDR_WIDTH = 18;

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
    wire capture_busy;
    wire frame_pending;
    wire fifo_ready;
    wire fifo_write_error;
    wire fifo_read_error;
    wire fir_busy;
    wire fir_protocol_error;
    wire fir_saturation_error;
    wire measurement_busy;
    wire measurement_frame_done;
    wire measurement_vpp_done;
    wire measurement_mean_square_done;
    wire measurement_wave_done;
    wire measurement_error;
    wire bram_en;
    wire [3:0] bram_we;
    wire [BRAM_ADDR_WIDTH-1:0] bram_addr;
    wire [31:0] bram_wrdata;

    logic [9:0] adc_memory [0:FRAME_SIZE-1];
    logic [31:0] bram_model [0:(FRAME_SIZE/2)+1];
    integer adc_drive_index = 0;
    integer write_count = 0;
    integer csv_file;
    integer summary_file;
    string adc_mem_path;
    string csv_output_path;
    string summary_output_path;

    measurement_timing_pipeline_top dut (
        .adc_clk(adc_clk),
        .adc_clk_drive(adc_clk),
        .processing_clk(processing_clk),
        .adc_rst(adc_rst),
        .processing_rst(processing_rst),
        .fifo_rst(fifo_rst),
        .capture_start(capture_start),
        .clear_error(clear_error),
        .adc_channel_select(adc_channel_select),
        .adc_data_a(adc_data_a),
        .adc_data_b(adc_data_b),
        .adc_clk_a(adc_clk_a),
        .adc_clk_b(adc_clk_b),
        .adc_oe_a(adc_oe_a),
        .adc_oe_b(adc_oe_b),
        .capture_busy(capture_busy),
        .frame_pending(frame_pending),
        .fifo_ready(fifo_ready),
        .fifo_write_error(fifo_write_error),
        .fifo_read_error(fifo_read_error),
        .fir_busy(fir_busy),
        .fir_protocol_error(fir_protocol_error),
        .fir_saturation_error(fir_saturation_error),
        .measurement_busy(measurement_busy),
        .measurement_frame_done(measurement_frame_done),
        .measurement_vpp_done(measurement_vpp_done),
        .measurement_mean_square_done(measurement_mean_square_done),
        .measurement_wave_done(measurement_wave_done),
        .measurement_error(measurement_error),
        .bram_en(bram_en),
        .bram_we(bram_we),
        .bram_addr(bram_addr),
        .bram_wrdata(bram_wrdata)
    );

    // The ADC model deliberately gives half a 32 MHz period of setup time.
    // Board-level ADC timing is checked by STA, not by this digital source.
    always @(negedge adc_clk) begin
        if (adc_rst) begin
            adc_drive_index = 0;
            adc_data_a = adc_memory[0];
        end else if (capture_busy && adc_drive_index < FRAME_SIZE-1) begin
            adc_drive_index = adc_drive_index + 1;
            adc_data_a = adc_memory[adc_drive_index];
        end
    end

    // Capture every transaction presented to the exported BRAM write port.
    always @(posedge processing_clk) begin
        if (!processing_rst && bram_en) begin
            bram_model[bram_addr >> 2] <= bram_wrdata;
            write_count <= write_count + 1;
            $fdisplay(csv_file,
                "%0t,%0d,0x%05h,%b,%b,0x%08h,%b,%b,%b,%b,%b",
                $time, write_count, bram_addr, bram_en, bram_we, bram_wrdata,
                measurement_busy, measurement_vpp_done,
                measurement_mean_square_done, measurement_wave_done,
                measurement_error);
        end
    end

    initial begin
        if (!$value$plusargs("ADC_MEM=%s", adc_mem_path)) begin
            adc_mem_path = "../src/sim/simdata/adc_input_u10.mem";
        end
        if (!$value$plusargs("CSV_OUT=%s", csv_output_path)) begin
            csv_output_path = "../sim_results/measurement_timing_bram_writes.csv";
        end
        if (!$value$plusargs("SUMMARY_OUT=%s", summary_output_path)) begin
            summary_output_path = "../sim_results/measurement_timing_summary.txt";
        end

        $readmemh(adc_mem_path, adc_memory);
        csv_file = $fopen(csv_output_path, "w");
        if (csv_file == 0) $fatal(1, "Cannot open CSV output: %s", csv_output_path);
        $fdisplay(csv_file,
            "time_ps,write_index,bram_addr,bram_en,bram_we,bram_wrdata,writer_busy,vpp_done,mean_square_done,wave_done,error");

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

        wait (measurement_frame_done === 1'b1);
        #1;

        summary_file = $fopen(summary_output_path, "w");
        if (summary_file == 0) $fatal(1, "Cannot open summary output: %s", summary_output_path);
        $fdisplay(summary_file, "vpp=%0d (0x%08h)", bram_model[0], bram_model[0]);
        $fdisplay(summary_file, "mean_square=%0d (0x%08h)", bram_model[1], bram_model[1]);
        $fdisplay(summary_file, "bram_vpp=0x%08h", bram_model[0]);
        $fdisplay(summary_file, "bram_mean_square=0x%08h", bram_model[1]);
        $fdisplay(summary_file, "bram_write_count=%0d", write_count);
        $fdisplay(summary_file, "first_wave_word=0x%08h", bram_model[2]);
        $fdisplay(summary_file, "last_wave_word=0x%08h", bram_model[(FRAME_SIZE/2)+1]);
        $fdisplay(summary_file, "fifo_write_error=%b", fifo_write_error);
        $fdisplay(summary_file, "fifo_read_error=%b", fifo_read_error);
        $fdisplay(summary_file, "fir_protocol_error=%b", fir_protocol_error);
        $fdisplay(summary_file, "fir_saturation_error=%b", fir_saturation_error);
        $fdisplay(summary_file, "measurement_error=%b", measurement_error);
        $fclose(summary_file);
        $fclose(csv_file);

        if (fifo_write_error || fifo_read_error || fir_protocol_error ||
            fir_saturation_error || measurement_error) begin
            $fatal(1, "Pipeline error: fifo_wr=%b fifo_rd=%b fir_proto=%b fir_sat=%b measurement=%b",
                   fifo_write_error, fifo_read_error, fir_protocol_error,
                   fir_saturation_error, measurement_error);
        end
        if (write_count != (FRAME_SIZE/2)+2) begin
            $fatal(1, "BRAM write count=%0d expected=%0d",
                   write_count, (FRAME_SIZE/2)+2);
        end
        $display("TEST PASSED: vpp=%0d mean_square=%0d writes=%0d",
                 bram_model[0], bram_model[1], write_count);
        $finish;
    end

    initial begin
        #12000000;
        $fatal(1, "measurement timing pipeline simulation timeout");
    end
endmodule

`default_nettype wire
