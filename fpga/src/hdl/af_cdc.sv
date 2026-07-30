`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：af_cdc
//
// 主要功能：
//   使用请求/确认 toggle 握手，把源时钟域中的单周期事件可靠地转换为目标时钟
//   域中的单周期事件。事件在目标时钟暂停或两侧频率差异较大时不会因脉宽不足而
//   丢失。本模块只传递事件，不传递多比特数据，也不解释事件的业务含义。
//
// 使用方法：
//   1. 将 src_clk、src_rst 和 src_event 连接到事件产生端所在时钟域。
//   2. 仅在 src_busy 为低时提交一个严格单周期的 src_event。
//   3. 将 dst_clk、dst_rst 和 dst_event 连接到事件接收端所在时钟域。
//   4. 两侧复位必须由同一系统复位请求协调产生，并在各自时钟域同步释放。
//
// 连接说明：
//   src_clk            <- 事件产生端工作时钟
//   src_rst            <- src_clk 域高有效同步复位
//   src_event          <- 上游业务模块产生的源域单周期事件
//   src_busy           -> 上游业务模块，指示当前事件尚未完成跨域握手
//   src_protocol_error -> 状态监控，指示上游在忙时重复提交事件
//   dst_clk            <- 事件接收端工作时钟
//   dst_rst            <- dst_clk 域高有效同步复位
//   dst_event          -> 下游业务模块使用的目标域单周期事件
//
// 时钟与复位：
//   src_clk 与 dst_clk 可以异步、同频异相或频率不同。src_rst、dst_rst 均为所属
//   时钟域的高电平有效同步复位。两侧 toggle 复位为零；不支持运行中只复位单侧。
//
// 输入格式：
//   src_event 是单比特控制事件，必须严格持续一个 src_clk 周期。它不携带数值数据。
//
// 输出格式：
//   dst_event 在目标域检测到新请求时拉高，严格持续一个 dst_clk 周期。
//   src_busy 是源域状态电平；src_protocol_error 是保持到 src_rst 的粘滞错误。
//
// 握手时序：
//   源域接收事件后翻转 req_toggle；请求经 SYNC_STAGES 级同步到目标域。目标域检测
//   到变化后产生 dst_event，并用 req_seen 保存已处理值。req_seen 再经同步链返回
//   源域作为确认；确认等于当前请求后 src_busy 自动解除。
//
// 参数说明：
//   SYNC_STAGES 为请求链和确认链的触发器级数，必须大于等于 2，默认 2 级。
//   增加级数可提高亚稳态平均无故障时间，但会增加完整往返握手延迟。
//
// 错误行为：
//   src_busy 为高时再次收到 src_event，不翻转请求、不覆盖当前事件，同时置位
//   src_protocol_error。当前已提交事件仍会继续完成。
//
// 使用限制：
//   本模块一次最多保存一个待传事件，峰值吞吐率受完整往返握手限制。禁止用它
//   逐位传输多比特总线。复位释放期间两个时钟必须运行，且不得提交 src_event。
// ============================================================================

module af_cdc #(
    parameter int unsigned SYNC_STAGES = 2  // 同步链级数，必须大于等于 2
) (
    input  wire logic src_clk,             // 源时钟域工作时钟
    input  wire logic src_rst,             // 源域高电平有效同步复位
    input  wire logic src_event,           // 源域单周期事件，仅在 src_busy 为低时提交
    output      logic src_busy,            // 当前事件正在跨域传输的源域状态电平
    output      logic src_protocol_error,  // 忙时重复事件的源域粘滞错误标志

    input  wire logic dst_clk,             // 目标时钟域工作时钟
    input  wire logic dst_rst,             // 目标域高电平有效同步复位
    output      logic dst_event            // 目标域成功接收事件后的单周期脉冲
);

    logic req_toggle;
    logic req_seen;

    // 属性阻止同步寄存器被抽取为 SRL，并帮助布局和 CDC 分析识别同步链。
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [SYNC_STAGES-1:0] req_sync;

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [SYNC_STAGES-1:0] ack_sync;

    integer req_stage;
    integer ack_stage;

    initial begin
        assert (SYNC_STAGES >= 2)
            else $fatal(1, "SYNC_STAGES 必须大于等于 2");
    end

    // 业务逻辑只比较返回同步链末级，绝不直接使用异步的 req_seen。
    always_comb begin
        src_busy = (req_toggle != ack_sync[SYNC_STAGES-1]);
    end

    // 源域请求寄存器和协议错误检测。
    always_ff @(posedge src_clk) begin
        if (src_rst) begin
            req_toggle        <= 1'b0;
            src_protocol_error <= 1'b0;
        end else if (src_event) begin
            if (!src_busy) begin
                req_toggle <= ~req_toggle;
            end else begin
                // 忙时拒绝新事件，当前 req_toggle 保持不变并继续完成原握手。
                src_protocol_error <= 1'b1;
            end
        end
    end

    // 确认从目标域返回源域；仅第一级直接采样异步信号。
    always_ff @(posedge src_clk) begin
        if (src_rst) begin
            ack_sync <= '0;
        end else begin
            ack_sync[0] <= req_seen;
            for (ack_stage = 1; ack_stage < SYNC_STAGES; ack_stage = ack_stage + 1) begin
                ack_sync[ack_stage] <= ack_sync[ack_stage-1];
            end
        end
    end

    // 请求从源域进入目标域；仅第一级直接采样异步信号。
    always_ff @(posedge dst_clk) begin
        if (dst_rst) begin
            req_sync <= '0;
        end else begin
            req_sync[0] <= req_toggle;
            for (req_stage = 1; req_stage < SYNC_STAGES; req_stage = req_stage + 1) begin
                req_sync[req_stage] <= req_sync[req_stage-1];
            end
        end
    end

    // 目标域只使用请求同步链末级，并将变化转换为严格单周期事件。
    always_ff @(posedge dst_clk) begin
        if (dst_rst) begin
            req_seen <= 1'b0;
            dst_event <= 1'b0;
        end else begin
            dst_event <= 1'b0;
            if (req_sync[SYNC_STAGES-1] != req_seen) begin
                req_seen  <= req_sync[SYNC_STAGES-1];
                dst_event <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
