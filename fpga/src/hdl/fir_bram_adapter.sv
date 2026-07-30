`timescale 1ns / 1ps
`default_nettype none

// ============================================================================
// 模块名称：fir_bram_adapter
//
// 主要功能：
//   按照 fifo_ctrl 所要求的 FIR valid-ready 帧协议接收 16 位原始样点，将相邻
//   两个样点打包为一个 32 位字并写入 PS 可见的时域 BRAM。本模块不执行滤波，
//   仅在接口行为上作为一个能够接收整帧数据并产生 fir_frame_done 的“伪 FIR”。
//
// 使用方法：
//   1. 将 fir_* 输入连接到 fifo_ctrl 的同名输出。
//   2. 将 fir_ready 和 fir_frame_done 连接回 fifo_ctrl。
//   3. 将 TIME_BRAM 接口连接到 Block Memory Generator 的一个端口。
//   4. Block Memory Generator 的另一个端口可连接 AXI BRAM Controller，供 PS 读取。
//
// 连接说明：
//   clk             <- fifo_ctrl 所在的 100 MHz 处理时钟
//   rst             <- 100 MHz 域高电平有效同步复位
//   fir_*           <- fifo_ctrl 的 FIR 输入接口
//   time_bram_*     -> 32 位 True Dual Port BRAM 的 PL 写端
//   fir_frame_done  -> fifo_ctrl.fir_frame_done
//
// 时钟与复位：
//   所有业务输入均属于 clk 域。time_bram_clk 与 clk 同源；time_bram_rst 高有效。
//
// 输入格式：
//   fir_data 为 DATA_WIDTH 位有符号二进制补码。默认 DATA_WIDTH=16。
//   输入帧默认包含 INPUT_FRAME_SIZE=65536 个样点，但只保存最前面的
//   STORE_SAMPLES=32768 个样点；剩余样点继续握手接收但不写BRAM。
//
// 输出格式：
//   采用 Curve_mini 时域 BRAM 的 32 位字和字节地址定义：
//     W0 = vpp_raw，本验证版本写 0
//     W1 = vrms_sq_raw，本验证版本写 0
//     W2 = f1_hz，本验证版本写 0
//     W3 = sample_count，写 STORE_SAMPLES
//     W4 起保存原始波形
//   每个波形字 bit[15:0] 为偶数序号样点，bit[31:16] 为奇数序号样点。
//
// 握手时序：
//   仅在 fir_valid && fir_ready 时接收一个样点。接收奇数序号样点的同一上升沿
//   写入一个 32 位 BRAM 字。最后一个样点接收后依次写四个头部字，随后产生一个
//   clk 周期的 fir_frame_done。写头期间 fir_ready 为低。
//
// 参数说明：
//   DATA_WIDTH       当前必须为16，以匹配两个S16打包为一个32位字。
//   INPUT_FRAME_SIZE fifo_ctrl送入的每帧样点数，默认65536。
//   STORE_SAMPLES    从帧首开始写入BRAM的样点数，默认32768。
//   ADDR_WIDTH       BRAM字节地址位宽，默认17位，对应128 KiB地址空间。
//
// 错误行为：
//   fir_first/fir_last 与固定帧位置不一致时 protocol_error 锁存为高；clear_error
//   可将其清除。为避免链路死锁，帧长度仍以内部计数器为准。
//
// 使用限制：
//   BRAM必须配置为32位数据宽度，地址必须采用BRAM Controller字节地址语义。
//   输入帧长和保存点数均须为偶数，STORE_SAMPLES不得大于INPUT_FRAME_SIZE。
//   写入期间PS不应读取尚未完成的当前帧。
// ============================================================================

module fir_bram_adapter #(
    parameter int unsigned DATA_WIDTH       = 16,     // 输入样点位宽，当前必须为16
    parameter int unsigned INPUT_FRAME_SIZE = 65536,  // fifo_ctrl送入的每帧样点数
    parameter int unsigned STORE_SAMPLES    = 32768,  // 从帧首开始保存的样点数
    parameter int unsigned ADDR_WIDTH       = 17      // BRAM字节地址位宽，默认覆盖128 KiB
) (
    input  wire logic                         clk,             // 处理时钟
    input  wire logic                         rst,             // 高电平有效同步复位
    input  wire logic                         clear_error,     // 错误清除，高电平可保持

    input  wire logic signed [DATA_WIDTH-1:0] fir_data,        // FIFO控制器输出的有符号样点
    input  wire logic                         fir_valid,       // 输入样点有效
    output      logic                         fir_ready,       // 可接收样点，写头期间拉低
    input  wire logic                         fir_first,       // 当前样点为帧首
    input  wire logic                         fir_last,        // 当前样点为帧尾
    output      logic                         fir_frame_done,  // BRAM整帧写完的单周期脉冲

    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM CLK" *)
    output wire logic                         time_bram_clk,   // BRAM端口时钟
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME TIME_BRAM, MASTER_TYPE BRAM_CTRL, MEM_ECC NONE, MEM_SIZE 131072, MEM_WIDTH 32, READ_LATENCY 1" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM RST" *)
    output wire logic                         time_bram_rst,   // BRAM端口高有效复位
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM EN" *)
    output      logic                         time_bram_en,    // BRAM端口使能
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM WE" *)
    output      logic [3:0]                   time_bram_we,    // 4字节写使能
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM ADDR" *)
    output      logic [ADDR_WIDTH-1:0]        time_bram_addr,  // BRAM字节地址
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM DIN" *)
    output      logic [31:0]                  time_bram_din,   // BRAM写数据
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM DOUT" *)
    input  wire logic [31:0]                  time_bram_dout,  // BRAM读数据，本模块不使用

    output      logic                         busy,            // 正在接收或整理一帧
    output      logic                         protocol_error   // 帧首尾协议错误，粘滞有效
);

    localparam int unsigned INDEX_WIDTH =
        (INPUT_FRAME_SIZE <= 1) ? 1 : $clog2(INPUT_FRAME_SIZE);
    localparam logic [INDEX_WIDTH-1:0] LAST_INDEX = INPUT_FRAME_SIZE - 1;
    localparam logic [INDEX_WIDTH-1:0] STORE_LIMIT = STORE_SAMPLES;
    localparam logic [ADDR_WIDTH-1:0] DATA_BASE_ADDR = 16;

    typedef enum logic [2:0] {
        STATE_STREAM,
        STATE_META_VPP,
        STATE_META_RMS,
        STATE_META_F1,
        STATE_META_COUNT
    } state_t;

    state_t state;

    logic [INDEX_WIDTH-1:0] sample_index;
    logic [15:0]            pair_low;
    logic [ADDR_WIDTH-1:0]  data_write_addr;
    logic                   transfer_fire;
    wire  logic             unused_bram_dout;

    assign time_bram_clk   = clk;
    assign time_bram_rst   = rst;
    assign unused_bram_dout = ^time_bram_dout;

    always_comb begin
        fir_ready      = (state == STATE_STREAM) && !rst;
        transfer_fire  = fir_valid && fir_ready;
        busy           = (state != STATE_STREAM) || (sample_index != '0);

        time_bram_en   = 1'b0;
        time_bram_we   = 4'b0000;
        time_bram_addr = '0;
        time_bram_din  = 32'd0;

        // 收到一对中的第二个样点时，直接写出完整32位波形字。
        if (transfer_fire && sample_index[0] &&
            (sample_index < STORE_LIMIT)) begin
            time_bram_en   = 1'b1;
            time_bram_we   = 4'b1111;
            time_bram_addr = data_write_addr;
            time_bram_din  = {fir_data[15:0], pair_low};
        end

        // 帧数据写完后补齐 Curve_mini 约定的四个头部字。
        case (state)
            STATE_META_VPP: begin
                time_bram_en   = 1'b1;
                time_bram_we   = 4'b1111;
                time_bram_addr = 'd0;
                time_bram_din  = 32'd0;
            end

            STATE_META_RMS: begin
                time_bram_en   = 1'b1;
                time_bram_we   = 4'b1111;
                time_bram_addr = 'd4;
                time_bram_din  = 32'd0;
            end

            STATE_META_F1: begin
                time_bram_en   = 1'b1;
                time_bram_we   = 4'b1111;
                time_bram_addr = 'd8;
                time_bram_din  = 32'd0;
            end

            STATE_META_COUNT: begin
                time_bram_en   = 1'b1;
                time_bram_we   = 4'b1111;
                time_bram_addr = 'd12;
                time_bram_din  = STORE_SAMPLES;
            end

            default: begin
                // STATE_STREAM 的波形写逻辑已在上方给出。
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state            <= STATE_STREAM;
            sample_index     <= '0;
            pair_low         <= 16'd0;
            data_write_addr  <= DATA_BASE_ADDR;
            fir_frame_done   <= 1'b0;
            protocol_error   <= 1'b0;
        end else begin
            fir_frame_done <= 1'b0;

            if (clear_error) begin
                protocol_error <= 1'b0;
            end

            case (state)
                STATE_STREAM: begin
                    if (transfer_fire) begin
                        if ((sample_index == '0) != fir_first) begin
                            protocol_error <= 1'b1;
                        end
                        if ((sample_index == LAST_INDEX) != fir_last) begin
                            protocol_error <= 1'b1;
                        end

                        if (!sample_index[0]) begin
                            pair_low <= fir_data[15:0];
                        end else if (sample_index < STORE_LIMIT) begin
                            data_write_addr <= data_write_addr + 4;
                        end

                        if (sample_index == LAST_INDEX) begin
                            sample_index <= '0;
                            state        <= STATE_META_VPP;
                        end else begin
                            sample_index <= sample_index + 1'b1;
                        end
                    end
                end

                STATE_META_VPP: begin
                    state <= STATE_META_RMS;
                end

                STATE_META_RMS: begin
                    state <= STATE_META_F1;
                end

                STATE_META_F1: begin
                    state <= STATE_META_COUNT;
                end

                STATE_META_COUNT: begin
                    data_write_addr <= DATA_BASE_ADDR;
                    fir_frame_done  <= 1'b1;
                    state           <= STATE_STREAM;
                end

                default: begin
                    state           <= STATE_STREAM;
                    sample_index    <= '0;
                    data_write_addr <= DATA_BASE_ADDR;
                    protocol_error  <= 1'b1;
                end
            endcase
        end
    end

    initial begin
        assert (DATA_WIDTH == 16)
            else $fatal(1, "fir_bram_adapter: DATA_WIDTH 当前必须为16");
        assert (INPUT_FRAME_SIZE > 0 && INPUT_FRAME_SIZE <= 65536)
            else $fatal(1, "fir_bram_adapter: INPUT_FRAME_SIZE必须为1到65536");
        assert ((INPUT_FRAME_SIZE % 2) == 0)
            else $fatal(1, "fir_bram_adapter: INPUT_FRAME_SIZE必须为偶数");
        assert (STORE_SAMPLES > 0 && STORE_SAMPLES <= INPUT_FRAME_SIZE)
            else $fatal(1, "fir_bram_adapter: STORE_SAMPLES范围错误");
        assert ((STORE_SAMPLES % 2) == 0)
            else $fatal(1, "fir_bram_adapter: STORE_SAMPLES必须为偶数");
        assert (ADDR_WIDTH >= 17)
            else $fatal(1, "fir_bram_adapter: ADDR_WIDTH必须至少为17");
    end

endmodule

`default_nettype wire
