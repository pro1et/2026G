`timescale 1ns/1ps
`default_nettype none

module measurement_pipeline_top_tb;
    localparam int FRAME_SIZE = 65536;
    localparam int BRAM_ADDR_WIDTH = 18;

    logic adc_clk = 1'b0;
    logic processing_clk = 1'b0;
    always #15.625 adc_clk = ~adc_clk;       // 32 MHz
    always #5.000 processing_clk = ~processing_clk; // 100 MHz

    logic adc_rst = 1'b1;
    logic processing_rst = 1'b1;
    logic fifo_rst = 1'b1;
    logic capture_start = 1'b0;
    logic clear_error = 1'b0;
    logic adc_channel_select = 1'b0;
    logic [9:0] adc_data_a = 10'd512;
    logic [9:0] adc_data_b = 10'd512;

    wire adc_clk_a, adc_clk_b, adc_oe_a, adc_oe_b;
    wire capture_busy, frame_pending, fifo_ready;
    wire fifo_write_error, fifo_read_error;
    wire [31:0] vpp_result, mean_square_result;
    wire vpp_result_valid, mean_square_result_valid;
    wire measurement_busy, measurement_frame_done;
    wire measurement_vpp_done, measurement_mean_square_done, measurement_wave_done;
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

    measurement_pipeline_top dut (
        .adc_clk(adc_clk), .adc_clk_drive(adc_clk),
        .processing_clk(processing_clk),
        .adc_rst(adc_rst), .processing_rst(processing_rst), .fifo_rst(fifo_rst),
        .capture_start(capture_start), .clear_error(clear_error),
        .adc_channel_select(adc_channel_select),
        .adc_data_a(adc_data_a), .adc_data_b(adc_data_b),
        .adc_clk_a(adc_clk_a), .adc_clk_b(adc_clk_b),
        .adc_oe_a(adc_oe_a), .adc_oe_b(adc_oe_b),
        .capture_busy(capture_busy), .frame_pending(frame_pending),
        .fifo_ready(fifo_ready), .fifo_write_error(fifo_write_error),
        .fifo_read_error(fifo_read_error),
        .vpp_result(vpp_result), .mean_square_result(mean_square_result),
        .vpp_result_valid(vpp_result_valid),
        .mean_square_result_valid(mean_square_result_valid),
        .measurement_busy(measurement_busy),
        .measurement_frame_done(measurement_frame_done),
        .measurement_vpp_done(measurement_vpp_done),
        .measurement_mean_square_done(measurement_mean_square_done),
        .measurement_wave_done(measurement_wave_done),
        .measurement_error(measurement_error),
        .bram_en(bram_en), .bram_we(bram_we),
        .bram_addr(bram_addr), .bram_wrdata(bram_wrdata)
    );

    // Present the next raw ADC code half a cycle before adc_capture samples it.
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
        if (!processing_rst && bram_en) begin
            assert (bram_we == 4'b1111) else $fatal(1, "Invalid BRAM WE");
            assert (bram_addr[1:0] == 2'b00) else $fatal(1, "Unaligned BRAM address");
            bram_model[bram_addr >> 2] <= bram_wrdata;
            write_count <= write_count + 1;
            $fdisplay(csv_file,
                "%0t,0x%05h,%b,%b,0x%08h,%0d,%b,0x%08h,%b,0x%08h,%b,%b,%b,%b",
                $time, bram_addr, bram_en, bram_we, bram_wrdata,
                $signed(dut.split_data), dut.split_valid,
                vpp_result, vpp_result_valid,
                mean_square_result, mean_square_result_valid,
                measurement_busy, measurement_vpp_done,
                measurement_mean_square_done);
        end
    end

    initial begin
        $readmemh("../src/sim/simdata/adc_input_u10.mem", adc_memory);
        csv_file = $fopen("../sim_results/measurement_pipeline_bram_writes.csv", "w");
        if (csv_file == 0) $fatal(1, "Cannot open CSV output");
        $fdisplay(csv_file,
            "time_ps,bram_addr,bram_en,bram_we,bram_wrdata,fir_data,fir_valid,vpp_data,vpp_valid,mean_square_data,mean_square_valid,writer_busy,vpp_done,mean_square_done");

        adc_data_a = adc_memory[0];
        repeat (10) @(posedge adc_clk);
        fifo_rst = 1'b0;
        repeat (4) @(posedge adc_clk);
        @(negedge adc_clk) adc_rst = 1'b0;
        @(negedge processing_clk) processing_rst = 1'b0;

        wait (fifo_ready && dut.adc_valid);
        repeat (2) @(posedge adc_clk);
        @(negedge adc_clk) capture_start = 1'b1;
        @(negedge adc_clk) capture_start = 1'b0;

        wait (measurement_frame_done);
        #1;
        assert (!fifo_write_error && !fifo_read_error && !measurement_error)
            else $fatal(1, "Pipeline error flags: wr=%b rd=%b writer=%b",
                        fifo_write_error, fifo_read_error, measurement_error);
        assert (measurement_vpp_done && measurement_mean_square_done && measurement_wave_done)
            else $fatal(1, "Not all measurement channels completed");
        assert (write_count == (FRAME_SIZE/2)+2)
            else $fatal(1, "BRAM write count=%0d expected=%0d", write_count, (FRAME_SIZE/2)+2);
        assert (bram_model[0] == vpp_result)
            else $fatal(1, "Vpp BRAM word mismatch");
        assert (bram_model[1] == mean_square_result)
            else $fatal(1, "Mean-square BRAM word mismatch");

        summary_file = $fopen("../sim_results/measurement_pipeline_summary.txt", "w");
        if (summary_file == 0) $fatal(1, "Cannot open summary output");
        $fdisplay(summary_file, "vpp=%0d (0x%08h)", vpp_result, vpp_result);
        $fdisplay(summary_file, "mean_square=%0d (0x%08h)", mean_square_result, mean_square_result);
        $fdisplay(summary_file, "bram_write_count=%0d", write_count);
        $fdisplay(summary_file, "first_wave_word=0x%08h", bram_model[2]);
        $fdisplay(summary_file, "last_wave_word=0x%08h", bram_model[(FRAME_SIZE/2)+1]);
        $fclose(summary_file);
        $fclose(csv_file);

        $display("TEST PASSED: vpp=%0d mean_square=%0d writes=%0d",
                 vpp_result, mean_square_result, write_count);
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "measurement pipeline simulation timeout");
    end
endmodule

// Simulation-only FWFT asynchronous FIFO model.  Synthesis uses the project's
// real fifo_generator_0 Xilinx IP through fifo_wrap.
module fifo_generator_0 (
    input wire rst, input wire wr_clk, input wire rd_clk,
    input wire [15:0] din, input wire wr_en, input wire rd_en,
    output wire [15:0] dout, output wire full, output wire empty,
    output wire wr_rst_busy, output wire rd_rst_busy
);
    logic [15:0] memory [0:65535];
    integer write_pointer = 0;
    integer read_pointer = 0;
    logic [1:0] write_reset_pipe = 2'b11;
    logic [1:0] read_reset_pipe = 2'b11;

    assign empty = (write_pointer == read_pointer);
    assign full = ((write_pointer - read_pointer) >= 65536);
    assign dout = empty ? 16'b0 : memory[read_pointer & 16'hffff];
    assign wr_rst_busy = |write_reset_pipe;
    assign rd_rst_busy = |read_reset_pipe;

    always @(posedge wr_clk or posedge rst) begin
        if (rst) begin
            write_pointer <= 0;
            write_reset_pipe <= 2'b11;
        end else begin
            write_reset_pipe <= {write_reset_pipe[0], 1'b0};
            if (wr_en && !full && !wr_rst_busy) begin
                memory[write_pointer & 16'hffff] <= din;
                write_pointer <= write_pointer + 1;
            end
        end
    end
    always @(posedge rd_clk or posedge rst) begin
        if (rst) begin
            read_pointer <= 0;
            read_reset_pipe <= 2'b11;
        end else begin
            read_reset_pipe <= {read_reset_pipe[0], 1'b0};
            if (rd_en && !empty && !rd_rst_busy) read_pointer <= read_pointer + 1;
        end
    end
endmodule

`default_nettype wire
