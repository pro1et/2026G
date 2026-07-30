`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：hann_window_4096
//
// 主要功能：
//   对一帧4096个16位有符号样点逐点乘以周期型Hann窗。窗系数使用Q1.15格式，
//   前2048点保存在hann_rom_0单口ROM中；中心点n=2048使用常量32767，后半窗
//   通过周期Hann的w[n]=w[4096-n]对称关系读取同一块ROM。
//
// 接口与时序：
//   输入输出均使用valid-ready握手。模块包含同步ROM读取、DSP乘法和Q1.15舍入
//   流水级；当输出被反压时整条流水线冻结，所有数据和帧标志保持不变。窗地址
//   只在sample_valid && sample_ready时推进。
//
// 数据格式：
//   sample_data/window_data为S16；ROM系数为非负Q1.15，范围0～32767。32位乘积
//   执行对称最近值舍入后算术右移15位，恢复为S16。Hann系数不大于1，合法S16
//   输入不会因加窗产生幅值溢出。
//
// 使用限制：
//   工程必须包含16位×2048深度、单拍同步读取、带ena端口的hann_rom_0 IP。
//   输入帧必须恰好4096个成功握手的样点，first/last分别与第0/4095点对齐。
// ============================================================================
module hann_window_4096 (
    input  wire logic               clk,
    input  wire logic               rst,
    input  wire logic               clear_error,

    input  wire logic signed [15:0] sample_data,
    input  wire logic               sample_valid,
    output wire logic               sample_ready,
    input  wire logic               sample_first,
    input  wire logic               sample_last,

    output      logic signed [15:0] window_data,
    output      logic               window_valid,
    input  wire logic               window_ready,
    output      logic               window_first,
    output      logic               window_last,

    output      logic               protocol_error
);

    logic [11:0] sample_index;

    logic [10:0] rom_addr;
    logic        rom_en;
    wire  [15:0] rom_dout;

    logic signed [15:0] sample_d1;
    logic               valid_d1;
    logic               first_d1;
    logic               last_d1;
    logic               center_d1;

    (* use_dsp = "yes" *)
    logic signed [31:0] rounded_product_d2;
    logic               valid_d2;
    logic               first_d2;
    logic               last_d2;

    logic signed [15:0] coefficient;
    logic signed [31:0] scaled_product;

    wire logic pipeline_enable;
    wire logic input_fire;

    assign pipeline_enable = !window_valid || window_ready;
    assign sample_ready    = pipeline_enable;
    assign input_fire      = sample_valid && sample_ready;
    assign rom_en          = input_fire;

    // 周期Hann半窗寻址：0～2047顺序读，2048用常量，2049～4095镜像读。
    always_comb begin
        if (sample_index < 12'd2048) begin
            rom_addr = sample_index[10:0];
        end else if (sample_index == 12'd2048) begin
            rom_addr = 11'd0;
        end else begin
            // 4096需要13位表示；赋给11位地址时保留合法结果1～2047。
            rom_addr = 13'd4096 - sample_index;
        end
    end

    hann_rom_0 u_hann_rom (
        .clka  (clk),
        .ena   (rom_en),
        .addra (rom_addr),
        .douta (rom_dout)
    );

    always_comb begin
        if (center_d1) begin
            coefficient = 16'sd32767;
        end else begin
            coefficient = $signed(rom_dout);
        end
    end

    // 舍入偏置已经在DSP乘加级加入，这里只需恢复Q1.15的小数尺度。
    assign scaled_product = rounded_product_d2 >>> 15;

    always_ff @(posedge clk) begin
        if (rst) begin
            sample_index   <= 12'd0;

            sample_d1      <= 16'sd0;
            valid_d1       <= 1'b0;
            first_d1       <= 1'b0;
            last_d1        <= 1'b0;
            center_d1      <= 1'b0;

            rounded_product_d2 <= 32'sd0;
            valid_d2       <= 1'b0;
            first_d2       <= 1'b0;
            last_d2        <= 1'b0;

            window_data    <= 16'sd0;
            window_valid   <= 1'b0;
            window_first   <= 1'b0;
            window_last    <= 1'b0;

            protocol_error <= 1'b0;
        end else begin
            if (clear_error) begin
                protocol_error <= 1'b0;
            end

            if (pipeline_enable) begin
                // 第三级：乘积舍入并恢复S16，同时提交上一流水级的帧标志。
                window_valid <= valid_d2;
                window_first <= first_d2;
                window_last  <= last_d2;
                if (valid_d2) begin
                    window_data <= scaled_product[15:0];
                end

                // 第二级：把乘法和符号相关舍入偏置合并进同一个DSP48乘加级。
                // 系数非负，因此乘积符号由sample_d1决定；负数加16383用于补偿
                // 算术右移的向负无穷取整，非负数加16384。
                valid_d2 <= valid_d1;
                first_d2 <= first_d1;
                last_d2  <= last_d1;
                if (valid_d1) begin
                    if (sample_d1[15]) begin
                        rounded_product_d2 <=
                            (sample_d1 * coefficient) + 32'sd16383;
                    end else begin
                        rounded_product_d2 <=
                            (sample_d1 * coefficient) + 32'sd16384;
                    end
                end

                // 第一级：提交ROM地址的同时保存输入样点和控制信息。
                valid_d1  <= input_fire;
                first_d1  <= sample_first;
                last_d1   <= sample_last;
                center_d1 <= (sample_index == 12'd2048);
                if (input_fire) begin
                    sample_d1 <= sample_data;
                end
            end

            // 窗地址和帧检查只由成功的输入握手推进。
            if (input_fire) begin
                if (sample_first != (sample_index == 12'd0)) begin
                    protocol_error <= 1'b1;
                end
                if (sample_last != (sample_index == 12'd4095)) begin
                    protocol_error <= 1'b1;
                end

                if (sample_index == 12'd4095) begin
                    sample_index <= 12'd0;
                end else begin
                    sample_index <= sample_index + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
