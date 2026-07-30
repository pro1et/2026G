`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：adc_write_controller
//
// 主要功能：
//   将单路有符号 ADC 样点按固定长度帧写入 16 位异步 FIFO 的写端。本模块负责
//   写入判定、帧内计数、完成通知和帧完整性错误锁存；不负责
//   ADC 码制转换、FIFO 读控制、FIFO 清空或跨时钟域同步。
//
// 使用方法：
//   1. 将 clk、rst 连接到 ADC 采样模块与异步 FIFO 写端所在的同一时钟域。
//   2. 将 data_in 和 in_valid 连接到 ADC 采集/格式转换模块的单路输出。
//   3. 将 fifo_din、fifo_wr_en 连接到异步 FIFO 写端，并接入写侧状态信号。
//   4. FIFO 空且复位完成后拉高 fifo_ready，再用单周期 capture_start 启动一帧。
//   5. 将 frame_done_event、frame_consumed 的 CDC 握手放在本模块外部。
//
// 连接说明：
//   clk                  <- clock_tree 输出的 ADC/FIFO 写时钟
//   rst                  <- clk 域高有效同步复位
//   capture_start        <- 本时钟域的单周期启动事件
//   frame_consumed       <- 读侧完成事件经 CDC 后形成的本时钟域单周期脉冲
//   clear_error          <- 系统错误恢复控制逻辑
//   fifo_ready           <- 系统确认 FIFO 为空且写端已完成复位的本时钟域状态
//   data_in              <- ADC 采集/格式转换模块的单路有符号样点
//   in_valid             <- ADC 采集/格式转换模块的样点有效信号
//   fifo_full            <- 异步 FIFO 写端 full
//   fifo_wr_rst_busy     <- 异步 FIFO 写端 wr_rst_busy
//   fifo_din/fifo_wr_en  -> 异步 FIFO 写端 din/wr_en
//   frame_done_event     -> 外部帧完成 CDC 握手模块
//
// 时钟与复位：
//   所有端口均属于 clk 域；来自其他时钟域的控制信号必须先在模块外完成 CDC。
//   rst 为高电平有效同步复位。复位上升沿后写使能、状态和错误输出均无效。
//
// 输入格式：
//   data_in 为 DATA_WIDTH 位有符号二进制补码整数。默认 DATA_WIDTH=16，数值范围
//   为 -32768～32767；本模块不缩放、不舍入、不饱和，也不改变位模式。
//
// 输出格式：
//   fifo_din 与 data_in 等宽并保持其二进制补码位模式。FRAME_LENGTH 表示每帧
//   样点数，因此每帧产生恰好 FRAME_LENGTH 个 FIFO 写字。
//
// 握手时序：
//   capture_start 仅在空闲且 FIFO 可用时接受；接受后的下一周期可首次写入。
//   采集中仅当 in_valid=1、FIFO 未满且写端可用时 fifo_wr_en=1。最后一个样点
//   仍正常写入，并在该上升沿后产生持续一个 clk 周期的 frame_done_event。
//   frame_pending 保持到 frame_consumed 到来；此期间新的启动请求被忽略。
//
// 参数说明：
//   DATA_WIDTH 为单通道样点位宽，必须大于 0，默认 16 位。
//   FRAME_LENGTH 为每帧样点数，必须大于 0，默认 65536 点。当前 FWFT FIFO 的
//   实际可写深度为 65537，可以完整保存一帧并保留一个存储位置的容量余量。
//
// 错误行为：
//   采集中若有效样点遇到 fifo_full，或 FIFO 写端复位忙/失去 ready，则当前帧
//   已不完整：立即停止写入、进入错误状态并锁存 overflow_error，不产生帧完成
//   事件。外部必须清空或复位 FIFO；仅当 FIFO 恢复可用且 clear_error=1 时复原。
//
// 使用限制：
//   上游不能被反压；本模块通过报错而不是暂停来处理会导致丢样的 FIFO 阻塞。
//   data_in 必须与 in_valid 对齐并在有效写入沿满足建立/保持时间。若要同时保存
//   两路 ADC，必须使用两个本模块/两个 16 位 FIFO，或改用一个 32 位 FIFO。
//   峰值吞吐率为每个 clk 周期一个样点，数据通路无额外寄存延迟。
// ============================================================================

module adc_write_controller #(
    parameter int unsigned DATA_WIDTH   = 16,    // 单通道有符号样点位宽，单位为位，必须大于 0
    parameter int unsigned FRAME_LENGTH = 65536  // 每帧样点数，单位为点，必须大于 0且不超过 FIFO 实际可写深度
) (
    input  wire logic                     clk,               // ADC/FIFO 写时钟，所有端口均属于此时钟域
    input  wire logic                     rst,               // 高电平有效同步复位

    input  wire logic                     capture_start,     // 启动一帧采集的单周期脉冲，仅空闲且 FIFO 可用时接受
    input  wire logic                     frame_consumed,    // 上一帧已读完的单周期脉冲，必须已完成 CDC
    input  wire logic                     clear_error,       // 错误清除请求，高电平可保持，仅错误状态下处理
    input  wire logic                     fifo_ready,        // FIFO 为空且复位完成的状态，采集期间必须持续为高

    input  wire logic signed [DATA_WIDTH-1:0] data_in,       // 单路有符号二进制补码样点，in_valid 为高时有效
    input  wire logic                     in_valid,          // 输入样点有效，高电平可连续保持

    input  wire logic                     fifo_full,         // FIFO 写满状态，高电平时禁止写入
    input  wire logic                     fifo_wr_rst_busy,  // FIFO 写端复位忙状态，高电平时禁止写入
    output logic [DATA_WIDTH-1:0]          fifo_din,          // FIFO 写数据，保持 data_in 的二进制补码位模式
    output logic                          fifo_wr_en,        // FIFO 写使能，高电平表示当前上升沿写入一个样点

    output logic                          capture_busy,      // 正在采集一帧的状态电平
    output logic                          frame_pending,     // FIFO 中有完整帧等待读取的状态电平
    output logic                          frame_done_event,  // 最后一个样点写入后的单周期完成脉冲
    output logic                          overflow_error     // 帧不完整错误锁存，清错成功前持续为高
);

    localparam int unsigned COUNT_WIDTH = (FRAME_LENGTH <= 1) ? 1 : $clog2(FRAME_LENGTH);
    localparam logic [COUNT_WIDTH-1:0] LAST_INDEX = COUNT_WIDTH'(FRAME_LENGTH - 1);

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_CAPTURE,
        STATE_WAIT_CONSUMED,
        STATE_ERROR
    } state_t;

    state_t state;
    logic [COUNT_WIDTH-1:0] write_count;
    logic write_fire;

    initial begin
        assert (DATA_WIDTH > 0)
            else $fatal(1, "DATA_WIDTH 必须大于 0");
        assert (FRAME_LENGTH > 0)
            else $fatal(1, "FRAME_LENGTH 必须大于 0");
    end

    always_comb begin
        // FIFO 端口按位保存补码；无需改变符号或执行数值转换。
        fifo_din      = data_in;
        capture_busy  = (state == STATE_CAPTURE);
        frame_pending = (state == STATE_WAIT_CONSUMED);

        // rst 参与组合门控，保证同步复位有效期间不会在复位沿前出现写请求。
        write_fire = !rst
                  && (state == STATE_CAPTURE)
                  && in_valid
                  && fifo_ready
                  && !fifo_full
                  && !fifo_wr_rst_busy;
        fifo_wr_en = write_fire;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state            <= STATE_IDLE;
            write_count      <= '0;
            frame_done_event <= 1'b0;
            overflow_error   <= 1'b0;
        end else begin
            // 完成事件默认仅保持一个周期，仅在最后一次成功写入时置位。
            frame_done_event <= 1'b0;

            unique case (state)
                STATE_IDLE: begin
                    write_count <= '0;
                    if (capture_start
                        && fifo_ready
                        && !fifo_full
                        && !fifo_wr_rst_busy) begin
                        state <= STATE_CAPTURE;
                    end
                end

                STATE_CAPTURE: begin
                    // FIFO 复位或 ready 撤销会破坏已写入数据，故无需等待 in_valid。
                    if (fifo_wr_rst_busy || !fifo_ready) begin
                        overflow_error <= 1'b1;
                        state          <= STATE_ERROR;
                    end else if (in_valid && fifo_full) begin
                        overflow_error <= 1'b1;
                        state          <= STATE_ERROR;
                    end else if (write_fire) begin
                        if (write_count == LAST_INDEX) begin
                            write_count      <= '0;
                            frame_done_event <= 1'b1;
                            state            <= STATE_WAIT_CONSUMED;
                        end else begin
                            write_count <= write_count + 1'b1;
                        end
                    end
                end

                STATE_WAIT_CONSUMED: begin
                    if (frame_consumed) begin
                        state <= STATE_IDLE;
                    end
                end

                STATE_ERROR: begin
                    // fifo_ready 表示外部已清空半帧；full 也必须解除后才允许恢复。
                    if (clear_error
                        && fifo_ready
                        && !fifo_full
                        && !fifo_wr_rst_busy) begin
                        overflow_error <= 1'b0;
                        write_count    <= '0;
                        state          <= STATE_IDLE;
                    end
                end

                default: begin
                    // 非法状态按帧损坏处理，禁止静默回到正常流程。
                    state          <= STATE_ERROR;
                    write_count    <= '0;
                    overflow_error <= 1'b1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
