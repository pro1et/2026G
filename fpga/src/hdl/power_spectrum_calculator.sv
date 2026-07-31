`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：power_spectrum_calculator
//
// 主要功能：
//   接收fft_4096_wrapper输出的4096点自然顺序FFT结果。实部和虚部均为S20，
//   原始功率按Re^2+Im^2计算为U40，再执行加128、右移8位的四舍五入，输出
//   U32功率。只输出bin 0～2047；bin 2048～4095仍被正常消费但不产生功率。
//
// 流水线与握手：
//   第一级计算两个20×20平方并保存bin；第二级完成平方和、缩放、饱和并寄存
//   输出。输入输出均使用valid-ready握手。当功率输出被反压时，两级流水线
//   整体冻结，数据、bin及帧标志保持不变。无反压时吞吐率为每时钟一个FFT点。
//
// 完成信号：
//   power_frame_done在bin 2047功率成功输出时脉冲；
//   fft_frame_done在完整FFT的bin 4095成功输入时脉冲。
//
// 使用限制：
//   第一版固定支持S20 FFT分量、U40原始功率、右移8位和U32输出。FFT输入必须
//   为自然顺序0～4095，first/last分别与bin 0/4095对齐。
// ============================================================================
module power_spectrum_calculator #(
    parameter int unsigned FFT_COMPONENT_WIDTH = 20,
    parameter int unsigned RAW_POWER_WIDTH      = 40,
    parameter int unsigned POWER_WIDTH          = 32,
    parameter int unsigned POWER_SHIFT          = 8
) (
    input  wire logic                                  clk,
    input  wire logic                                  rst,
    input  wire logic                                  clear_error,

    // FFT输入流：完整4096点自然顺序结果
    input  wire logic signed [FFT_COMPONENT_WIDTH-1:0] fft_re,
    input  wire logic signed [FFT_COMPONENT_WIDTH-1:0] fft_im,
    input  wire logic        [11:0]                    fft_bin,
    input  wire logic                                  fft_valid,
    output wire logic                                  fft_ready,
    input  wire logic                                  fft_first,
    input  wire logic                                  fft_last,

    // 正频率功率谱输出流：bin 0～2047
    output      logic        [POWER_WIDTH-1:0]          power_data,
    output      logic        [10:0]                    power_bin,
    output      logic                                  power_valid,
    input  wire logic                                  power_ready,
    output      logic                                  power_first,
    output      logic                                  power_last,

    // 完成与诊断
    output      logic                                  fft_frame_done,
    output      logic                                  power_frame_done,
    output      logic                                  protocol_error
);

    logic [11:0] expected_fft_bin;

    (* use_dsp = "yes" *)
    wire logic signed [RAW_POWER_WIDTH-1:0] re_product;
    (* use_dsp = "yes" *)
    wire logic signed [RAW_POWER_WIDTH-1:0] im_product;

    logic [RAW_POWER_WIDTH-1:0] re_square_d1;
    logic [RAW_POWER_WIDTH-1:0] im_square_d1;
    logic [10:0]                power_bin_d1;
    logic                       square_valid_d1;
    logic                       power_first_d1;
    logic                       power_last_d1;

    logic [RAW_POWER_WIDTH:0] raw_power_ext;
    logic [RAW_POWER_WIDTH:0] rounded_power_ext;
    logic [RAW_POWER_WIDTH:0] scaled_power_ext;

    wire logic pipeline_enable;
    wire logic input_fire;
    wire logic output_fire;
    wire logic positive_frequency;
    wire logic scaled_overflow;

    initial begin
        assert (FFT_COMPONENT_WIDTH == 20)
            else $fatal(1, "power_spectrum_calculator supports FFT_COMPONENT_WIDTH=20 only");
        assert (RAW_POWER_WIDTH == 40)
            else $fatal(1, "power_spectrum_calculator supports RAW_POWER_WIDTH=40 only");
        assert (POWER_WIDTH == 32)
            else $fatal(1, "power_spectrum_calculator supports POWER_WIDTH=32 only");
        assert (POWER_SHIFT == 8)
            else $fatal(1, "power_spectrum_calculator supports POWER_SHIFT=8 only");
    end

    assign re_product = fft_re * fft_re;
    assign im_product = fft_im * fft_im;

    assign pipeline_enable   = !power_valid || power_ready;
    assign fft_ready         = pipeline_enable;
    assign input_fire        = fft_valid && fft_ready;
    assign output_fire       = power_valid && power_ready;
    assign positive_frequency = (fft_bin <= 12'd2047);

    // 两个S20平方的位模式均为非负U40，加法前显式补0，避免符号扩展。
    always_comb begin
        raw_power_ext =
            {1'b0, re_square_d1} +
            {1'b0, im_square_d1};
        rounded_power_ext = raw_power_ext + 41'd128;
        scaled_power_ext  = rounded_power_ext >> POWER_SHIFT;
    end

    assign scaled_overflow =
        |scaled_power_ext[RAW_POWER_WIDTH:POWER_WIDTH];

    always_ff @(posedge clk) begin
        if (rst) begin
            expected_fft_bin <= 12'd0;

            re_square_d1     <= '0;
            im_square_d1     <= '0;
            power_bin_d1     <= 11'd0;
            square_valid_d1  <= 1'b0;
            power_first_d1   <= 1'b0;
            power_last_d1    <= 1'b0;

            power_data       <= '0;
            power_bin        <= 11'd0;
            power_valid      <= 1'b0;
            power_first      <= 1'b0;
            power_last       <= 1'b0;

            fft_frame_done   <= 1'b0;
            power_frame_done <= 1'b0;
            protocol_error   <= 1'b0;
        end else begin
            fft_frame_done   <= 1'b0;
            power_frame_done <= output_fire && power_last;

            if (clear_error) begin
                protocol_error <= 1'b0;
            end

            if (pipeline_enable) begin
                // 第二级：平方和、四舍五入、固定右移和U32防御性饱和。
                power_valid <= square_valid_d1;
                power_bin   <= power_bin_d1;
                power_first <= power_first_d1;
                power_last  <= power_last_d1;

                if (square_valid_d1) begin
                    if (scaled_overflow) begin
                        power_data <= {POWER_WIDTH{1'b1}};
                    end else begin
                        power_data <= scaled_power_ext[POWER_WIDTH-1:0];
                    end

                    // 合法S20输入的平方和不应使用第40位。
                    if (raw_power_ext[RAW_POWER_WIDTH]) begin
                        protocol_error <= 1'b1;
                    end
                end

                // 第一级：正频率点进入乘法流水线，负频率点形成空泡。
                square_valid_d1 <= input_fire && positive_frequency;
                power_bin_d1    <= fft_bin[10:0];
                power_first_d1  <= (fft_bin == 12'd0);
                power_last_d1   <= (fft_bin == 12'd2047);

                if (input_fire && positive_frequency) begin
                    re_square_d1 <= $unsigned(re_product);
                    im_square_d1 <= $unsigned(im_product);
                end
            end

            // 完整FFT输入协议只在成功握手时检查和推进。
            if (input_fire) begin
                if (fft_bin != expected_fft_bin) begin
                    protocol_error <= 1'b1;
                end
                if (fft_first != (expected_fft_bin == 12'd0)) begin
                    protocol_error <= 1'b1;
                end
                if (fft_last != (expected_fft_bin == 12'd4095)) begin
                    protocol_error <= 1'b1;
                end

                fft_frame_done <= fft_last;

                if (expected_fft_bin == 12'd4095) begin
                    expected_fft_bin <= 12'd0;
                end else begin
                    expected_fft_bin <= expected_fft_bin + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
