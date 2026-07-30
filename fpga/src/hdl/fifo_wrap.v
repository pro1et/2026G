`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：fifo_wrap
//
// 主要功能：
//   把 ADC 写控制器、16 位异步 FIFO、FIFO 读控制器和双向事件 CDC 封装为一个
//   完整的帧缓存子系统。顶层只需提供 ADC 数据、采集控制和 FIR valid-ready
//   接口，不需要处理 FIFO 原生端口或跨时钟域事件。
//
// 使用方法：
//   1. 将 wr_clk/wr_rst 连接到 ADC 与 FIFO 写端时钟域。
//   2. 将 rd_clk/rd_rst 连接到 FIFO 读端与 FIR 时钟域。
//   3. 将 fifo_rst 连接到 fifo_generator_0 的系统异步复位请求。
//   4. fifo_ready 为高后，用一个 wr_clk 周期的 capture_start 启动一帧采集。
//   5. FIR 通过 fir_valid/fir_ready 接收数据，并在整帧输出完成后给出
//      一个 rd_clk 周期的 fir_frame_done。
//
// 连接说明：
//   wr_clk/wr_rst       <- ADC/FIFO 写时钟域及其同步复位
//   rd_clk/rd_rst       <- FIFO 读端/FIR 时钟域及其同步复位
//   fifo_rst            <- 系统复位控制，直接连接异步 FIFO IP 的 rst
//   adc_data/adc_valid  <- ADC 采集及有符号格式转换模块
//   capture_start       <- 写域上层采集控制逻辑
//   clear_error         <- 写域上层错误恢复控制逻辑
//   fir_*               <-> FIR 模块的输入握手与帧边界接口
//   fir_frame_done      <- FIR 当前帧全部处理完成的读域单周期事件
//   写域和读域状态输出 -> 顶层状态控制、ILA 或故障监控逻辑
//
// 时钟与复位：
//   wr_clk 与 rd_clk 可异步，当前系统分别为 30 MHz 和 100 MHz。wr_rst、rd_rst
//   是所属时钟域高有效同步复位；fifo_rst 是 FIFO IP 高有效异步复位。三者必须
//   由同一次系统复位协调产生，不支持运行中只复位某一个域。
//
// 输入格式：
//   adc_data 为 DATA_WIDTH 位有符号二进制补码整数；默认且当前唯一支持 16 位。
//   本模块不缩放、不舍入、不饱和，也不改变其二进制位模式。
//
// 输出格式：
//   fir_data 显式声明为有符号二进制补码，与 adc_data 位宽和位模式一致。
//   fir_first/fir_last 仅在 fir_valid 为高时有效，并随数据保持到握手完成。
//
// 握手时序：
//   写满 FRAME_SIZE 个有效样点后，正向 af_cdc 通知读域开始读帧。FIFO 为 FWFT
//   模式；只有 fir_valid && fir_ready 时才弹出一个 FIFO 字。最后一个 FIFO 字
//   被 FIR 接收后，反向 af_cdc 通知写域该帧已消费，允许后续采集。
//
// 参数说明：
//   DATA_WIDTH 为数据位宽。fifo_generator_0 固定为 16 位，因此本版本必须取 16。
//   FRAME_SIZE 为每帧有效样点数，必须大于 0且不超过 FIFO 实际容量 65537。
//
// 错误行为：
//   wr_error 汇总 wr_clk 域的写溢出和正向 CDC 协议错误。
//   rd_error 汇总 rd_clk 域的读下溢、读控制协议错误和反向 CDC 协议错误。
//   clear_error 只清除 ADC 写控制器错误；CDC 和读控制错误必须通过协调复位清除。
//
// 使用限制：
//   必须使用工程中的 16 位、独立时钟、FWFT fifo_generator_0。fifo_ready 只表示
//   写控制器和 FIFO 写端已退出复位；上层仍须遵守 capture_busy/frame_pending，
//   不得在上一帧尚未消费时重复启动。峰值写入和读取吞吐率均为每周期一个样点。
// ============================================================================

module fifo_wrap #(
    parameter DATA_WIDTH = 16,     // 数据位宽，本版本必须为 16
    parameter FRAME_SIZE = 65536   // 每帧样点数，合法范围为 1 到 65537
) (
    input  wire                         wr_clk,          // ADC/FIFO 写时钟域工作时钟
    input  wire                         wr_rst,          // wr_clk 域高电平有效同步复位
    input  wire                         rd_clk,          // FIFO 读端/FIR 时钟域工作时钟
    input  wire                         rd_rst,          // rd_clk 域高电平有效同步复位
    input  wire                         fifo_rst,        // FIFO IP 高电平有效异步复位

    input  wire signed [DATA_WIDTH-1:0] adc_data,        // ADC 有符号二进制补码采样值
    input  wire                         adc_valid,       // ADC 数据有效，高电平可连续保持
    input  wire                         capture_start,   // 写域单周期采集启动事件
    input  wire                         clear_error,     // 写域 ADC 写错误清除请求

    output wire signed [DATA_WIDTH-1:0] fir_data,        // FIR 有符号二进制补码输入数据
    output wire                         fir_valid,       // FIR 输入数据有效
    input  wire                         fir_ready,       // FIR 可以接收当前输入
    output wire                         fir_first,       // 当前有效数据为帧首
    output wire                         fir_last,        // 当前有效数据为帧尾
    input  wire                         fir_frame_done,  // FIR 整帧处理完成的读域单周期事件

    output wire                         capture_busy,    // 写域正在采集一帧
    output wire                         frame_pending,   // 写域完整帧尚未被读端消费
    output wire                         fifo_ready,      // 写域控制器和 FIFO 写端均已就绪
    output wire                         wr_error,        // wr_clk 域粘滞错误汇总
    output wire                         rd_error         // rd_clk 域粘滞错误汇总
);

    wire [DATA_WIDTH-1:0] fifo_din;
    wire [DATA_WIDTH-1:0] fifo_dout;
    wire                  fifo_wr_en;
    wire                  fifo_rd_en;
    wire                  fifo_full;
    wire                  fifo_empty;
    wire                  fifo_wr_rst_busy;
    wire                  fifo_rd_rst_busy;

    wire frame_done_event;
    wire frame_ready_event;
    wire fifo_frame_done;
    wire frame_consumed;

    wire frame_ready_cdc_busy;
    wire frame_consumed_cdc_busy;
    wire frame_ready_cdc_error;
    wire frame_consumed_cdc_error;

    wire overflow_error;
    wire underflow_error;
    wire fifo_protocol_error;
    wire transfer_busy_unused;
    wire [((FRAME_SIZE <= 1) ? 1 : $clog2(FRAME_SIZE))-1:0]
         transfer_index_unused;

    // FIFO 写端 busy 已在 wr_clk 域产生，可直接用于本域就绪判断。
    assign fifo_ready = ~wr_rst & ~fifo_wr_rst_busy;

    // 错误只在各自所属时钟域内组合，避免产生未同步的跨域状态路径。
    assign wr_error = overflow_error | frame_ready_cdc_error;
    assign rd_error = underflow_error
                    | fifo_protocol_error
                    | frame_consumed_cdc_error;

    initial begin
        if (DATA_WIDTH != 16) begin
            $error("fifo_wrap 的 DATA_WIDTH 必须为 16，与 fifo_generator_0 一致");
        end
        if ((FRAME_SIZE < 1) || (FRAME_SIZE > 65537)) begin
            $error("fifo_wrap 的 FRAME_SIZE 必须在 1 到 65537 范围内");
        end
    end

    adc_write_controller #(
        .DATA_WIDTH   (DATA_WIDTH),
        .FRAME_LENGTH (FRAME_SIZE)
    ) u_adc_write_controller (
        .clk               (wr_clk),
        .rst               (wr_rst),
        .capture_start     (capture_start),
        .frame_consumed    (frame_consumed),
        .clear_error       (clear_error),
        .fifo_ready        (fifo_ready),
        .data_in           (adc_data),
        .in_valid          (adc_valid),
        .fifo_full         (fifo_full),
        .fifo_wr_rst_busy  (fifo_wr_rst_busy),
        .fifo_din          (fifo_din),
        .fifo_wr_en        (fifo_wr_en),
        .capture_busy      (capture_busy),
        .frame_pending     (frame_pending),
        .frame_done_event  (frame_done_event),
        .overflow_error    (overflow_error)
    );

    fifo_generator_0 u_fifo_generator_0 (
        .rst         (fifo_rst),
        .wr_clk      (wr_clk),
        .rd_clk      (rd_clk),
        .din         (fifo_din),
        .wr_en       (fifo_wr_en),
        .rd_en       (fifo_rd_en),
        .dout        (fifo_dout),
        .full        (fifo_full),
        .empty       (fifo_empty),
        .wr_rst_busy (fifo_wr_rst_busy),
        .rd_rst_busy (fifo_rd_rst_busy)
    );

    af_cdc #(
        .SYNC_STAGES (2)
    ) u_frame_ready_cdc (
        .src_clk            (wr_clk),
        .src_rst            (wr_rst),
        .src_event          (frame_done_event),
        .src_busy           (frame_ready_cdc_busy),
        .src_protocol_error (frame_ready_cdc_error),
        .dst_clk            (rd_clk),
        .dst_rst            (rd_rst),
        .dst_event          (frame_ready_event)
    );

    fifo_ctrl #(
        .DATA_WIDTH (DATA_WIDTH),
        .FRAME_SIZE (FRAME_SIZE)
    ) u_fifo_ctrl (
        .clk               (rd_clk),
        .rst               (rd_rst),
        .frame_ready_event (frame_ready_event),
        .fifo_dout         (fifo_dout),
        .fifo_empty        (fifo_empty),
        .fifo_rd_rst_busy  (fifo_rd_rst_busy),
        .fifo_rd_en        (fifo_rd_en),
        .fir_data          (fir_data),
        .fir_valid         (fir_valid),
        .fir_ready         (fir_ready),
        .fir_first         (fir_first),
        .fir_last          (fir_last),
        .fir_frame_done    (fir_frame_done),
        .transfer_busy     (transfer_busy_unused),
        .fifo_frame_done   (fifo_frame_done),
        .underflow_error   (underflow_error),
        .protocol_error    (fifo_protocol_error),
        .transfer_index    (transfer_index_unused)
    );

    af_cdc #(
        .SYNC_STAGES (2)
    ) u_frame_consumed_cdc (
        .src_clk            (rd_clk),
        .src_rst            (rd_rst),
        .src_event          (fifo_frame_done),
        .src_busy           (frame_consumed_cdc_busy),
        .src_protocol_error (frame_consumed_cdc_error),
        .dst_clk            (wr_clk),
        .dst_rst            (wr_rst),
        .dst_event          (frame_consumed)
    );

endmodule

`default_nettype wire
