`timescale 1ns / 1ps
`default_nettype none

// ============================================================================
// 模块名称：adc_fifo_bram_chain
//
// 主要功能：
//   用于Block Design联调的ADC到BRAM整体链路。内部串接：
//     clock_tree -> adc_capture -> adc_write_controller
//     -> fifo_generator_0 -> fifo_ctrl -> fir_bram_adapter
//   并使用三个af_cdc实例完成启动、帧就绪和帧释放事件的跨时钟传输。
//
// 使用方法：
//   1. 将本文件及其依赖RTL、clk_wiz_0和fifo_generator_0加入Vivado工程。
//   2. 在Block Design中以Module Reference方式加入adc_fifo_bram_chain。
//   3. 将TIME_BRAM连接到32位True Dual Port Block Memory Generator的Port B。
//   4. Block Memory Generator的Port A连接AXI BRAM Controller，供PS读取。
//   5. capture_start接100 MHz域AXI GPIO输出；软件写0->1->0启动一帧。
//
// 连接说明：
//   clk_50m/rst_n      <- 板卡50 MHz系统时钟和低有效复位
//   adc_data_a/b       <- 板卡ADC并行数据管脚
//   adc_clk/oe         -> 板卡ADC控制管脚
//   capture_start      <- 与clk_100m_out同步的启动电平，上升沿有效
//   TIME_BRAM          -> BD内Block Memory Generator的Port B
//   clk_100m_out       -> BD内AXI、AXI BRAM Controller等100 MHz逻辑时钟
//   rst_100m_n_out     -> BD内100 MHz逻辑的低有效复位
//
// 时钟与复位：
//   ADC写侧工作在32 MHz，FIFO读侧、BRAM写侧和BD控制侧工作在100 MHz。
//   两个时钟均由clock_tree中的clk_wiz_0产生。rst_n异步有效，各域同步释放。
//
// 数据与存储：
//   ADC每帧采集FRAME_SIZE=65536点，FIFO控制器仍完整读出65536点以维持原有
//   帧握手。fir_bram_adapter只把帧首BRAM_SAMPLE_COUNT=32768点写入BRAM，
//   后32768点正常握手但直接丢弃。BRAM按两个S16样点打包为一个32位字。
//
// 握手时序：
//   capture_start上升沿经CDC送到32 MHz域；一帧写完后frame_done_event经CDC
//   通知fifo_ctrl；fifo_ctrl通过FIR握手送入fir_bram_adapter；FIFO末样点读完后
//   反向CDC释放写控制器；BRAM头部写完后capture_done输出一个100 MHz周期脉冲。
//
// 参数说明：
//   FRAME_SIZE默认65536且必须为偶数。BRAM_SAMPLE_COUNT必须等于FRAME_SIZE/2。
//   ADC_CHANNEL为0选择A通道，为1选择B通道。
//
// 错误行为：
//   任一控制器或CDC报告错误时error拉高并保持到系统复位。测试阶段可连接ILA。
//
// 使用限制：
//   capture_start必须来自clk_100m_out时钟域。若来自机械按键或其他时钟域，应先
//   完成同步和去抖。BRAM至少需要16388个32位字，推荐配置32768x32。
// ============================================================================

module adc_fifo_bram_chain #(
    parameter integer FRAME_SIZE        = 65536,  // ADC和FIFO每帧样点数
    parameter integer BRAM_SAMPLE_COUNT = 32768,  // 从帧首开始写入BRAM的样点数
    parameter integer ADC_CHANNEL       = 0       // 0选择ADC A，1选择ADC B
) (
    input  wire        clk_50m,             // 板载50 MHz输入时钟
    input  wire        rst_n,               // 系统低有效复位
    input  wire        capture_start,       // 100 MHz域启动电平，上升沿启动一帧

    input  wire [9:0]  adc_data_a,          // ADC A通道10位偏移二进制数据
    input  wire [9:0]  adc_data_b,          // ADC B通道10位偏移二进制数据
    output wire        adc_clk_a,           // ADC A转发采样时钟
    output wire        adc_clk_b,           // ADC B转发采样时钟
    output wire        adc_oe_a,            // ADC A输出控制，低有效
    output wire        adc_oe_b,            // ADC B输出控制，低有效

    output wire        clk_100m_out,        // 提供给BD内AXI逻辑的100 MHz时钟
    output wire        rst_100m_n_out,      // 提供给BD内AXI逻辑的低有效复位

    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM CLK" *)
    output wire        time_bram_clk,       // 时域BRAM Port B时钟
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME TIME_BRAM, MASTER_TYPE BRAM_CTRL, MEM_ECC NONE, MEM_SIZE 131072, MEM_WIDTH 32, READ_LATENCY 1" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM RST" *)
    output wire        time_bram_rst,       // 时域BRAM Port B高有效复位
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM EN" *)
    output wire        time_bram_en,        // 时域BRAM Port B使能
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM WE" *)
    output wire [3:0]  time_bram_we,        // 时域BRAM Port B字节写使能
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM ADDR" *)
    output wire [16:0] time_bram_addr,      // 时域BRAM Port B字节地址
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM DIN" *)
    output wire [31:0] time_bram_din,       // 时域BRAM Port B写数据
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 TIME_BRAM DOUT" *)
    input  wire [31:0] time_bram_dout,      // 时域BRAM Port B读数据

    output wire        capture_ready,       // 可接受新启动命令的100 MHz域状态
    output wire        capture_busy,        // ADC正在采集或存在待处理帧
    output wire        capture_done,        // BRAM整帧写完的100 MHz单周期脉冲
    output wire        error,               // 任一链路错误的汇总状态
    output wire        locked               // Clock Wizard锁定状态
);

    wire clk_100m;
    wire clk_32m;
    wire clk_32m_adc;
    wire rst_100m;
    wire rst_32m;

    reg  capture_start_d;
    wire capture_start_pulse;
    wire start_cdc_busy;
    wire start_cdc_error;
    wire capture_start_32m;

    wire signed [15:0] adc_sample_a;
    wire signed [15:0] adc_sample_b;
    wire signed [15:0] adc_sample_selected;
    wire               adc_valid;

    wire [15:0] fifo_din;
    wire        fifo_wr_en;
    wire        fifo_full;
    wire        fifo_wr_rst_busy;
    wire [15:0] fifo_dout;
    wire        fifo_rd_en;
    wire        fifo_empty;
    wire        fifo_rd_rst_busy;
    wire        fifo_rst;

    wire adc_capture_busy;
    wire frame_pending;
    wire frame_done_32m;
    wire adc_overflow_error;

    wire frame_ready_100m;
    wire frame_ready_cdc_busy;
    wire frame_ready_cdc_error;

    wire fifo_frame_done_100m;
    wire frame_consumed_32m;
    wire frame_consumed_cdc_busy;
    wire frame_consumed_cdc_error;

    wire signed [15:0] fir_data;
    wire               fir_valid;
    wire               fir_ready;
    wire               fir_first;
    wire               fir_last;
    wire               fir_frame_done;
    wire               transfer_busy;
    wire               fifo_underflow_error;
    wire               fifo_protocol_error;
    wire [((FRAME_SIZE <= 1) ? 1 : $clog2(FRAME_SIZE))-1:0]
                       transfer_index;

    wire bram_writer_busy;
    wire bram_protocol_error;

    reg capture_busy_meta;
    reg capture_busy_sync;
    reg frame_pending_meta;
    reg frame_pending_sync;

    assign clk_100m_out   = clk_100m;
    assign rst_100m_n_out = ~rst_100m;
    assign fifo_rst       = ~rst_n | ~locked;

    // AXI GPIO可输出保持电平；这里只把其上升沿转换为单周期启动事件。
    always @(posedge clk_100m) begin
        if (rst_100m) begin
            capture_start_d <= 1'b0;
        end else begin
            capture_start_d <= capture_start;
        end
    end
    assign capture_start_pulse = capture_start && !capture_start_d;

    // ADC域状态同步到100 MHz域，仅用于BD状态显示，不参与数据握手。
    always @(posedge clk_100m) begin
        if (rst_100m) begin
            capture_busy_meta  <= 1'b0;
            capture_busy_sync  <= 1'b0;
            frame_pending_meta <= 1'b0;
            frame_pending_sync <= 1'b0;
        end else begin
            capture_busy_meta  <= adc_capture_busy;
            capture_busy_sync  <= capture_busy_meta;
            frame_pending_meta <= frame_pending;
            frame_pending_sync <= frame_pending_meta;
        end
    end

    assign capture_busy = capture_busy_sync || frame_pending_sync ||
                          transfer_busy || bram_writer_busy;
    assign capture_ready = locked && !rst_100m && !capture_busy &&
                           !start_cdc_busy && !fifo_wr_rst_busy &&
                           !fifo_rd_rst_busy;

    assign adc_sample_selected =
        (ADC_CHANNEL == 0) ? adc_sample_a : adc_sample_b;

    assign capture_done = fir_frame_done;
    assign error = start_cdc_error || frame_ready_cdc_error ||
                   frame_consumed_cdc_error || adc_overflow_error ||
                   fifo_underflow_error || fifo_protocol_error ||
                   bram_protocol_error;

    clock_tree u_clock_tree (
        .clk_50m     (clk_50m),
        .rst_n       (rst_n),
        .clk_100m    (clk_100m),
        .clk_32m     (clk_32m),
        .clk_32m_adc (clk_32m_adc),
        .rst_100m    (rst_100m),
        .rst_32m     (rst_32m),
        .locked      (locked)
    );

    adc_capture u_adc_capture (
        .clk        (clk_32m),
        .clk_drive  (clk_32m_adc),
        .rst        (rst_32m),
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

    af_cdc u_start_cdc (
        .src_clk            (clk_100m),
        .src_rst            (rst_100m),
        .src_event          (capture_start_pulse),
        .src_busy           (start_cdc_busy),
        .src_protocol_error (start_cdc_error),
        .dst_clk            (clk_32m),
        .dst_rst            (rst_32m),
        .dst_event          (capture_start_32m)
    );

    adc_write_controller #(
        .DATA_WIDTH   (16),
        .FRAME_LENGTH (FRAME_SIZE)
    ) u_adc_write_controller (
        .clk              (clk_32m),
        .rst              (rst_32m),
        .capture_start    (capture_start_32m),
        .frame_consumed   (frame_consumed_32m),
        .clear_error      (1'b0),
        .fifo_ready       (!fifo_full && !fifo_wr_rst_busy),
        .data_in          (adc_sample_selected),
        .in_valid         (adc_valid),
        .fifo_full        (fifo_full),
        .fifo_wr_rst_busy (fifo_wr_rst_busy),
        .fifo_din         (fifo_din),
        .fifo_wr_en       (fifo_wr_en),
        .capture_busy     (adc_capture_busy),
        .frame_pending    (frame_pending),
        .frame_done_event (frame_done_32m),
        .overflow_error   (adc_overflow_error)
    );

    fifo_generator_0 u_sample_fifo (
        .rst         (fifo_rst),
        .wr_clk      (clk_32m),
        .rd_clk      (clk_100m),
        .din         (fifo_din),
        .wr_en       (fifo_wr_en),
        .rd_en       (fifo_rd_en),
        .dout        (fifo_dout),
        .full        (fifo_full),
        .empty       (fifo_empty),
        .wr_rst_busy (fifo_wr_rst_busy),
        .rd_rst_busy (fifo_rd_rst_busy)
    );

    af_cdc u_frame_ready_cdc (
        .src_clk            (clk_32m),
        .src_rst            (rst_32m),
        .src_event          (frame_done_32m),
        .src_busy           (frame_ready_cdc_busy),
        .src_protocol_error (frame_ready_cdc_error),
        .dst_clk            (clk_100m),
        .dst_rst            (rst_100m),
        .dst_event          (frame_ready_100m)
    );

    fifo_ctrl #(
        .DATA_WIDTH (16),
        .FRAME_SIZE (FRAME_SIZE)
    ) u_fifo_ctrl (
        .clk               (clk_100m),
        .rst               (rst_100m),
        .frame_ready_event (frame_ready_100m),
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
        .transfer_busy     (transfer_busy),
        .fifo_frame_done   (fifo_frame_done_100m),
        .underflow_error   (fifo_underflow_error),
        .protocol_error    (fifo_protocol_error),
        .transfer_index    (transfer_index)
    );

    af_cdc u_frame_consumed_cdc (
        .src_clk            (clk_100m),
        .src_rst            (rst_100m),
        .src_event          (fifo_frame_done_100m),
        .src_busy           (frame_consumed_cdc_busy),
        .src_protocol_error (frame_consumed_cdc_error),
        .dst_clk            (clk_32m),
        .dst_rst            (rst_32m),
        .dst_event          (frame_consumed_32m)
    );

    fir_bram_adapter #(
        .DATA_WIDTH       (16),
        .INPUT_FRAME_SIZE (FRAME_SIZE),
        .STORE_SAMPLES    (BRAM_SAMPLE_COUNT),
        .ADDR_WIDTH       (17)
    ) u_fir_bram_adapter (
        .clk             (clk_100m),
        .rst             (rst_100m),
        .clear_error     (1'b0),
        .fir_data        (fir_data),
        .fir_valid       (fir_valid),
        .fir_ready       (fir_ready),
        .fir_first       (fir_first),
        .fir_last        (fir_last),
        .fir_frame_done  (fir_frame_done),
        .time_bram_clk   (time_bram_clk),
        .time_bram_rst   (time_bram_rst),
        .time_bram_en    (time_bram_en),
        .time_bram_we    (time_bram_we),
        .time_bram_addr  (time_bram_addr),
        .time_bram_din   (time_bram_din),
        .time_bram_dout  (time_bram_dout),
        .busy            (bram_writer_busy),
        .protocol_error  (bram_protocol_error)
    );

    // synthesis translate_off
    initial begin
        if ((FRAME_SIZE <= 0) || (FRAME_SIZE > 65536) ||
            ((FRAME_SIZE % 2) != 0)) begin
            $error("adc_fifo_bram_chain: FRAME_SIZE参数错误");
        end
        if ((BRAM_SAMPLE_COUNT <= 0) ||
            ((BRAM_SAMPLE_COUNT * 2) != FRAME_SIZE)) begin
            $error("adc_fifo_bram_chain: BRAM_SAMPLE_COUNT必须等于FRAME_SIZE/2");
        end
        if ((ADC_CHANNEL < 0) || (ADC_CHANNEL > 1)) begin
            $error("adc_fifo_bram_chain: ADC_CHANNEL只能为0或1");
        end
    end
    // synthesis translate_on

endmodule

`default_nettype wire
