`timescale 1ns/1ps
`default_nettype none

// Copies the COE-initialized test images into the two BRAMs that are exposed
// to the Zynq PS through AXI BRAM Controllers.
//
// The source ROMs contain the final PS-visible 32-bit BRAM images.  Header
// fields occupy complete 32-bit words.  Only waveform and spectrum plot
// points are packed two 16-bit values per word.
//
// A one-cycle pulse on start begins a copy while the engine is idle.  start is
// ignored while busy.  done remains high after completion and is cleared by
// the next accepted start.  Both channels operate in parallel.
module hmi_bram_init_copy #(
    parameter integer STARTUP_CYCLES     = 16,
    parameter integer TIME_COPY_WORDS    = 16388,
    parameter integer SPECTRUM_COPY_WORDS = 520
) (
    input  wire         clk,
    input  wire         resetn,
    input  wire         start,

    output wire         copy_busy,
    output wire         copy_done,
    output wire         copy_error,
    output reg          time_copy_done,
    output reg          spectrum_copy_done,

    // COE source: blk_mem_gen_2, time_init_rom, 32768 x 32.
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_SRC CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME TIME_SRC, MASTER_TYPE OTHER, MEM_ECC NONE, MEM_SIZE 131072, MEM_WIDTH 32, READ_LATENCY 1" *)
    output wire         time_src_clk,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_SRC RST" *)
    output wire         time_src_rst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_SRC EN" *)
    output reg          time_src_en,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_SRC ADDR" *)
    output reg   [14:0] time_src_addr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_SRC DOUT" *)
    input  wire  [31:0] time_src_dout,

    // COE source: blk_mem_gen_3, spectrum_init_rom, 1024 x 32.
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 SPECTRUM_SRC CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME SPECTRUM_SRC, MASTER_TYPE OTHER, MEM_ECC NONE, MEM_SIZE 4096, MEM_WIDTH 32, READ_LATENCY 1" *)
    output wire         spectrum_src_clk,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 SPECTRUM_SRC RST" *)
    output wire         spectrum_src_rst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 SPECTRUM_SRC EN" *)
    output reg          spectrum_src_en,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 SPECTRUM_SRC ADDR" *)
    output reg   [9:0]  spectrum_src_addr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 SPECTRUM_SRC DOUT" *)
    input  wire  [31:0] spectrum_src_dout,

    // AXI-visible destination: blk_mem_gen_0 Port B, 128 KiB byte address.
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_DST CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME TIME_DST, MASTER_TYPE BRAM_CTRL, MEM_ECC NONE, MEM_SIZE 131072, MEM_WIDTH 32, READ_LATENCY 1" *)
    output wire         time_dst_clk,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_DST RST" *)
    output wire         time_dst_rst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_DST EN" *)
    output reg          time_dst_en,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_DST WE" *)
    output reg   [3:0]  time_dst_we,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_DST ADDR" *)
    output reg   [16:0] time_dst_addr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_DST DIN" *)
    output reg   [31:0] time_dst_din,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_DST DOUT" *)
    input  wire  [31:0] time_dst_dout,

    // AXI-visible destination: blk_mem_gen_1 Port B, 8 KiB byte address.
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 SPECTRUM_DST CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME SPECTRUM_DST, MASTER_TYPE BRAM_CTRL, MEM_ECC NONE, MEM_SIZE 8192, MEM_WIDTH 32, READ_LATENCY 1" *)
    output wire         spectrum_dst_clk,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 SPECTRUM_DST RST" *)
    output wire         spectrum_dst_rst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 SPECTRUM_DST EN" *)
    output reg          spectrum_dst_en,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 SPECTRUM_DST WE" *)
    output reg   [3:0]  spectrum_dst_we,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 SPECTRUM_DST ADDR" *)
    output reg   [12:0] spectrum_dst_addr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 SPECTRUM_DST DIN" *)
    output reg   [31:0] spectrum_dst_din,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 SPECTRUM_DST DOUT" *)
    input  wire  [31:0] spectrum_dst_dout
);

    localparam [1:0] COPY_READ  = 2'd0;
    localparam [1:0] COPY_WAIT  = 2'd1;
    localparam [1:0] COPY_WRITE = 2'd2;
    localparam [1:0] COPY_DONE  = 2'd3;

    reg [15:0] startup_count;
    reg        startup_done;
    reg        run_active;
    reg        copy_done_reg;

    reg [1:0]  time_state;
    reg [14:0] time_word_index;

    reg [1:0] spectrum_state;
    reg [9:0] spectrum_word_index;

    // All four memories use the same FCLK_CLK0 clock.
    assign time_src_clk     = clk;
    assign spectrum_src_clk = clk;
    assign time_dst_clk     = clk;
    assign spectrum_dst_clk = clk;

    // Block Memory Generator BRAM resets are active high.
    assign time_src_rst     = ~resetn;
    assign spectrum_src_rst = ~resetn;
    assign time_dst_rst     = ~resetn;
    assign spectrum_dst_rst = ~resetn;

    wire start_accept;
    assign start_accept = startup_done && start && !run_active;

    assign copy_busy  = run_active;
    assign copy_done  = copy_done_reg;
    assign copy_error = 1'b0;

    // The destination read data is intentionally unused during initialization.
    wire unused_dst_dout;
    assign unused_dst_dout = ^time_dst_dout ^ ^spectrum_dst_dout;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            startup_count <= 16'd0;
            startup_done  <= 1'b0;
        end else if (!startup_done) begin
            if (STARTUP_CYCLES <= 1) begin
                startup_done <= 1'b1;
            end else if (startup_count == STARTUP_CYCLES - 1) begin
                startup_done <= 1'b1;
            end else begin
                startup_count <= startup_count + 1'b1;
            end
        end
    end

    // Global command/status controller. done is sticky until the next
    // accepted start command.
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            run_active   <= 1'b0;
            copy_done_reg <= 1'b0;
        end else if (start_accept) begin
            run_active   <= 1'b1;
            copy_done_reg <= 1'b0;
        end else if (run_active && time_copy_done &&
                     spectrum_copy_done) begin
            run_active   <= 1'b0;
            copy_done_reg <= 1'b1;
        end
    end

    // Time-domain copy controller.
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            time_state      <= COPY_DONE;
            time_word_index <= 15'd0;
            time_copy_done  <= 1'b0;
        end else if (start_accept) begin
            time_state      <= COPY_READ;
            time_word_index <= 15'd0;
            time_copy_done  <= 1'b0;
        end else if (run_active) begin
            case (time_state)
                COPY_READ: begin
                    time_state <= COPY_WAIT;
                end

                COPY_WAIT: begin
                    time_state <= COPY_WRITE;
                end

                COPY_WRITE: begin
                    if (time_word_index == TIME_COPY_WORDS - 1) begin
                        time_state     <= COPY_DONE;
                        time_copy_done <= 1'b1;
                    end else begin
                        time_word_index <= time_word_index + 1'b1;
                        time_state      <= COPY_READ;
                    end
                end

                default: begin
                    time_state     <= COPY_DONE;
                    time_copy_done <= 1'b1;
                end
            endcase
        end
    end

    // Spectrum copy controller.
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            spectrum_state      <= COPY_DONE;
            spectrum_word_index <= 10'd0;
            spectrum_copy_done  <= 1'b0;
        end else if (start_accept) begin
            spectrum_state      <= COPY_READ;
            spectrum_word_index <= 10'd0;
            spectrum_copy_done  <= 1'b0;
        end else if (run_active) begin
            case (spectrum_state)
                COPY_READ: begin
                    spectrum_state <= COPY_WAIT;
                end

                COPY_WAIT: begin
                    spectrum_state <= COPY_WRITE;
                end

                COPY_WRITE: begin
                    if (spectrum_word_index == SPECTRUM_COPY_WORDS - 1) begin
                        spectrum_state     <= COPY_DONE;
                        spectrum_copy_done <= 1'b1;
                    end else begin
                        spectrum_word_index <= spectrum_word_index + 1'b1;
                        spectrum_state      <= COPY_READ;
                    end
                end

                default: begin
                    spectrum_state     <= COPY_DONE;
                    spectrum_copy_done <= 1'b1;
                end
            endcase
        end
    end

    // BRAM controls.  Destination addresses are byte addresses because the
    // destination memories operate in BRAM Controller mode.
    always @* begin
        time_src_en   = 1'b0;
        time_src_addr = time_word_index;

        time_dst_en   = 1'b0;
        time_dst_we   = 4'b0000;
        time_dst_addr = {time_word_index, 2'b00};
        time_dst_din  = time_src_dout;

        if (run_active && (time_state != COPY_DONE)) begin
            time_src_en = 1'b1;
        end

        if (run_active && (time_state == COPY_WRITE)) begin
            time_dst_en = 1'b1;
            time_dst_we = 4'b1111;
        end
    end

    always @* begin
        spectrum_src_en   = 1'b0;
        spectrum_src_addr = spectrum_word_index;

        spectrum_dst_en   = 1'b0;
        spectrum_dst_we   = 4'b0000;
        spectrum_dst_addr = {1'b0, spectrum_word_index, 2'b00};
        spectrum_dst_din  = spectrum_src_dout;

        if (run_active && (spectrum_state != COPY_DONE)) begin
            spectrum_src_en = 1'b1;
        end

        if (run_active && (spectrum_state == COPY_WRITE)) begin
            spectrum_dst_en = 1'b1;
            spectrum_dst_we = 4'b1111;
        end
    end

endmodule

`default_nettype wire
