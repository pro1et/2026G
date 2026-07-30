`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：clock_tree
//
// 主要功能：
//   封装工程中的 clk_wiz_0 Clocking Wizard IP，将板载 50 MHz PL 时钟转换为
//   32 MHz ADC 时钟和 100 MHz 系统时钟，并为两个逻辑时钟域生成独立的复位
//   信号。clk_wiz_0 的 clk_out1 为 32 MHz，clk_out2 为 100 MHz。
//
// 使用方法：
//   1. 将 clk_50m 连接到 Mizar Z7 板载 50 MHz PL 时钟输入。
//   2. 将 rst_n 连接到系统低有效复位源。
//   3. ADC 相关逻辑使用 clk_32m 和 rst_32m。
//   4. 其他处理模块使用 clk_100m 和 rst_100m。
//   5. adc_capture 的 clk 和 clk_drive 均连接 clk_32m；ADC 管脚时钟仍由
//      adc_capture 内部的 ODDR 转发，不直接连接 Clocking Wizard 输出。
//
// 连接说明：
//   clk_50m     <- 板载 50 MHz PL 有源晶振输入管脚
//   rst_n       <- 系统低有效异步复位源
//   clk_100m    -> 100 MHz 系统逻辑时钟域
//   clk_32m     -> ADC 采样、接口及 FIFO 写时钟域
//   clk_32m_adc -> clk_32m 的同网别名，连接 adc_capture 的 clk_drive
//   rst_100m    -> 100 MHz 时钟域内各业务模块的高有效复位
//   rst_32m     -> 32 MHz 时钟域内各 ADC 相关模块的高有效复位
//   locked      -> 顶层状态监测逻辑；业务模块不得将其替代域内复位
//
// 时钟与复位：
//   clk_wiz_0 内部使用 MMCM 和 BUFG 产生两路全局时钟。本模块不再自行实例化
//   MMCM 或 BUFG。rst_n 低电平时复位 Clocking Wizard；rst_n 低电平或 IP
//   失锁时，两个域复位异步置位。IP 重新锁定后，复位在对应时钟域连续经过
//   两个上升沿后同步释放。
//
// 输入格式：
//   clk_50m 为占空比约 50% 的连续 50 MHz 时钟；rst_n 为低有效电平信号。
//
// 输出格式：
//   clk_32m 和 clk_100m 均已在 clk_wiz_0 内经过 BUFG。clk_32m_adc 与
//   clk_32m 是同一时钟网络的别名，不占用额外 MMCM 输出或 BUFG。
//   rst_100m、rst_32m 均为高电平有效。
//
// 握手时序：
//   本模块无数据或控制握手。locked 拉高且对应 rst 输出拉低后，下游方可工作。
//
// 参数说明：
//   本模块无参数。clk_wiz_0 必须配置为 50 MHz 输入、32 MHz clk_out1、
//   100 MHz clk_out2、active-high reset，并启用 locked 输出。
//
// 错误行为：
//   输入复位有效或 clk_wiz_0 失锁时，两个域复位立即置位；重新锁定后同步释放。
//
// 使用限制：
//   工程中必须包含名为 clk_wiz_0 的 Clocking Wizard IP。顶层约束必须为
//   clk_50m 建立 20 ns 输入时钟，并按开发板原理图设置输入管脚和 I/O 标准。
// ============================================================================

module clock_tree (
    input  wire logic clk_50m,     // 板载 50 MHz PL 输入时钟，连接 clk_wiz_0.clk_in1
    input  wire logic rst_n,       // 系统异步复位，低电平有效

    output wire logic clk_100m,    // clk_wiz_0.clk_out2，100 MHz 系统逻辑时钟
    output wire logic clk_32m,     // clk_wiz_0.clk_out1，32 MHz ADC 逻辑时钟
    output wire logic clk_32m_adc, // clk_32m 同网别名，连接 adc_capture.clk_drive
    output wire logic rst_100m,    // 100 MHz 域复位，高有效、异步置位同步释放
    output wire logic rst_32m,     // 32 MHz 域复位，高有效、异步置位同步释放
    output wire logic locked       // Clocking Wizard 锁定状态，高电平表示输出稳定
);

    logic clk_wiz_locked;
    logic clk_wiz_reset;
    logic domain_reset_async;

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] rst_100m_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] rst_32m_sync;

    // 生成的 Clocking Wizard 已在内部完成输入缓冲、MMCM 反馈和输出 BUFG。
    clk_wiz_0 u_clk_wiz (
        .clk_out1(clk_32m),
        .clk_out2(clk_100m),
        .reset   (clk_wiz_reset),
        .locked  (clk_wiz_locked),
        .clk_in1 (clk_50m)
    );

    assign clk_wiz_reset      = ~rst_n;
    assign domain_reset_async = ~rst_n | ~clk_wiz_locked;
    assign clk_32m_adc        = clk_32m;
    assign locked             = clk_wiz_locked;

    // 失锁可立即复位 100 MHz 域，释放只能发生在本域时钟上升沿。
    always_ff @(posedge clk_100m or posedge domain_reset_async) begin
        if (domain_reset_async) begin
            rst_100m_sync <= 2'b11;
        end else begin
            rst_100m_sync <= {rst_100m_sync[0], 1'b0};
        end
    end

    // 失锁可立即复位 32 MHz 域，释放只能发生在本域时钟上升沿。
    always_ff @(posedge clk_32m or posedge domain_reset_async) begin
        if (domain_reset_async) begin
            rst_32m_sync <= 2'b11;
        end else begin
            rst_32m_sync <= {rst_32m_sync[0], 1'b0};
        end
    end

    assign rst_100m = rst_100m_sync[1];
    assign rst_32m  = rst_32m_sync[1];

endmodule

`default_nettype wire
