`timescale 1ns/1ps
`default_nettype none

module measurement_window_pipeline_top_tb;
    localparam int FRAME_SIZE = 65536;

    logic adc_clk = 1'b0;
    logic processing_clk = 1'b0;
    always #15.625 adc_clk = ~adc_clk;       // 32 MHz ADC domain
    always #5.000 processing_clk = ~processing_clk; // 100 MHz processing

    logic adc_rst = 1'b1;
    logic processing_rst = 1'b1;
    logic fifo_rst = 1'b1;
    logic capture_start = 1'b0;
    logic clear_error = 1'b0;
    logic adc_channel_select = 1'b0;
    logic [9:0] adc_data_a = 10'd512;
    logic [9:0] adc_data_b = 10'd512;
    logic window_ready = 1'b1;

    wire adc_clk_a, adc_clk_b, adc_oe_a, adc_oe_b;
    wire signed [15:0] window_data;
    wire window_valid, window_first, window_last;
    wire [31:0] vpp_result, mean_square_result;
    wire vpp_result_valid, mean_square_result_valid;
    wire capture_busy, frame_pending, fifo_ready;
    wire measurement_frame_done, frequency_frame_valid, pipeline_error;

    logic [9:0] adc_memory [0:FRAME_SIZE-1];
    integer adc_drive_index = 0;
    integer fir_count = 0;
    integer decim_count = 0;
    integer window_count = 0;
    integer fir_file, decim_file, window_file, summary_file;
    logic measurement_done_seen = 1'b0;
    logic frequency_valid_seen = 1'b0;
    logic window_done_seen = 1'b0;
    string adc_mem_path;
    string fir_output_path;
    string decim_output_path;
    string window_output_path;
    string summary_output_path;

    measurement_window_pipeline_top dut (
        .adc_clk(adc_clk), .adc_clk_drive(adc_clk),
        .processing_clk(processing_clk), .adc_rst(adc_rst),
        .processing_rst(processing_rst), .fifo_rst(fifo_rst),
        .capture_start(capture_start), .clear_error(clear_error),
        .adc_channel_select(adc_channel_select),
        .adc_data_a(adc_data_a), .adc_data_b(adc_data_b),
        .adc_clk_a(adc_clk_a), .adc_clk_b(adc_clk_b),
        .adc_oe_a(adc_oe_a), .adc_oe_b(adc_oe_b),
        .window_data(window_data), .window_valid(window_valid),
        .window_ready(window_ready), .window_first(window_first),
        .window_last(window_last), .vpp_result(vpp_result),
        .mean_square_result(mean_square_result),
        .vpp_result_valid(vpp_result_valid),
        .mean_square_result_valid(mean_square_result_valid),
        .capture_busy(capture_busy), .frame_pending(frame_pending),
        .fifo_ready(fifo_ready),
        .measurement_frame_done(measurement_frame_done),
        .frequency_frame_valid(frequency_frame_valid),
        .pipeline_error(pipeline_error)
    );

    // Present each ADC code half a source-clock period before capture.
    always @(negedge adc_clk) begin
        if (adc_rst) begin
            adc_drive_index = 0;
            adc_data_a = adc_memory[0];
        end else if (capture_busy && adc_drive_index < FRAME_SIZE-1) begin
            adc_drive_index = adc_drive_index + 1;
            adc_data_a = adc_memory[adc_drive_index];
        end
    end

    always @(posedge processing_clk) begin
        if (!processing_rst) begin
            if (dut.filtered_valid) begin
                $fdisplay(fir_file, "%0d,%0d,%0d,%0d", fir_count,
                          $signed(dut.filtered_data), dut.filtered_first,
                          dut.filtered_last);
                fir_count <= fir_count + 1;
            end

            if (dut.decim_valid && dut.decim_ready) begin
                $fdisplay(decim_file, "%0d,%0d,%0d,%0d", decim_count,
                          $signed(dut.decim_data), dut.decim_first,
                          dut.decim_last);
                if ((decim_count == 0) != dut.decim_first)
                    $fatal(1, "Downsample first marker mismatch at %0d", decim_count);
                if ((decim_count == 4095) != dut.decim_last)
                    $fatal(1, "Downsample last marker mismatch at %0d", decim_count);
                decim_count <= decim_count + 1;
            end

            if (window_valid && window_ready) begin
                $fdisplay(window_file, "%0d,%0d,%0d,%0d", window_count,
                          $signed(window_data), window_first, window_last);
                if ((window_count == 0) != window_first)
                    $fatal(1, "Window first marker mismatch at %0d", window_count);
                if ((window_count == 4095) != window_last)
                    $fatal(1, "Window last marker mismatch at %0d", window_count);
                if (window_last) window_done_seen <= 1'b1;
                window_count <= window_count + 1;
            end

            if (measurement_frame_done) measurement_done_seen <= 1'b1;
            if (frequency_frame_valid) frequency_valid_seen <= 1'b1;
        end
    end

    initial begin
        if (!$value$plusargs("ADC_MEM=%s", adc_mem_path))
            adc_mem_path = "../src/sim/simdata/adc_input_u10.mem";
        if (!$value$plusargs("FIR_OUT=%s", fir_output_path))
            fir_output_path = "../sim_results/window_pipeline_fir.csv";
        if (!$value$plusargs("DECIM_OUT=%s", decim_output_path))
            decim_output_path = "../sim_results/window_pipeline_decim.csv";
        if (!$value$plusargs("WINDOW_OUT=%s", window_output_path))
            window_output_path = "../sim_results/window_pipeline_window.csv";
        if (!$value$plusargs("SUMMARY_OUT=%s", summary_output_path))
            summary_output_path = "../sim_results/window_pipeline_summary.txt";

        $readmemh(adc_mem_path, adc_memory);
        fir_file = $fopen(fir_output_path, "w");
        decim_file = $fopen(decim_output_path, "w");
        window_file = $fopen(window_output_path, "w");
        if (!fir_file || !decim_file || !window_file)
            $fatal(1, "Cannot open one or more pipeline CSV outputs");
        $fdisplay(fir_file, "index,data,first,last");
        $fdisplay(decim_file, "index,data,first,last");
        $fdisplay(window_file, "index,data,first,last");

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

        wait (measurement_done_seen && frequency_valid_seen && window_done_seen);
        @(posedge processing_clk);
        #1;

        if (pipeline_error) $fatal(1, "Pipeline error flag asserted");
        if (fir_count != 65536) $fatal(1, "FIR count=%0d", fir_count);
        if (decim_count != 4096) $fatal(1, "Downsample count=%0d", decim_count);
        if (window_count != 4096) $fatal(1, "Window count=%0d", window_count);

        summary_file = $fopen(summary_output_path, "w");
        if (!summary_file) $fatal(1, "Cannot open summary output");
        $fdisplay(summary_file, "fir_count=%0d", fir_count);
        $fdisplay(summary_file, "decim_count=%0d", decim_count);
        $fdisplay(summary_file, "window_count=%0d", window_count);
        $fdisplay(summary_file, "vpp=%0d", vpp_result);
        $fdisplay(summary_file, "mean_square=%0d", mean_square_result);
        $fdisplay(summary_file, "pipeline_error=%0d", pipeline_error);
        $fclose(summary_file);
        $fclose(fir_file);
        $fclose(decim_file);
        $fclose(window_file);

        $display("TEST PASSED: FIR=%0d DECIM=%0d WINDOW=%0d VPP=%0d MS=%0d",
                 fir_count, decim_count, window_count, vpp_result,
                 mean_square_result);
        $finish;
    end

    initial begin
        #12000000;
        $fatal(1, "measurement window pipeline simulation timeout");
    end
endmodule

`default_nettype wire
