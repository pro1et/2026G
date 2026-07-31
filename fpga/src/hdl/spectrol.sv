`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：spectrol
//
// 当前版本职责：
//   接收power_spectrum_calculator产生的一帧2048点U32功率谱，并按power_bin
//   写入外部频谱BRAM。基频检测、能量计算和BRAM读取仲裁将在后续版本中加入。
//
// 接口约定：
//   1. start仅在空闲时采样，用于打开一帧写入窗口；
//   2. power_valid与power_ready同时为1时接收一个功率点；
//   3. 合法帧必须严格按bin 0～2047输入，first/last分别对齐bin 0/2047；
//   4. 每次合法握手产生一拍BRAM写使能，BRAM使用11位字地址；
//   5. bin 2047成功写入后产生一拍frame_done，并返回空闲状态；
//   6. 协议错误会中止当前帧并置位sticky protocol_error。
// ============================================================================
module spectrol #(
    parameter int unsigned POWER_WIDTH = 32
) (
    input  wire logic                         clk,
    input  wire logic                         rst,
    input  wire logic                         clear_error,

    // 帧控制
    input  wire logic                         start,
    output wire logic                         busy,
    output      logic                         frame_done,
    output      logic                         protocol_error,

    // 功率谱输入流
    input  wire logic [POWER_WIDTH-1:0]       power_data,
    input  wire logic [10:0]                  power_bin,
    input  wire logic                         power_valid,
    output wire logic                         power_ready,
    input  wire logic                         power_first,
    input  wire logic                         power_last,

    // 频谱BRAM写端口：地址为32位字地址，而不是AXI字节地址
    output wire logic                         spectrum_bram_en,
    output wire logic                         spectrum_bram_we,
    output wire logic [10:0]                  spectrum_bram_addr,
    output wire logic [POWER_WIDTH-1:0]       spectrum_bram_din
);

    typedef enum logic {
        STATE_IDLE,
        STATE_WRITE
    } state_t;

    state_t state;
    logic [10:0] expected_bin;

    wire logic input_fire;
    wire logic input_protocol_ok;

    initial begin
        assert (POWER_WIDTH == 32)
            else $fatal(1, "spectrol supports POWER_WIDTH=32 only");
    end

    assign busy        = (state == STATE_WRITE);
    assign power_ready = (state == STATE_WRITE);
    assign input_fire  = power_valid && power_ready;

    assign input_protocol_ok =
        (power_bin == expected_bin) &&
        (power_first == (expected_bin == 11'd0)) &&
        (power_last == (expected_bin == 11'd2047));

    // BRAM只接收协议正确且已经完成valid-ready握手的数据。
    assign spectrum_bram_en   = input_fire && input_protocol_ok;
    assign spectrum_bram_we   = input_fire && input_protocol_ok;
    assign spectrum_bram_addr = power_bin;
    assign spectrum_bram_din  = power_data;

    always_ff @(posedge clk) begin
        if (rst) begin
            state          <= STATE_IDLE;
            expected_bin   <= 11'd0;
            frame_done     <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            frame_done <= 1'b0;

            if (clear_error) begin
                protocol_error <= 1'b0;
            end

            case (state)
                STATE_IDLE: begin
                    expected_bin <= 11'd0;
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
                            expected_bin <= 11'd0;
                            frame_done   <= 1'b1;
                            state        <= STATE_IDLE;
                        end else begin
                            expected_bin <= expected_bin + 1'b1;
                        end
                    end
                end

                default: begin
                    state          <= STATE_IDLE;
                    expected_bin   <= 11'd0;
                    protocol_error <= 1'b1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
