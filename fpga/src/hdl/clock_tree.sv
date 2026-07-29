`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：clock_tree
//
// 主要功能：
//   使用 7 系列 FPGA 的 MMCM 专用时钟资源，将板载 50 MHz PL 时钟转换为
//   100 MHz 系统时钟、30 MHz ADC 捕获时钟和与捕获时钟同相的 ADC 驱动时钟，
//   并为两个逻辑时钟域生成复位信号。
//
// 使用方法：
//   1. 将 clk_50m 连接到 Mizar Z7 板载 50 MHz PL 时钟输入。
//   2. 将 rst_n 连接到系统低有效复位源。
//   3. 下游逻辑分别使用对应时钟及 rst_100m、rst_30m。
//
// 连接说明：
//   clk_50m  <- 板载 50 MHz PL 有源晶振，经输入时钟缓冲后的时钟
//   rst_n    <- 系统低有效异步复位源
//   clk_100m -> 100 MHz 系统逻辑时钟域
//   clk_30m  -> ADC 采样及接口时钟域
//   clk_30m_adc -> ADC 接口模块的 clk_drive，仅用于转发到 ADC 引脚
//   rst_100m -> 100 MHz 时钟域内各业务模块的高有效复位
//   rst_30m  -> 30 MHz 时钟域内各 ADC 相关模块的高有效复位
//   locked   -> 顶层状态监测逻辑；业务模块不得将其替代域内复位
//
// 时钟与复位：
//   MMCM 的 VCO 频率为 50 MHz * 18 = 900 MHz；输出分别除以 9 和 30。
//   rst_n 低电平或 MMCM 失锁时，两个域复位异步置位；MMCM 锁定后，复位在
//   对应时钟域连续经过两个上升沿后同步释放。
//
// 输入格式：
//   clk_50m 为占空比约 50% 的连续 50 MHz 时钟；rst_n 为低有效电平信号。
//
// 输出格式：
//   三路时钟均由 BUFG 驱动；rst_100m、rst_30m 高电平有效。
//
// 握手时序：
//   本模块无数据或控制握手。locked 拉高且对应 rst 输出拉低后，下游方可工作。
//
// 参数说明：
//   本模块针对 Mizar Z7 的固定 50 MHz 输入设计，不提供运行时配置参数。
//
// 错误行为：
//   输入复位有效或 MMCM 失锁时，两个域复位立即置位；重新锁定后同步释放。
//
// 使用限制：
//   仅适用于 Xilinx 7 系列器件。顶层约束必须为 clk_50m 建立 20 ns 输入时钟，
//   并按开发板原理图设置时钟输入管脚和 I/O 电平标准。
// ============================================================================

module clock_tree (
    input  wire logic clk_50m,   // 板载 50 MHz PL 输入时钟，连续运行
    input  wire logic rst_n,     // 系统异步复位，低电平有效

    output wire logic clk_100m,  // 100 MHz 全局时钟，MMCM 锁定后供系统逻辑使用
    output wire logic clk_30m,   // 30 MHz 全局时钟，MMCM 锁定后供 ADC 逻辑使用
    output wire logic clk_30m_adc, // 30 MHz ADC 驱动时钟，与 clk_30m 同频同相
    output wire logic rst_100m,  // 100 MHz 域复位，高有效、异步置位同步释放
    output wire logic rst_30m,   // 30 MHz 域复位，高有效、异步置位同步释放
    output wire logic locked     // MMCM 锁定状态，高电平表示输出时钟已稳定
);

    logic clk_fb_mmcm;
    logic clk_fb;
    logic clk_100m_mmcm;
    logic clk_30m_mmcm;
    logic clk_30m_adc_mmcm;
    logic mmcm_locked;
    (* ASYNC_REG = "TRUE" *) logic [1:0] rst_100m_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] rst_30m_sync;

    MMCME2_BASE #(
        .BANDWIDTH       ("OPTIMIZED"),
        .CLKFBOUT_MULT_F (18.0),
        .CLKIN1_PERIOD   (20.0),
        .CLKOUT0_DIVIDE_F(9.0),
        .CLKOUT1_DIVIDE  (30),
        .CLKOUT2_DIVIDE  (30),
        // 同相转发使外部 ADC 时钟在内部捕获沿之后到达管脚，为下一捕获沿
        // 留出完整周期；45° 延后方案在 25 ns 最大 tCO 约束下没有建立裕量。
        .CLKOUT2_PHASE   (0.0),
        .DIVCLK_DIVIDE   (1),
        .STARTUP_WAIT    ("FALSE")
    ) u_mmcm (
        .CLKIN1  (clk_50m),
        .RST     (~rst_n),
        .PWRDWN  (1'b0),
        .CLKFBIN (clk_fb),
        .CLKFBOUT(clk_fb_mmcm),
        .CLKFBOUTB(),
        .CLKOUT0 (clk_100m_mmcm),
        .CLKOUT0B(),
        .CLKOUT1 (clk_30m_mmcm),
        .CLKOUT1B(),
        .CLKOUT2 (clk_30m_adc_mmcm),
        .CLKOUT2B(),
        .CLKOUT3 (),
        .CLKOUT3B(),
        .CLKOUT4 (),
        .CLKOUT5 (),
        .CLKOUT6 (),
        .LOCKED  (mmcm_locked)
    );

    // 反馈时钟也经过全局缓冲，以补偿输出全局时钟网络的插入延迟。
    BUFG u_bufg_feedback (
        .I(clk_fb_mmcm),
        .O(clk_fb)
    );

    BUFG u_bufg_100m (
        .I(clk_100m_mmcm),
        .O(clk_100m)
    );

    BUFG u_bufg_30m (
        .I(clk_30m_mmcm),
        .O(clk_30m)
    );

    BUFG u_bufg_30m_adc (
        .I(clk_30m_adc_mmcm),
        .O(clk_30m_adc)
    );

    // 失锁可立即复位 100 MHz 域，释放只能发生在本域时钟上升沿。
    always_ff @(posedge clk_100m or negedge rst_n or negedge mmcm_locked) begin
        if (!rst_n || !mmcm_locked) begin
            rst_100m_sync <= 2'b11;
        end else begin
            rst_100m_sync <= {rst_100m_sync[0], 1'b0};
        end
    end

    // 失锁可立即复位 30 MHz 域，释放只能发生在本域时钟上升沿。
    always_ff @(posedge clk_30m or negedge rst_n or negedge mmcm_locked) begin
        if (!rst_n || !mmcm_locked) begin
            rst_30m_sync <= 2'b11;
        end else begin
            rst_30m_sync <= {rst_30m_sync[0], 1'b0};
        end
    end

    assign rst_100m = rst_100m_sync[1];
    assign rst_30m  = rst_30m_sync[1];
    assign locked   = mmcm_locked;

endmodule

`default_nettype wire
