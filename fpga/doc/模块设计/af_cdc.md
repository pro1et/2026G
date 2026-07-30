# `af_cdc` 模块设计指导

## 一、任务目标

设计一个参数化的 SystemVerilog 模块：

```systemverilog
af_cdc
```

该模块把源时钟域中的单周期事件可靠地转换为目标时钟域中的单周期事件。模块
内部使用 toggle 请求/确认握手，事件在目标时钟暂时停止或两侧频率差异较大时
仍能保持，不能用简单的脉冲打两拍代替。

本系统需要实例化两次：

```text
30 MHz ADC 写域                              100 MHz FIFO/FIR 域
frame_done_event ── af_cdc ──> frame_ready_event

30 MHz ADC 写域                              100 MHz FIFO/FIR 域
frame_consumed    <─ af_cdc ── fifo_frame_done
```

---

## 二、模块职责与边界

模块负责：

```text
接收源域单周期事件
在源域锁存事件请求
把请求 toggle 同步到目标域
在目标域产生恰好一个周期的事件脉冲
把目标域确认同步回源域
指示上一事件是否仍在传输
检测源域在忙期间提交新事件的协议错误
```

模块不负责：

```text
解释事件的业务含义
传输多比特数据
缓存多个待发送事件
产生或同步系统复位
控制 ADC、FIFO 或 FIR 状态机
```

多比特数据必须通过异步 FIFO、双口 BRAM 所有权协议或其他明确的 CDC 结构传输。

---

## 三、为什么使用请求/确认 toggle

源域单周期脉冲不能直接在目标域打两拍。目标时钟较慢、暂停或与源时钟边沿不利
时，目标域可能完全看不到该脉冲。

本模块把事件编码为持续保持的状态变化：

```text
源事件到达
→ req_toggle 翻转并保持
→ 目标域同步后检测到 req_toggle 变化
→ 目标域产生一个 dst_event
→ 目标域把已处理值作为确认返回
→ 源域收到确认后解除 src_busy
```

只有确认返回后才能接受下一事件，因此不会因两个事件间隔过短而把两次 toggle
抵消成一次。

---

## 四、建议参数

```systemverilog
parameter int unsigned SYNC_STAGES = 2;
```

`SYNC_STAGES` 是每个同步链的触发器级数，必须大于等于 2。默认两级适合当前
30 MHz 与 100 MHz 时钟域。增加级数可以提高 MTBF，但也会增加握手往返延迟。

仿真阶段必须检查参数：

```systemverilog
initial begin
    assert (SYNC_STAGES >= 2)
        else $fatal(1, "SYNC_STAGES 必须大于等于 2");
end
```

---

## 五、建议模块接口

```systemverilog
module af_cdc #(
    parameter int unsigned SYNC_STAGES = 2  // 同步链级数，必须大于等于 2
) (
    // 源时钟域接口
    input  wire logic src_clk,            // 源域工作时钟
    input  wire logic src_rst,            // 源域高电平有效同步复位
    input  wire logic src_event,          // 源域单周期事件，仅在 src_busy 为低时接受
    output      logic src_busy,           // 事件正在跨域传输的源域状态电平
    output      logic src_protocol_error, // 忙期间重复提交事件的源域粘滞错误标志

    // 目标时钟域接口
    input  wire logic dst_clk,            // 目标域工作时钟
    input  wire logic dst_rst,            // 目标域高电平有效同步复位
    output      logic dst_event           // 目标域单周期事件脉冲
);
```

| 端口 | 时钟域 | 语义 |
| --- | --- | --- |
| `src_clk` | 源域 | 源侧工作时钟 |
| `src_rst` | 源域 | 高电平有效同步复位 |
| `src_event` | 源域 | 待传输的单周期事件，仅在 `src_busy=0` 时允许 |
| `src_busy` | 源域 | 上一事件尚未被目标域确认的状态电平 |
| `src_protocol_error` | 源域 | 忙期间又收到事件的粘滞错误标志 |
| `dst_clk` | 目标域 | 目标侧工作时钟 |
| `dst_rst` | 目标域 | 高电平有效同步复位 |
| `dst_event` | 目标域 | 成功接收事件后的单周期脉冲 |

---

## 六、时钟域与复位要求

`src_clk` 和 `dst_clk` 可以异步、同频异相或频率不同。本系统中分别为 30 MHz 与
100 MHz；反向实例交换两个时钟。

`src_rst` 和 `dst_rst` 必须来自同一个系统复位请求，并分别在各自时钟域同步释放。
两侧 toggle 状态的复位初值统一为 `1'b0`。

使用限制：

```text
两个时钟在复位释放过程中必须持续运行
不得只复位一侧而让另一侧继续处理事件
复位期间及任一侧尚未完成复位时不得提交 src_event
系统重新初始化时应同时复位两个时钟域中的本模块实例
```

若只复位一侧，toggle 初值可能与另一侧保存值不一致，从而产生虚假事件、遗漏事件
或使 `src_busy` 无法解除。需要支持独立域复位时，应升级为带显式链路初始化状态的
协议，不能继续使用本指导的简化复位约束。

---

## 七、内部信号

建议使用：

```systemverilog
logic req_toggle;
logic req_seen;
logic [SYNC_STAGES-1:0] req_sync;
logic [SYNC_STAGES-1:0] ack_sync;
```

含义：

```text
req_toggle  源域中当前请求的 toggle 值
req_sync    请求从源域进入目标域的同步链
req_seen    目标域已经处理过的请求值，同时作为返回确认
ack_sync    req_seen 返回源域的同步链
```

同步链必须添加属性，避免综合工具把触发器重构为移位寄存器或分散放置：

```systemverilog
(* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
logic [SYNC_STAGES-1:0] req_sync;

(* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
logic [SYNC_STAGES-1:0] ack_sync;
```

只有同步链第一级允许直接采样异步 toggle。业务逻辑只能使用同步链最后一级。

---

## 八、源域逻辑

源域忙状态定义为：

```systemverilog
assign src_busy = req_toggle != ack_sync[SYNC_STAGES-1];
```

事件处理原则：

```systemverilog
if (src_event && !src_busy) begin
    req_toggle <= ~req_toggle;
end
else if (src_event && src_busy) begin
    src_protocol_error <= 1'b1;
end
```

`src_event` 必须严格保持一个源时钟周期。若上游把它保持到 `src_busy` 再次变低，
模块可能把仍为高的电平误认为第二个事件，因此禁止使用多周期电平代替事件脉冲。

`src_protocol_error` 为粘滞标志，保持到 `src_rst`。发生该错误时，新事件被拒绝，
正在传输的上一事件仍继续完成。

---

## 九、目标域逻辑

目标域每周期默认清除事件输出：

```systemverilog
dst_event <= 1'b0;
```

当同步后的请求与已处理值不同时，表示有一个新事件：

```systemverilog
if (req_sync[SYNC_STAGES-1] != req_seen) begin
    dst_event <= 1'b1;
    req_seen  <= req_sync[SYNC_STAGES-1];
end
```

`req_seen` 更新后持续保持，并通过 `ack_sync` 返回源域。目标域不向业务模块暴露
toggle，只输出清晰的单周期 `dst_event`。

---

## 十、同步链写法

参数化同步链必须保证 `SYNC_STAGES=2` 时索引合法。建议使用循环：

```systemverilog
integer i;

always_ff @(posedge dst_clk) begin
    if (dst_rst) begin
        req_sync <= '0;
    end
    else begin
        req_sync[0] <= req_toggle;
        for (i = 1; i < SYNC_STAGES; i = i + 1) begin
            req_sync[i] <= req_sync[i-1];
        end
    end
end
```

确认返回链在 `src_clk` 域采用相同结构，把异步的 `req_seen` 同步到 `ack_sync`。

同步链寄存器不得加入组合逻辑、时钟使能或业务复位条件。

---

## 十一、握手时序、延迟与吞吐率

一次正常事件按以下顺序发生：

```text
源域：src_event=1 且 src_busy=0
源域：req_toggle 翻转，src_busy 随后变为 1
目标域：req_sync 经过 SYNC_STAGES 级同步
目标域：检测变化，dst_event=1 一个周期，req_seen 更新
源域：ack_sync 经过 SYNC_STAGES 级同步
源域：ack_sync 等于 req_toggle，src_busy 变为 0
```

延迟不是固定的绝对时间，取决于两个异步时钟的相位。采用两级同步器时，通常约
需要 2～3 个目标时钟周期产生 `dst_event`，确认返回还需要约 2～3 个源时钟周期。

峰值事件吞吐率受完整往返握手限制。本系统的帧事件间隔为数百微秒到毫秒，远大于
握手延迟，因此不会成为吞吐瓶颈。

---

## 十二、30 MHz 到 100 MHz 的连接

帧就绪通知实例：

```systemverilog
af_cdc u_frame_ready_cdc (
    .src_clk            (clk_30m),
    .src_rst            (rst_30m),
    .src_event          (frame_done_event),
    .src_busy           (frame_ready_cdc_busy),
    .src_protocol_error (frame_ready_cdc_error),
    .dst_clk            (clk_100m),
    .dst_rst            (rst_100m),
    .dst_event          (frame_ready_event)
);
```

`frame_done_event` 来自 `adc_write_controller`，`frame_ready_event` 连接到
`fifo_ctrl`。正常情况下 ADC 写控制器在上一帧消费完成前不会产生下一帧完成事件，
因此 `src_busy` 应在下一事件前自然解除。

---

## 十三、100 MHz 到 30 MHz 的连接

帧消费通知实例：

```systemverilog
af_cdc u_frame_consumed_cdc (
    .src_clk            (clk_100m),
    .src_rst            (rst_100m),
    .src_event          (fifo_frame_done),
    .src_busy           (frame_consumed_cdc_busy),
    .src_protocol_error (frame_consumed_cdc_error),
    .dst_clk            (clk_30m),
    .dst_rst            (rst_30m),
    .dst_event          (frame_consumed)
);
```

`fifo_frame_done` 只在最后一个 FIFO 数据与 FIR 完成 valid-ready 握手时产生。
目标域的 `frame_consumed` 连接到 `adc_write_controller`，使其离开等待消费状态。

---

## 十四、错误与异常行为

### 忙期间重复事件

当 `src_busy=1` 时收到 `src_event`：

```text
不改变 req_toggle
不覆盖正在传输的事件
置位 src_protocol_error
```

### 目标时钟暂停

请求 toggle 持续保持，因此目标时钟恢复后仍能收到事件。暂停期间 `src_busy`
保持为高，源域不能提交下一事件。

### 源时钟暂停

目标域可以完成当前事件，但确认返回只有在源时钟恢复后才能解除 `src_busy`。

### 单侧复位

本版本不支持运行中单独复位一个时钟域。系统必须同时重新初始化两侧，否则可能
出现虚假事件或握手状态不一致。

---

## 十五、综合与 CDC 检查要求

必须检查：

```text
req_sync 和 ack_sync 被识别为 ASYNC_REG 同步链
跨域路径只进入同步链第一级
同步链第一级到末级没有组合逻辑
业务逻辑不直接使用 req_toggle 或 req_seen 的异步值
不存在多比特总线逐位同步
CDC 报告没有未识别或不安全路径
```

不要对两个时钟声明为同源同步时钟。即使它们都由同一个 MMCM 产生，只要业务上
不依赖固定相位，本模块仍按异步 CDC 处理。顶层时序约束应与实际时钟树一致，
不能用虚假的 false path 掩盖同步结构错误。

---

## 十六、仿真验证计划

必须编写自检式 testbench，至少覆盖以下场景。

### 正常单事件

```text
目标域恰好产生一个单周期 dst_event
src_busy 在请求后拉高
确认返回后 src_busy 自动拉低
src_protocol_error 保持为 0
```

### 连续合法事件

每次等待 `src_busy=0` 后再发送事件，重复多次，检查目标事件数量和顺序完全一致。

### 忙期间重复事件

```text
第二个事件不传输
第一个事件正常完成
src_protocol_error 被锁存
```

### 不同频率和相位

至少测试：

```text
30 MHz → 100 MHz
100 MHz → 30 MHz
非整数频率比
随机初始相位
```

### 时钟暂停

分别暂停源时钟和目标时钟，验证请求不会丢失、不会重复，并在两个时钟恢复后完成
确认。

### 协调复位

在空闲和忙状态分别同时复位两个时钟域，检查：

```text
dst_event 不产生虚假脉冲
src_busy 返回 0
src_protocol_error 清零
后续事件仍能正常传输
```

### 长时间运行

传输足够多的事件，使 toggle 多次往返翻转，检查不存在偶数次翻转丢失或计数偏差。

测试结束必须打印 `TEST PASSED`；任一断言失败必须通过 `$fatal` 结束仿真。

---

## 十七、ILA 调试信号

建议保留：

```text
src_event
src_busy
req_toggle
ack_sync 最后一级
req_sync 最后一级
req_seen
dst_event
src_protocol_error
```

这些信号跨越两个时钟域，ILA 连接时应按所在时钟域分别采样，不能用一个 ILA
时钟直接观察另一域的未同步内部信号并据此判断功能正确性。

---

## 十八、最终实现原则

```text
业务模块只产生和接收本时钟域单周期事件
跨域请求必须保持到目标域确认
同步链只同步单比特 toggle
忙期间不覆盖事件，并锁存协议错误
两个方向使用两个独立实例
复位初值一致，两个时钟域协调复位
CDC 模块不承担 ADC、FIFO 或 FIR 业务逻辑
```
