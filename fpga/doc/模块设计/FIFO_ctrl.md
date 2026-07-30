# `fifo_ctrl` 模块设计指导

## 一、任务目标

设计一个参数化的 SystemVerilog 模块：

```systemverilog
fifo_ctrl
```

该模块位于异步 FIFO 读端与 FIR 滤波器之间，工作在 100 MHz 处理时钟域。

主要功能为：

```text
接收 ADC 写控制器产生的整帧就绪事件
→ 等待 FIFO 读端和 FIR 满足启动条件
→ 从 FWFT 异步 FIFO 中读取固定数量的数据
→ 通过 valid-ready 握手送入 FIR
→ 产生 fir_first 和 fir_last
→ 最后一个 FIFO 数据被 FIR 接收后通知 ADC 写控制器
→ 等待 FIR 完成本帧输出
→ 允许下一帧进入 FIR
```

默认一帧长度为：

```text
65536 点
```

但必须通过参数配置，不得在逻辑中写死。

---

## 二、系统位置

系统数据通路为：

```text
ADC 采样模块
    │
    ▼
ADC 写控制器
    │ ADC 时钟域
    │
    ▼
异步 FIFO 写端
    │
    │ FIFO 内部 BRAM
    ▼
异步 FIFO 读端
    │ 100 MHz 时钟域
    ▼
fifo_ctrl
    │
    │ fir_data
    │ fir_valid
    │ fir_ready
    │ fir_first
    │ fir_last
    ▼
FIR 滤波器
```

`fifo_ctrl` 不负责：

```text
ADC 数据采集
ADC 数据格式转换
FIFO 写入
FIFO 内部地址生成
FIR 乘加计算
FIR 系数管理
跨时钟同步器内部实现
```

---

## 三、与 ADC 写控制器的协作

ADC 写控制器工作在 ADC 采样时钟域。

ADC 写控制器接收到上层的：

```systemverilog
capture_start_pulse
```

后，向异步 FIFO 中写入一帧数据。

只有满足：

```systemverilog
adc_valid &&
!fifo_full &&
!fifo_wr_rst_busy
```

时，当前 ADC 数据才算真正写入 FIFO。

ADC 写控制器成功写入第 `FRAME_SIZE` 个数据后，产生本域单周期事件：

```systemverilog
frame_done_event
```

该事件送入独立的 `af_cdc` 模块。CDC 模块内部使用 toggle
请求/确认握手，在 100 MHz 域输出单周期事件：

```systemverilog
frame_ready_event
```

`fifo_ctrl` 接收的是同步后的：

```systemverilog
frame_ready_event
```

不直接处理 ADC 时钟域中的原始脉冲。

---

## 四、返回 ADC 写控制器的事件

当本帧最后一个 FIFO 数据已经被 FIR 成功接收时，`fifo_ctrl` 产生本域单周期事件：

```systemverilog
fifo_frame_done
```

产生条件为：

```systemverilog
fir_valid &&
fir_ready &&
fir_last
```

`fifo_frame_done` 送入反向实例化的 `af_cdc`，在 ADC 时钟域形成：

```systemverilog
frame_consumed
```

ADC 写控制器收到该事件后，才认为 FIFO 已经可以重新用于下一帧采集。

注意：

```text
frame_consumed
```

表示 FIFO 中的本帧已经全部读出，不表示 FIR 的最后一个输出已经产生。

---

## 五、ADC 与 FIR 的并行关系

最后一个 FIFO 数据送入 FIR 后：

```text
FIFO 已经可以重新写入
但 FIR 可能仍在输出上一帧结果
```

因此允许以下两个过程并行进行：

```text
ADC 采集下一帧并写入 FIFO
FIR 完成上一帧的输出流水线
```

但是下一帧数据不能立即送入 FIR。

`fifo_ctrl` 必须等待：

```systemverilog
fir_frame_done
```

表示上一帧最后一个 FIR 输出已经产生，之后才能向 FIR 发送下一帧的第一个数据。

---

## 六、FIR 帧语义

每一帧 FIR 输入相互独立。

当以下条件成立时：

```systemverilog
fir_valid &&
fir_ready &&
fir_first
```

FIR 必须：

```text
清空上一帧的历史采样
将当前 fir_data 作为新帧第一个输入
按照零初始状态开始滤波
```

不能仅根据 `fir_first` 清空历史，因为在：

```systemverilog
fir_valid = 1;
fir_first = 1;
fir_ready = 0;
```

时，FIR 尚未真正接收第一个数据。

---

## 七、FIFO 配置要求

异步 FIFO 建议配置为：

```text
写数据宽度：16 bit
读数据宽度：16 bit
深度：65536
读模式：FWFT
```

在 FWFT 模式下，当：

```systemverilog
fifo_empty == 1'b0
```

时：

```systemverilog
fifo_dout
```

已经是当前待读取的数据。

因此可以直接连接：

```systemverilog
assign fir_data = $signed(fifo_dout);
```

`fifo_ctrl` 不需要重新缓存 FIFO 输出。

FIFO 的 `dout` 端口只表示存储位模式，没有 signed 数值语义。当前 ADC 写入的是
二进制补码有符号样点，因此 `fifo_ctrl` 向 FIR 输出时必须恢复 signed 类型，避免
FIR 的乘法、比较和扩位被按无符号处理。

---

## 八、建议参数

模块至少包含以下参数：

```systemverilog
parameter int DATA_WIDTH = 16;
parameter int FRAME_SIZE = 65536;
```

计数器位宽在模块内部自动计算：

```systemverilog
localparam int INDEX_WIDTH =
    (FRAME_SIZE <= 1) ? 1 : $clog2(FRAME_SIZE);
```

计数器建议命名为：

```systemverilog
transfer_index
```

其含义是当前正在发送的数据序号：

```text
0 ～ FRAME_SIZE - 1
```

不要将其定义为已经传输的数据总数，否则 `FRAME_SIZE = 65536` 时需要额外一位。

---

## 九、建议模块接口

```systemverilog
module fifo_ctrl #(
    parameter int DATA_WIDTH = 16,
    parameter int FRAME_SIZE = 65536
) (
    input  logic                    clk,
    input  logic                    rst,

    // ADC 写控制器的整帧就绪事件
    // 已经同步到 clk 时钟域
    input  logic                    frame_ready_event,

    // 异步 FIFO 读接口
    input  logic [DATA_WIDTH-1:0]   fifo_dout,
    input  logic                    fifo_empty,
    input  logic                    fifo_rd_rst_busy,
    output logic                    fifo_rd_en,

    // FIR 输入接口
    output logic signed [DATA_WIDTH-1:0] fir_data,
    output logic                    fir_valid,
    input  logic                    fir_ready,
    output logic                    fir_first,
    output logic                    fir_last,

    // FIR 当前帧输出完成事件
    input  logic                    fir_frame_done,

    // 状态和调试信号
    output logic                    transfer_busy,
    output logic                    fifo_frame_done,
    output logic                    underflow_error,
    output logic                    protocol_error,

    output logic [
        ((FRAME_SIZE <= 1) ? 1 : $clog2(FRAME_SIZE))-1:0
    ] transfer_index
);
```

可以根据现有工程接口风格微调，但不要改变核心握手语义。

---

## 十、核心握手逻辑

定义：

```systemverilog
transfer_fire = fir_valid && fir_ready;
```

只有 `transfer_fire` 为高时，才同时发生：

```text
FIR 接收当前数据
FIFO 弹出当前数据
transfer_index 更新
```

因此：

```systemverilog
fifo_rd_en = fir_valid && fir_ready;
```

禁止写成：

```systemverilog
fifo_rd_en = !fifo_empty;
```

否则 FIR 无法接收时，FIFO 仍会继续弹出数据。

---

## 十一、推荐组合逻辑

在传输状态下建议采用：

```systemverilog
// FIFO 只保存补码位模式，此处显式恢复为有符号数后送入 FIR。
assign fir_data = $signed(fifo_dout);

assign fir_valid =
    (state == TRANSFER) &&
    !fifo_empty &&
    !fifo_rd_rst_busy;

assign fir_first =
    fir_valid &&
    (transfer_index == 0);

assign fir_last =
    fir_valid &&
    (transfer_index == FRAME_SIZE - 1);

assign fifo_rd_en =
    fir_valid &&
    fir_ready;

assign transfer_fire =
    fir_valid &&
    fir_ready;
```

`fir_valid` 不应直接受 `fir_ready` 控制。

valid-ready 接口应满足：

```text
发送方声明数据有效
接收方声明是否准备好
双方同时为高时完成一次传输
```

---

## 十二、FIR 反压要求

当：

```systemverilog
fir_valid == 1'b1 &&
fir_ready == 1'b0
```

时，必须保持以下信号稳定：

```text
fir_data
fir_valid
fir_first
fir_last
transfer_index
```

同时：

```systemverilog
fifo_rd_en = 1'b0;
```

这样 FIFO 当前数据不会被弹出。

特别需要测试：

```text
第一个数据被反压
最后一个数据被反压
```

确保 `fir_first` 和 `fir_last` 会一直保持到真正握手成功。

---

## 十三、待处理帧锁存

增加：

```systemverilog
logic frame_pending;
```

当检测到：

```systemverilog
frame_ready_event
```

时，将新帧请求保存：

```systemverilog
frame_pending <= 1'b1;
```

这样即使事件到达时：

```text
FIFO 读端仍处于复位
FIR 上一帧尚未完成
状态机尚不能立即读取
```

也不会丢失帧请求。

开始发送该帧后再清除：

```systemverilog
frame_pending <= 1'b0;
```

---

## 十四、状态机建议

建议至少包含以下状态：

```text
WAIT_FRAME
WAIT_FIFO
TRANSFER
WAIT_FIR_DONE
ERROR
```

### `WAIT_FRAME`

等待新的完整帧。

主要行为：

```text
不读取 FIFO
fir_valid = 0
transfer_busy = 0
transfer_index = 0
```

收到 `frame_ready_event` 后：

```text
设置 frame_pending
进入 WAIT_FIFO
```

如果帧事件已经在其他状态被锁存，返回该状态后也要继续处理。

---

### `WAIT_FIFO`

等待启动条件。

启动传输需要满足：

```systemverilog
frame_pending &&
!fifo_rd_rst_busy &&
!fifo_empty
```

同时必须保证上一帧 FIR 已经结束。

由于状态机只有在 `fir_frame_done` 后才会从 `WAIT_FIR_DONE` 离开，因此可以通过状态机自然保证 FIR 空闲。

注意：

收到 `frame_ready_event` 后，`fifo_empty` 可能因为跨时钟标志同步延迟而暂时仍为高。

因此在 `WAIT_FIFO` 状态中不能因为 `fifo_empty` 为高就立即报错，只需要继续等待。

---

### `TRANSFER`

向 FIR 发送一帧数据。

每当：

```systemverilog
transfer_fire
```

成立时：

* 如果当前数据不是最后一个，`transfer_index` 加一；
* 如果当前数据是最后一个，结束 FIFO 输入传输。

最后一个数据完成条件为：

```systemverilog
transfer_fire &&
(transfer_index == FRAME_SIZE - 1)
```

此时应：

```text
正常拉高 fifo_rd_en
保持 fir_last 有效
让 FIR 接收最后一个数据
产生 fifo_frame_done 单周期事件，并送往反向事件 CDC 模块
退出 TRANSFER
进入 WAIT_FIR_DONE
```

最后一个数据成功后，不要再让 `transfer_index` 加一，避免计数器回绕。

---

### `WAIT_FIR_DONE`

等待 FIR 完成上一帧输出。

此状态下：

```text
不读取 FIFO
fir_valid = 0
transfer_busy = 0
```

ADC 可以在此期间采集下一帧并写入 FIFO。

如果此时收到新的：

```systemverilog
frame_ready_event
```

应将其保存到：

```systemverilog
frame_pending
```

不能将其直接判定为错误。

收到：

```systemverilog
fir_frame_done
```

后：

* 若没有待处理帧，返回 `WAIT_FRAME`；
* 若 `frame_pending == 1`，进入 `WAIT_FIFO`。

---

### `ERROR`

用于处理不可恢复异常。

进入错误状态后：

```text
停止 FIFO 读取
撤销 fir_valid
停止当前传输
保持错误标志
```

初始版本可以要求通过系统复位恢复，不需要设计复杂的自动清空 FIFO 逻辑。

---

## 十五、重复帧事件判断

当前系统只有一个 FIFO，最多只能保存一帧尚未送入 FIR 的数据。

在 `WAIT_FIR_DONE` 状态收到一次新的 `frame_ready_event` 是合法的。

但如果：

```systemverilog
frame_pending == 1'b1
```

时再次收到：

```systemverilog
frame_ready_event
```

说明已经有一帧等待处理，ADC 又报告了新的完整帧，应设置：

```systemverilog
protocol_error <= 1'b1;
```

这可能说明：

```text
ADC 写控制器未等待 frame_consumed
跨时钟事件发生重复
系统握手状态不一致
```

在 `TRANSFER` 状态收到新的完整帧事件通常也应视为协议异常，因为 ADC 此时尚未收到当前帧经 CDC 返回的 `frame_consumed`。

---

## 十六、FIFO 下溢检测

正常情况下，收到 `frame_ready_event` 后，FIFO 中应已经保存完整的一帧数据。

如果在 `TRANSFER` 状态中，尚未完成规定数量的数据传输，FIFO 却变为空，应设置：

```systemverilog
underflow_error <= 1'b1;
```

可能原因包括：

```text
ADC 实际写入数量不足
frame_ready 产生过早
FIFO 被其他模块读取
FIFO 复位异常
读写计数不一致
```

异常判断必须注意最后一个数据的优先级。

推荐时序关系：

```systemverilog
if (transfer_fire) begin
    if (transfer_index == FRAME_SIZE - 1) begin
        // 正常完成一帧
    end
    else begin
        transfer_index <= transfer_index + 1'b1;
    end
end
else if ((state == TRANSFER) && fifo_empty) begin
    // 尚未完成但 FIFO 已空
    // 设置 underflow_error
end
```

避免最后一个数据弹出后 FIFO 正常变空，却被误判为下溢。

必要时可以给进入 `TRANSFER` 后的 `fifo_empty` 检测增加一个周期保护，但不要掩盖真正的数据不足问题。

---

## 十七、完成事件定义

必须明确区分两个完成事件。

### `fifo_frame_done`

单周期脉冲，表示：

```text
最后一个 FIFO 数据已经被 FIR 接收
```

产生条件：

```systemverilog
transfer_fire && fir_last
```

### `fir_frame_done`

由 FIR 输入到 `fifo_ctrl`，表示：

```text
最后一个 FIR 输出已经产生
FIR 当前帧已经全部结束
```

只有收到 `fir_frame_done` 后，才能向 FIR 发送下一帧的 `fir_first`。

---

## 十八、帧消费事件的 CDC 行为

`fifo_ctrl` 只产生本时钟域的单周期事件：

```systemverilog
fifo_frame_done
```

不能把该脉冲直接送到 ADC 时钟域。系统应实例化独立的
`af_cdc`：

```text
100 MHz 域 fifo_frame_done
    → af_cdc
    → 30 MHz 域 frame_consumed
```

CDC 模块内部负责 toggle 请求、目标域脉冲生成和确认返回。`fifo_ctrl` 不保存或
操作跨时钟域 toggle，从而保持业务状态机为单时钟、单职责模块。具体协议、复位
要求和异常行为见 `af_cdc.md`。

---

## 十九、复位行为

复位时应：

```text
状态机返回 WAIT_FRAME
fifo_rd_en 关闭
fir_valid 撤销
fir_first 撤销
fir_last 撤销
transfer_index 清零
frame_pending 清零
transfer_busy 清零
fifo_frame_done 清零
错误标志清零
```

`fifo_rd_rst_busy` 为高时，禁止：

```text
开始新一帧
拉高 fir_valid
拉高 fifo_rd_en
```

---

## 二十、编码要求

代码使用 SystemVerilog。

要求：

1. 所有输入输出端口均添加中文注释；
2. 模块开头添加完整的中文使用说明；
3. 说明模块应连接到哪些时钟域和接口；
4. 明确 FIFO 必须配置为 FWFT 模式；
5. 状态机使用清晰的枚举命名；
6. 参数化数据宽度和帧长度；
7. 不在模块内部自行分频；
8. 计数器只能在 `transfer_fire` 时更新；
9. 单周期脉冲每周期默认清零；
10. 错误标志建议设计为粘滞标志，保持到复位；
11. 组合逻辑必须设置完整默认值，避免锁存器；
12. 不要把 CDC 同步器与核心控制状态机混在一起。

---

## 二十一、仿真要求

为 `fifo_ctrl` 编写自检 testbench，至少覆盖以下场景。

### 正常连续传输

验证：

```text
准确传输 FRAME_SIZE 个数据
fifo_rd_en 有效次数正确
第一个数据 fir_first = 1
最后一个数据 fir_last = 1
transfer_index 顺序正确
fifo_frame_done 只产生一个周期，CDC 目标端只产生一次 frame_consumed
```

### FIR 随机反压

随机拉低 `fir_ready`，验证：

```text
反压期间 FIFO 不继续读取
fir_data 保持稳定
transfer_index 不增加
数据没有丢失、重复或乱序
```

### 第一个数据反压

在 `fir_first` 有效时拉低 `fir_ready`，验证：

```text
fir_first 持续保持
数据不被弹出
恢复 fir_ready 后只接收一次
```

### 最后一个数据反压

在 `fir_last` 有效时拉低 `fir_ready`，验证：

```text
控制器不会提前结束
fifo_frame_done 和目标域 frame_consumed 都不会提前产生
```

### 下一帧提前写入

在 `WAIT_FIR_DONE` 状态产生新的 `frame_ready_event`，验证：

```text
frame_pending 被正确锁存
不会立即向 FIR 发送下一帧
收到 fir_frame_done 后自动开始处理下一帧
```

### 重复帧事件

在 `frame_pending == 1` 时再次产生 `frame_ready_event`，验证：

```text
protocol_error 被置位
```

### FIFO 数据不足

只提供少于 `FRAME_SIZE` 个数据，验证：

```text
underflow_error 被置位
当前帧不会被判定为正常完成
```

### FIFO 读端复位忙

在帧事件到达时保持：

```systemverilog
fifo_rd_rst_busy = 1'b1;
```

验证：

```text
帧事件不会丢失
不会读取 FIFO
复位结束后能够正常启动传输
```

### 中途复位

分别在各状态施加复位，验证模块能够安全返回初始状态。

---

## 二十二、ILA 调试信号

建议保留并接入 ILA：

```text
state
frame_ready_event
frame_pending
fifo_empty
fifo_rd_rst_busy
fifo_rd_en
fifo_dout
fir_valid
fir_ready
fir_first
fir_last
transfer_fire
transfer_index
fifo_frame_done
fir_frame_done
underflow_error
protocol_error
```

在模块代码最底部以中文注释记录仿真和上板过程中发现的问题、原因以及对应解决方法。

---

## 二十三、最终实现原则

`fifo_ctrl` 的核心原则是：

```text
只在 FIR 真正接收数据时读取 FIFO
只在最后一个数据真正握手后通知 ADC
允许 ADC 与 FIR 输出流水线并行工作
但不允许两帧同时进入 FIR
每一帧开始时 FIR 清空历史采样
所有跨时钟事件通过独立的 `af_cdc` 传递
```

优先保证数据不丢失、不重复、不跨帧混合，再考虑进一步提高吞吐率。
