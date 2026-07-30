`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：fifo_ctrl
//
// 主要功能：
//   在异步 FIFO 的读时钟域内接收完整帧通知，把 FWFT FIFO 中固定数量的 16 位
//   有符号样点通过 valid-ready 接口送入 FIR，并产生帧首、帧尾和 FIFO 帧消费
//   完成事件。本模块不包含 CDC、FIFO 写控制或 FIR 运算逻辑。
//
// 使用方法：
//   1. 将 clk、rst 连接到 FIFO 读端和 FIR 所在的 100 MHz 时钟域。
//   2. 将 frame_ready_event 连接到正向 af_cdc 的目标域单周期事件输出。
//   3. 将 FIFO 配置为 16 位、深度不小于 FRAME_SIZE、FWFT 读模式，并连接读端口。
//   4. 将 fir_* 接口连接到支持 valid-ready 和帧首尾语义的 FIR 输入端。
//   5. 将 fifo_frame_done 连接到反向 af_cdc 的源域事件输入。
//
// 连接说明：
//   clk                  <- clock_tree 输出的 FIFO/FIR 读域时钟
//   rst                  <- clk 域高有效同步复位
//   frame_ready_event    <- 正向 af_cdc 的 100 MHz 域单周期事件输出
//   fifo_dout            <- FWFT 异步 FIFO 的 dout
//   fifo_empty           <- FWFT 异步 FIFO 的 empty
//   fifo_rd_rst_busy     <- FWFT 异步 FIFO 的 rd_rst_busy
//   fifo_rd_en           -> FWFT 异步 FIFO 的 rd_en
//   fir_data/fir_valid   -> FIR 输入数据和有效信号
//   fir_ready            <- FIR 输入就绪信号
//   fir_first/fir_last   -> FIR 输入帧边界信号
//   fir_frame_done       <- FIR 最后一个输出产生后的本域单周期事件
//   fifo_frame_done      -> 反向 af_cdc 的源域单周期事件输入
//
// 时钟与复位：
//   所有端口均属于 clk 域，跨时钟事件必须在模块外通过 af_cdc 处理。rst 为高电平
//   有效同步复位。fifo_rd_rst_busy 为高时禁止开始或继续读取 FIFO。
//
// 输入格式：
//   fifo_dout 为 DATA_WIDTH 位二进制补码位模式。FIFO 端口本身无 signed 语义。
//   frame_ready_event、fir_frame_done 均必须是 clk 域单周期事件。
//
// 输出格式：
//   fir_data 显式恢复为 DATA_WIDTH 位有符号二进制补码，不缩放、不舍入、不截位。
//   fir_first 和 fir_last 只在 fir_valid 为高时有效，并随数据保持到握手完成。
//
// 握手时序：
//   transfer_fire = fir_valid && fir_ready。仅在 transfer_fire 成立的同一上升沿
//   拉高 fifo_rd_en、消费当前 FWFT 数据并更新索引。反压期间 fifo_rd_en 为低，
//   fir_data、fir_first、fir_last 和 transfer_index 保持稳定。
//
// 参数说明：
//   DATA_WIDTH 为 FIFO/FIR 数据位宽，必须大于 0，默认 16 位。
//   FRAME_SIZE 为每帧样点数，必须大于 0，默认 65536 点。
//
// 错误行为：
//   传输未完成时 FIFO 变空或读端进入复位忙，锁存 underflow_error 并进入 ERROR。
//   已有一帧等待处理或正在传输时再次收到帧事件，锁存 protocol_error 并进入
//   ERROR。ERROR 状态停止 FIFO 和 FIR 输入，错误仅通过 rst 清除。
//
// 使用限制：
//   FIFO 必须使用 FWFT 模式；Standard FIFO 的读延迟与本模块时序不兼容。
//   单 FIFO 最多保存一帧尚未送入 FIR 的数据。fir_frame_done 应在最后一个输入被
//   接收的同周期或之后产生。峰值吞吐率为每个 clk 周期一个样点。
// ============================================================================

module fifo_ctrl #(
    parameter int unsigned DATA_WIDTH = 16,    // 数据位宽，单位为位，必须大于 0
    parameter int unsigned FRAME_SIZE = 65536  // 每帧样点数，单位为点，必须大于 0
) (
    input  wire logic                    clk,               // FIFO/FIR 读时钟域工作时钟
    input  wire logic                    rst,               // 高电平有效同步复位

    input  wire logic                    frame_ready_event, // 完整帧已写入的本域单周期事件

    input  wire logic [DATA_WIDTH-1:0]   fifo_dout,         // FWFT FIFO 当前输出位模式，empty 为低时有效
    input  wire logic                    fifo_empty,        // FIFO 读域空标志，高电平表示无有效 dout
    input  wire logic                    fifo_rd_rst_busy,  // FIFO 读端复位忙，高电平时禁止读取
    output      logic                    fifo_rd_en,        // FIFO 读使能，与 FIR 输入握手同周期有效

    output      logic signed [DATA_WIDTH-1:0] fir_data,    // FIR 有符号二进制补码输入数据
    output      logic                    fir_valid,         // FIR 输入有效，反压期间保持为高
    input  wire logic                    fir_ready,         // FIR 输入就绪，高电平允许本周期接收
    output      logic                    fir_first,         // 当前数据为帧首，随有效数据保持到握手
    output      logic                    fir_last,          // 当前数据为帧尾，随有效数据保持到握手

    input  wire logic                    fir_frame_done,    // FIR 当前帧输出完成的本域单周期事件

    output      logic                    transfer_busy,     // 正在把 FIFO 帧送入 FIR 的状态电平
    output      logic                    fifo_frame_done,   // 最后一个输入握手完成后的单周期事件
    output      logic                    underflow_error,   // FIFO 数据不足或读端异常的粘滞错误
    output      logic                    protocol_error,    // 帧事件顺序异常的粘滞错误
    output      logic [((FRAME_SIZE <= 1) ? 1 : $clog2(FRAME_SIZE))-1:0]
                                            transfer_index  // 当前待发送样点索引，范围 0 到 FRAME_SIZE-1
);

    localparam int unsigned INDEX_WIDTH = (FRAME_SIZE <= 1) ? 1 : $clog2(FRAME_SIZE);
    localparam logic [INDEX_WIDTH-1:0] LAST_INDEX = INDEX_WIDTH'(FRAME_SIZE - 1);

    typedef enum logic [2:0] {
        STATE_WAIT_FRAME,
        STATE_WAIT_FIFO,
        STATE_TRANSFER,
        STATE_WAIT_FIR_DONE,
        STATE_ERROR
    } state_t;

    state_t state;
    logic frame_pending;
    logic transfer_fire;

    initial begin
        assert (DATA_WIDTH > 0)
            else $fatal(1, "DATA_WIDTH 必须大于 0");
        assert (FRAME_SIZE > 0)
            else $fatal(1, "FRAME_SIZE 必须大于 0");
    end

    always_comb begin
        // FIFO 只保存补码位模式，此处显式恢复 signed 语义供 FIR 运算使用。
        fir_data      = $signed(fifo_dout);
        transfer_busy = (state == STATE_TRANSFER);

        fir_valid = !rst
                 && (state == STATE_TRANSFER)
                 && !fifo_empty
                 && !fifo_rd_rst_busy;
        fir_first = fir_valid && (transfer_index == '0);
        fir_last  = fir_valid && (transfer_index == LAST_INDEX);

        transfer_fire = fir_valid && fir_ready;
        fifo_rd_en     = transfer_fire;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state            <= STATE_WAIT_FRAME;
            frame_pending    <= 1'b0;
            transfer_index   <= '0;
            fifo_frame_done  <= 1'b0;
            underflow_error  <= 1'b0;
            protocol_error   <= 1'b0;
        end else begin
            // 完成事件默认清零，只在最后一个样点真正握手时保持一个周期。
            fifo_frame_done <= 1'b0;

            unique case (state)
                STATE_WAIT_FRAME: begin
                    transfer_index <= '0;
                    if (frame_ready_event) begin
                        frame_pending <= 1'b1;
                        state         <= STATE_WAIT_FIFO;
                    end
                end

                STATE_WAIT_FIFO: begin
                    transfer_index <= '0;
                    if (frame_ready_event) begin
                        // 已有完整帧等待处理时不允许再报告一帧。
                        frame_pending  <= 1'b0;
                        protocol_error <= 1'b1;
                        state          <= STATE_ERROR;
                    end else if (frame_pending
                                 && !fifo_empty
                                 && !fifo_rd_rst_busy) begin
                        frame_pending <= 1'b0;
                        state         <= STATE_TRANSFER;
                    end
                end

                STATE_TRANSFER: begin
                    if (frame_ready_event) begin
                        protocol_error <= 1'b1;
                        state          <= STATE_ERROR;
                    end else if (fifo_rd_rst_busy) begin
                        underflow_error <= 1'b1;
                        state           <= STATE_ERROR;
                    end else if (transfer_fire) begin
                        if (transfer_index == LAST_INDEX) begin
                            transfer_index  <= '0;
                            fifo_frame_done <= 1'b1;

                            // 支持零额外尾延迟的 FIR；通常 fir_frame_done 会更晚到达。
                            if (fir_frame_done) begin
                                state <= STATE_WAIT_FRAME;
                            end else begin
                                state <= STATE_WAIT_FIR_DONE;
                            end
                        end else begin
                            transfer_index <= transfer_index + 1'b1;
                        end
                    end else if (fifo_empty) begin
                        // 最后一拍优先在上面的 transfer_fire 分支处理，避免正常空误报。
                        underflow_error <= 1'b1;
                        state           <= STATE_ERROR;
                    end
                end

                STATE_WAIT_FIR_DONE: begin
                    transfer_index <= '0;

                    if (frame_ready_event && frame_pending) begin
                        frame_pending  <= 1'b0;
                        protocol_error <= 1'b1;
                        state          <= STATE_ERROR;
                    end else begin
                        if (frame_ready_event) begin
                            frame_pending <= 1'b1;
                        end

                        if (fir_frame_done) begin
                            // 同周期到达的新帧也必须被保留并进入 FIFO 等待状态。
                            if (frame_pending || frame_ready_event) begin
                                state <= STATE_WAIT_FIFO;
                            end else begin
                                state <= STATE_WAIT_FRAME;
                            end
                        end
                    end
                end

                STATE_ERROR: begin
                    frame_pending  <= 1'b0;
                    transfer_index <= '0;
                end

                default: begin
                    frame_pending  <= 1'b0;
                    transfer_index <= '0;
                    protocol_error <= 1'b1;
                    state          <= STATE_ERROR;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
