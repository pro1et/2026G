`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：spectrol
//
// 当前版本职责：
//   1. 将一帧2048点U32功率谱写入外部频谱BRAM；
//   2. 写完后启动基频检测模块；
//   3. 为基频检测模块提供带固定延迟封装的BRAM读取服务；
//   4. 等待基频检测结束后产生frame_done。
//   能量计算及其BRAM读取仲裁将在后续版本中加入。
//
// 接口约定：
//   1. start仅在空闲时采样，用于打开一帧写入窗口；
//   2. power_valid与power_ready同时为1时接收一个功率点；
//   3. 合法帧必须严格按bin 0～2047输入，first/last分别对齐bin 0/2047；
//   4. 每次合法握手产生一拍BRAM写使能，BRAM使用11位字地址；
//   5. bin 2047成功写入后产生一拍spectrum_write_done；
//   6. base_start为单拍脉冲，frame_done在base_done之后产生；
//   7. 协议错误会中止当前帧并置位sticky protocol_error。
// ============================================================================
module spectrol #(
    parameter int unsigned POWER_WIDTH     = 32,
    parameter int unsigned BRAM_RD_LATENCY = 2
) (
    input  wire logic                         clk,
    input  wire logic                         rst,
    input  wire logic                         clear_error,

    // 帧控制
    input  wire logic                         start,
    output wire logic                         busy,
    output      logic                         spectrum_write_done,
    output      logic                         frame_done,
    output      logic                         protocol_error,

    // 功率谱输入流
    input  wire logic [POWER_WIDTH-1:0]       power_data,
    input  wire logic [10:0]                  power_bin,
    input  wire logic                         power_valid,
    output wire logic                         power_ready,
    input  wire logic                         power_first,
    input  wire logic                         power_last,

    // 基频检测控制
    output      logic                         base_start,
    input  wire logic                         base_done,
    input  wire logic                         base_valid,

    // 基频检测的频谱读取接口
    input  wire logic                         base_mem_req,
    input  wire logic [10:0]                  base_mem_addr,
    output wire logic                         base_mem_ready,
    output wire logic                         base_mem_rvalid,
    output wire logic [POWER_WIDTH-1:0]       base_mem_rdata,

    // 频谱BRAM物理端口：地址为32位字地址，而不是AXI字节地址
    output wire logic                         spectrum_bram_en,
    output wire logic                         spectrum_bram_we,
    output wire logic [10:0]                  spectrum_bram_addr,
    output wire logic [POWER_WIDTH-1:0]       spectrum_bram_din,
    input  wire logic [POWER_WIDTH-1:0]       spectrum_bram_dout
);

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_WRITE,
        STATE_START_BASE,
        STATE_WAIT_BASE,
        STATE_FRAME_DONE
    } state_t;

    state_t state;
    logic [10:0] expected_bin;
    logic [15:0] base_pending_count;
    logic        base_done_seen;
    logic [BRAM_RD_LATENCY-1:0] base_read_valid_pipe;
    integer read_stage;

    wire logic input_fire;
    wire logic input_protocol_ok;
    wire logic write_fire;
    wire logic base_request_fire;
    logic [15:0] base_pending_count_next;

    initial begin
        assert (POWER_WIDTH == 32)
            else $fatal(1, "spectrol supports POWER_WIDTH=32 only");
        assert (BRAM_RD_LATENCY >= 1)
            else $fatal(1, "BRAM_RD_LATENCY must be at least 1");
    end

    assign busy        = (state != STATE_IDLE);
    assign power_ready = (state == STATE_WRITE);
    assign input_fire  = power_valid && power_ready;

    assign input_protocol_ok =
        (power_bin == expected_bin) &&
        (power_first == (expected_bin == 11'd0)) &&
        (power_last == (expected_bin == 11'd2047));

    assign write_fire = input_fire && input_protocol_ok;

    assign base_mem_ready    = (state == STATE_WAIT_BASE);
    assign base_request_fire = base_mem_req && base_mem_ready;
    assign base_mem_rvalid   = base_read_valid_pipe[BRAM_RD_LATENCY-1];
    assign base_mem_rdata    = spectrum_bram_dout;

    // 写阶段和基频读取阶段分时控制同一个BRAM端口。
    assign spectrum_bram_en =
        (state == STATE_WRITE) ? write_fire :
        (state == STATE_WAIT_BASE) ? base_request_fire :
        1'b0;
    assign spectrum_bram_we =
        (state == STATE_WRITE) ? write_fire : 1'b0;
    assign spectrum_bram_addr =
        (state == STATE_WRITE) ? power_bin :
        (state == STATE_WAIT_BASE) ? base_mem_addr :
        11'd0;
    assign spectrum_bram_din =
        (state == STATE_WRITE) ? power_data : '0;

    always_comb begin
        base_pending_count_next = base_pending_count;
        case ({base_request_fire, base_mem_rvalid})
            2'b10: base_pending_count_next = base_pending_count + 1'b1;
            2'b01: base_pending_count_next = base_pending_count - 1'b1;
            default: base_pending_count_next = base_pending_count;
        endcase
    end

    // 将BRAM的固定读取延迟转换为请求-返回接口上的rvalid。
    always_ff @(posedge clk) begin
        if (rst) begin
            base_read_valid_pipe <= '0;
        end else begin
            base_read_valid_pipe[0] <= base_request_fire;
            for (read_stage = 1; read_stage < BRAM_RD_LATENCY;
                 read_stage = read_stage + 1) begin
                base_read_valid_pipe[read_stage] <=
                    base_read_valid_pipe[read_stage-1];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state               <= STATE_IDLE;
            expected_bin        <= 11'd0;
            base_pending_count  <= 16'd0;
            base_done_seen      <= 1'b0;
            spectrum_write_done <= 1'b0;
            base_start          <= 1'b0;
            frame_done          <= 1'b0;
            protocol_error      <= 1'b0;
        end else begin
            spectrum_write_done <= 1'b0;
            base_start          <= 1'b0;
            frame_done          <= 1'b0;

            if (clear_error) begin
                protocol_error <= 1'b0;
            end

            case (state)
                STATE_IDLE: begin
                    expected_bin       <= 11'd0;
                    base_pending_count <= 16'd0;
                    base_done_seen     <= 1'b0;
                    if (start) begin
                        state <= STATE_WRITE;
                    end
                end

                STATE_WRITE: begin
                    // 工作期间重复start属于上层控制协议错误，但不打断当前帧。
                    if (start) begin
                        protocol_error <= 1'b1;
                    end

                    if (input_fire) begin
                        if (!input_protocol_ok) begin
                            protocol_error <= 1'b1;
                            expected_bin   <= 11'd0;
                            state          <= STATE_IDLE;
                        end else if (expected_bin == 11'd2047) begin
                            expected_bin        <= 11'd0;
                            spectrum_write_done <= 1'b1;
                            state               <= STATE_START_BASE;
                        end else begin
                            expected_bin <= expected_bin + 1'b1;
                        end
                    end
                end

                STATE_START_BASE: begin
                    base_start         <= 1'b1;
                    base_done_seen     <= 1'b0;
                    base_pending_count <= 16'd0;
                    state              <= STATE_WAIT_BASE;
                end

                STATE_WAIT_BASE: begin
                    base_pending_count <= base_pending_count_next;

                    if (start) begin
                        protocol_error <= 1'b1;
                    end

                    if (base_done) begin
                        base_done_seen <= 1'b1;
                    end

                    if ((base_done || base_done_seen) &&
                        (base_pending_count_next == 16'd0)) begin
                        base_done_seen <= 1'b0;
                        state          <= STATE_FRAME_DONE;
                    end
                end

                STATE_FRAME_DONE: begin
                    // 当前阶段无能量计算，因此基频检测结束即为整帧处理结束。
                    frame_done <= 1'b1;
                    state      <= STATE_IDLE;
                end

                default: begin
                    state               <= STATE_IDLE;
                    expected_bin        <= 11'd0;
                    base_pending_count  <= 16'd0;
                    base_done_seen      <= 1'b0;
                    protocol_error      <= 1'b1;
                end
            endcase
        end
    end

    // 当前版本只等待base_done；base_valid由基频检测器直接送往后级。
    wire logic unused_base_valid = base_valid;

endmodule

`default_nettype wire
