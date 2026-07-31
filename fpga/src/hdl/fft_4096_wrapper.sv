`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：fft_4096_wrapper
//
// 主要功能：
//   封装固定配置的xfft_0 IP。输入是一帧4096点S16实信号，虚部固定为0；输出
//   为自然顺序的FFT结果。xfft_0采用Unscaled定点运算，S16输入对应S29实部和
//   虚部；本模块将S29结果右移9位，执行收敛舍入并饱和为S20，供功率谱模块
//   计算Re^2+Im^2。
//
// 配置与时序：
//   复位释放后自动向FFT配置通道提交8'h01，选择前向FFT。配置成功握手后等待
//   4个完整时钟周期，再允许Hann数据进入FFT。输入输出均采用valid-ready握手，
//   所有帧计数器只在对应握手成功时推进。
//
// IP配置约束：
//   xfft_0必须为4096点、单通道、Pipelined Streaming I/O、Fixed Point、
//   Unscaled、S16输入、S29输出、Natural Order、Non-Realtime，并开启ARESETn。
//   当前IP没有XK_INDEX端口，因此本模块依据自然顺序输出自行产生fft_bin。
//
// 错误处理：
//   protocol_error是粘滞错误，记录输入first/last位置错误、FFT输出TLAST位置
//   错误以及FFT IP报告的TLAST错误。channel_halt是独立的粘滞诊断状态，记录
//   AXI数据或状态通道发生过停顿；Non-Realtime模式允许正常反压，因此停顿本身
//   不直接判定当前帧无效。
// ============================================================================
module fft_4096_wrapper (
    input  wire logic                clk,
    input  wire logic                rst,
    input  wire logic                clear_error,

    // Hann窗输出：4096点S16实数流
    input  wire logic signed [15:0]  window_data,
    input  wire logic                window_valid,
    output wire logic                window_ready,
    input  wire logic                window_first,
    input  wire logic                window_last,

    // FFT量化输出：自然顺序，S20实部和虚部
    output wire logic signed [19:0]  fft_re,
    output wire logic signed [19:0]  fft_im,
    output wire logic        [11:0]  fft_bin,
    output wire logic                fft_valid,
    input  wire logic                fft_ready,
    output wire logic                fft_first,
    output wire logic                fft_last,

    // 状态与诊断
    output wire logic                config_done,
    output      logic                protocol_error,
    output      logic                channel_halt
);

    localparam logic [7:0] FFT_FORWARD_CONFIG = 8'h01;
    localparam int unsigned CONFIG_GUARD_CYCLES = 4;

    logic        config_accepted;
    logic [2:0]  config_guard_count;
    logic        data_enabled;
    logic [11:0] input_index;
    logic [11:0] output_index;

    wire logic [7:0]  fft_s_axis_config_tdata;
    wire logic        fft_s_axis_config_tvalid;
    wire logic        fft_s_axis_config_tready;

    wire logic [31:0] fft_s_axis_data_tdata;
    wire logic        fft_s_axis_data_tvalid;
    wire logic        fft_s_axis_data_tready;
    wire logic        fft_s_axis_data_tlast;

    wire logic [63:0] fft_m_axis_data_tdata;
    wire logic        fft_m_axis_data_tvalid;
    wire logic        fft_m_axis_data_tready;
    wire logic        fft_m_axis_data_tlast;

    wire logic event_frame_started;
    wire logic event_tlast_unexpected;
    wire logic event_tlast_missing;
    wire logic event_status_channel_halt;
    wire logic event_data_in_channel_halt;
    wire logic event_data_out_channel_halt;

    wire logic config_fire;
    wire logic input_fire;
    wire logic output_fire;

    wire logic signed [28:0] fft_re_full;
    wire logic signed [28:0] fft_im_full;

    // 将S29除以2^9，采用“最接近偶数”的收敛舍入，并对S20边界饱和。
    function automatic logic signed [19:0] quantize_s29_to_s20 (
        input logic signed [28:0] value
    );
        logic        negative;
        logic [28:0] magnitude;
        logic [19:0] integer_part;
        logic [8:0]  fractional_part;
        logic        round_up;
        logic [20:0] rounded_magnitude;
        begin
            negative = value[28];
            if (negative) begin
                magnitude = (~$unsigned(value)) + 29'd1;
            end else begin
                magnitude = $unsigned(value);
            end

            integer_part   = magnitude[28:9];
            fractional_part = magnitude[8:0];
            round_up = (fractional_part > 9'd256) ||
                       ((fractional_part == 9'd256) && integer_part[0]);
            rounded_magnitude = {1'b0, integer_part} +
                                {{20{1'b0}}, round_up};

            if (negative) begin
                if (rounded_magnitude >= 21'd524288) begin
                    quantize_s29_to_s20 = 20'sh80000;
                end else begin
                    quantize_s29_to_s20 =
                        $signed((~rounded_magnitude[19:0]) + 20'd1);
                end
            end else begin
                if (rounded_magnitude > 21'd524287) begin
                    quantize_s29_to_s20 = 20'sh7FFFF;
                end else begin
                    quantize_s29_to_s20 =
                        $signed(rounded_magnitude[19:0]);
                end
            end
        end
    endfunction

    assign fft_s_axis_config_tdata  = FFT_FORWARD_CONFIG;
    assign fft_s_axis_config_tvalid = !rst && !config_accepted;
    assign config_fire = fft_s_axis_config_tvalid &&
                         fft_s_axis_config_tready;

    assign config_done = data_enabled;

    // AXI FFT输入的低16位为实部，高16位为虚部。
    assign fft_s_axis_data_tdata  = {16'sd0, window_data};
    assign fft_s_axis_data_tvalid = window_valid && data_enabled;
    assign fft_s_axis_data_tlast  = window_last;
    assign window_ready = data_enabled && fft_s_axis_data_tready;
    assign input_fire = window_valid && window_ready;

    // 当前IP为自然顺序且未启用XK_INDEX，输出编号由成功握手计数产生。
    assign fft_m_axis_data_tready = fft_ready;
    assign fft_valid = fft_m_axis_data_tvalid;
    assign output_fire = fft_valid && fft_ready;
    assign fft_bin   = output_index;
    assign fft_first = (output_index == 12'd0);
    assign fft_last  = fft_m_axis_data_tlast;

    // S29分量分别位于两个32位对齐字段的低29位。
    assign fft_re_full = $signed(fft_m_axis_data_tdata[28:0]);
    assign fft_im_full = $signed(fft_m_axis_data_tdata[60:32]);
    assign fft_re = quantize_s29_to_s20(fft_re_full);
    assign fft_im = quantize_s29_to_s20(fft_im_full);

    always_ff @(posedge clk) begin
        if (rst) begin
            config_accepted  <= 1'b0;
            config_guard_count <= 3'd0;
            data_enabled     <= 1'b0;
            input_index      <= 12'd0;
            output_index     <= 12'd0;
            protocol_error   <= 1'b0;
            channel_halt     <= 1'b0;
        end else begin
            if (clear_error) begin
                protocol_error <= 1'b0;
                channel_halt   <= 1'b0;
            end

            if (config_fire) begin
                config_accepted    <= 1'b1;
                config_guard_count <= CONFIG_GUARD_CYCLES[2:0];
            end else if (config_accepted && !data_enabled) begin
                if (config_guard_count > 3'd1) begin
                    config_guard_count <= config_guard_count - 1'b1;
                end else if (config_guard_count == 3'd1) begin
                    config_guard_count <= 3'd0;
                    data_enabled       <= 1'b1;
                end
            end

            if (input_fire) begin
                if (window_first != (input_index == 12'd0)) begin
                    protocol_error <= 1'b1;
                end
                if (window_last != (input_index == 12'd4095)) begin
                    protocol_error <= 1'b1;
                end

                if (input_index == 12'd4095) begin
                    input_index <= 12'd0;
                end else begin
                    input_index <= input_index + 1'b1;
                end
            end

            if (output_fire) begin
                if (fft_m_axis_data_tlast !=
                    (output_index == 12'd4095)) begin
                    protocol_error <= 1'b1;
                end

                if (output_index == 12'd4095) begin
                    output_index <= 12'd0;
                end else begin
                    output_index <= output_index + 1'b1;
                end
            end

            if (event_tlast_unexpected || event_tlast_missing) begin
                protocol_error <= 1'b1;
            end

            if (event_status_channel_halt ||
                event_data_in_channel_halt ||
                event_data_out_channel_halt) begin
                channel_halt <= 1'b1;
            end
        end
    end

    xfft_0 u_xfft_0 (
        .aclk                         (clk),
        .aresetn                      (!rst),

        .s_axis_config_tdata          (fft_s_axis_config_tdata),
        .s_axis_config_tvalid         (fft_s_axis_config_tvalid),
        .s_axis_config_tready         (fft_s_axis_config_tready),

        .s_axis_data_tdata            (fft_s_axis_data_tdata),
        .s_axis_data_tvalid           (fft_s_axis_data_tvalid),
        .s_axis_data_tready           (fft_s_axis_data_tready),
        .s_axis_data_tlast            (fft_s_axis_data_tlast),

        .m_axis_data_tdata            (fft_m_axis_data_tdata),
        .m_axis_data_tvalid           (fft_m_axis_data_tvalid),
        .m_axis_data_tready           (fft_m_axis_data_tready),
        .m_axis_data_tlast            (fft_m_axis_data_tlast),

        .event_frame_started          (event_frame_started),
        .event_tlast_unexpected       (event_tlast_unexpected),
        .event_tlast_missing          (event_tlast_missing),
        .event_status_channel_halt    (event_status_channel_halt),
        .event_data_in_channel_halt   (event_data_in_channel_halt),
        .event_data_out_channel_halt  (event_data_out_channel_halt)
    );

endmodule

`default_nettype wire
