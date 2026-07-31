
# Spectrol 频域处理控制器设计背景

## 1. 系统说明

整个周期信号测量系统可以使用多块 BRAM，例如参数 BRAM、FIR 系数 BRAM、IQ 数据 BRAM等。

但在当前讨论的**频域处理部分**中，只使用以下两块 BRAM：

1. 频谱 BRAM；
2. 能量结果 BRAM。

其中，Spectrol 只负责管理频谱 BRAM，不负责管理能量结果 BRAM。

模块采用 SystemVerilog 编写，文件名为：

```text
fpga/src/hdl/spectrol.sv
```

当前频域处理参数如下：

* FFT 输入采样率：2 MHz；
* FFT 点数：4096；
* 实信号只分析正频率部分；
* 有效频谱下标约为 0～2047；
* 每根 FFT 谱线对应约 488.28125 Hz；
* 功率谱定义为：P[k] = Re[k]² + Im[k]²；
* 功率计算模块已经完成固定缩放、四舍五入和 32 位处理；
* Spectrol、频谱 BRAM、基频检测和能量计算之间的功率数据统一为 32 位无符号数；
* `POWER_WIDTH` 固定为 32。

---

## 1.1 当前实现范围

当前版本已经实现：

* 第一阶段：功率谱写入频谱 BRAM；
* 写完后的单拍 `base_start`；
* 基频检测模块的 BRAM 请求、固定读取延迟和返回数据服务；
* 等待 `base_done` 后产生整帧 `frame_done`。

当前暂不实现：

* 能量计算启动和读取服务；
* 基频检测与能量计算之间的多读取者仲裁。

当前模块接口为：

```systemverilog
module spectrol #(
    parameter int unsigned POWER_WIDTH     = 32,
    parameter int unsigned BRAM_RD_LATENCY = 2
) (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    clear_error,

    input  logic                    start,
    output logic                    busy,
    output logic                    spectrum_write_done,
    output logic                    frame_done,
    output logic                    protocol_error,

    input  logic [POWER_WIDTH-1:0]  power_data,
    input  logic [10:0]             power_bin,
    input  logic                    power_valid,
    output logic                    power_ready,
    input  logic                    power_first,
    input  logic                    power_last,

    output logic                    base_start,
    input  logic                    base_done,
    input  logic                    base_valid,

    input  logic                    base_mem_req,
    input  logic [10:0]             base_mem_addr,
    output logic                    base_mem_ready,
    output logic                    base_mem_rvalid,
    output logic [POWER_WIDTH-1:0]  base_mem_rdata,

    output logic                    spectrum_bram_en,
    output logic                    spectrum_bram_we,
    output logic [10:0]             spectrum_bram_addr,
    output logic [POWER_WIDTH-1:0]  spectrum_bram_din,
    input  logic [POWER_WIDTH-1:0]  spectrum_bram_dout
);
```

`start` 在空闲状态下启动一帧写入。上游必须保持 `power_valid`、`power_bin`、
`power_data`、`power_first` 和 `power_last`，直到 `power_ready = 1` 完成握手。

频谱 BRAM 使用 11 位逻辑字地址：

```text
spectrum_bram_addr = k  →  第k个32位功率值
```

这里不是 AXI 字节地址，因此不需要对地址左移 2 位。若以后连接 AXI 地址接口，
应在相应适配层中转换为 `k << 2`。

`spectrum_write_done` 表示 2048 点功率谱已经写完；它不代表整帧频域处理结束。
当前 `frame_done` 在基频检测模块给出 `base_done`、且所有 BRAM 返回数据均已
排空后产生。

---

## 2. 两块频域处理 BRAM

### 2.1 频谱 BRAM

频谱 BRAM保存完整正频率功率谱：

```text
地址 k → 功率谱 P[k]
```

该 BRAM 的 PL 侧端口由 Spectrol 统一管理。

需要访问该端口的模块有：

* 功率谱写入通路；
* 基频检测模块；
* 能量计算模块。

由于 PL 侧只有一个可用端口，这三个访问过程必须分阶段进行。

### 2.2 能量结果 BRAM

能量结果 BRAM保存基波和各次谐波的分析结果。

端口分配为：

```text
Port A：能量计算模块写入
Port B：PS通过AXI读取
```

能量结果 BRAM由能量计算模块直接管理，Spectrol 不参与其地址、写使能和写数据控制。

---

## 3. Spectrol 的主要职责

Spectrol 负责：

1. 将功率谱写入频谱 BRAM；
2. 在功率谱写完后启动基频检测模块；
3. 为基频检测模块提供频谱 BRAM读取服务；
4. 在基频检测成功后启动能量计算模块；
5. 为能量计算模块提供频谱 BRAM读取服务；
6. 管理频谱 BRAM 的地址、使能、写使能和写数据；
7. 处理频谱 BRAM 的固定读取延迟；
8. 将返回数据送给当前工作的读取模块；
9. 等待各处理模块完成；
10. 输出当前帧频域处理完成状态。

Spectrol 不负责：

* 计算基波和谐波能量；
* 写入能量结果 BRAM；
* 组织结果 BRAM的数据结构；
* 向 PS发布结果有效标志。

这些功能属于能量计算模块。

---

## 4. Spectrol 的三个处理阶段

### 第一阶段：写入功率谱

FFT 输出经过功率计算后形成：

```text
power_valid
power_ready
power_bin
power_data
power_first
power_last
```

其中：

* `power_valid`：当前功率数据有效；
* `power_ready`：Spectrol 当前可以接收功率数据；
* `power_bin`：当前 FFT 频点下标；
* `power_data`：当前频点功率；
* `power_first`：当前点是否为 bin 0；
* `power_last`：当前帧最后一个有效功率谱点。

Spectrol 在该阶段驱动频谱 BRAM：

```text
接收条件   = power_valid && power_ready
BRAM地址   = power_bin
BRAM写数据 = power_data
BRAM写使能 = power_valid && power_ready && 输入协议正确
```

成功接收且写入 `power_last` 后，表示完整功率谱已经写入频谱 BRAM。

---

### 第二阶段：基频检测

功率谱写完后，Spectrol 向基频检测模块产生一拍启动信号：

```text
base_start
```

基频检测模块通过统一请求接口读取频谱：

```text
base_mem_req
base_mem_addr
base_mem_ready
base_mem_rvalid
base_mem_rdata
```

检测结束后，基频检测模块输出：

```text
base_done
base_valid
base_index_500
base_bin
```

其中：

* `base_valid`：是否成功检测到基频；
* `base_index_500`：基频的 500 Hz 编号；
* `base_bin`：基频最接近的整数 FFT 谱线；
* `base_done`：检测过程结束。

基频实际频率为：

```text
基频频率 = 500 × base_index_500 Hz
```

例如：

```text
base_index_500 = 40
```

表示基频为：

```text
40 × 500 Hz = 20 kHz
```

---

### 第三阶段：基波与谐波能量计算

基频检测完成后，无论 `base_valid` 为 1 还是 0，Spectrol都向能量计算模块
产生一拍启动信号：

```text
energy_start
```

能量计算模块接收：

```text
base_valid
base_index_500
```

并通过以下接口读取频谱 BRAM：

```text
energy_mem_req
energy_mem_addr
energy_mem_ready
energy_mem_rvalid
energy_mem_rdata
```

能量计算模块在该阶段自行完成：

* 基波和谐波频点计算；
* 频谱读取；
* 能量累计；
* 能量结果 BRAM写入；
* 结果有效状态发布。

Spectrol 只需要等待：

```text
energy_done
```

收到 `energy_done` 后，当前帧频域处理结束。

---

## 5. 总体状态流程

推荐状态流程为：

```text
IDLE
  ↓
WRITE_SPECTRUM
  ↓
START_BASE
  ↓
WAIT_BASE
  ↓
START_ENERGY
  ↓
WAIT_ENERGY
  ↓
FRAME_DONE
```

当 `base_valid=0` 时仍执行能量阶段，由能量模块写入零能量和
`base_invalid=1` 的最终状态字，避免PS误读上一帧有效结果。

Spectrol 不再包含结果写入阶段。

原来的：

```text
WRITE_RESULT
```

状态被取消。

---

## 6. 频谱 BRAM 端口选择

### 写功率谱阶段

```verilog
spectrum_bram_en   = power_valid && power_ready && input_protocol_ok;
spectrum_bram_we   = power_valid && power_ready && input_protocol_ok;
spectrum_bram_addr = power_bin;
spectrum_bram_din  = power_data;
```

### 基频检测阶段

```verilog
spectrum_bram_en   = base_mem_req && base_mem_ready;
spectrum_bram_we   = 1'b0;
spectrum_bram_addr = base_mem_addr;
```

### 能量计算阶段

```verilog
spectrum_bram_en   = energy_mem_req && energy_mem_ready;
spectrum_bram_we   = 1'b0;
spectrum_bram_addr = energy_mem_addr;
```

任意时刻只能有一个数据源控制频谱 BRAM 的 PL 侧端口。

---

## 7. BRAM读取接口

基频检测模块和能量计算模块分别使用独立的请求接口。

### 基频检测模块接口

```verilog
input                         base_mem_req;
input      [10:0]             base_mem_addr;
output                        base_mem_ready;
output                        base_mem_rvalid;
output     [POWER_WIDTH-1:0]  base_mem_rdata;
```

### 能量计算模块接口

```verilog
input                         energy_mem_req;
input      [10:0]             energy_mem_addr;
output                        energy_mem_ready;
output                        energy_mem_rvalid;
output     [POWER_WIDTH-1:0]  energy_mem_rdata;
```

在基频检测阶段：

```text
base_mem_ready   = 1
energy_mem_ready = 0
```

在能量计算阶段：

```text
base_mem_ready   = 0
energy_mem_ready = 1
```

---

## 8. BRAM读取延迟

频谱 BRAM可能具有固定的一拍或两拍读取延迟。

Spectrol 应统一封装这一延迟，并在数据真正有效时产生：

```text
base_mem_rvalid
```

或者：

```text
energy_mem_rvalid
```

例如两拍读取延迟时：

```text
请求有效：1 1 1 1 1 1 1
返回有效：0 0 1 1 1 1 1 1 1
```

读取延迟只影响最开始等待的周期，不影响连续读取吞吐率。

地址可以连续每拍提交，经过流水线填充后，BRAM可以每拍返回一个数据。

---

## 9. 阶段切换与未完成请求

Spectrol 在切换频谱 BRAM使用者之前，应确保当前模块不存在尚未返回的读请求。

可维护：

```text
pending_count
```

当一次请求成功提交时：

```text
mem_req = 1 且 mem_ready = 1
```

则：

```text
pending_count 加 1
```

当一次返回数据有效时：

```text
mem_rvalid = 1
```

则：

```text
pending_count 减 1
```

只有同时满足以下两个条件，才允许切换阶段：

```text
当前模块已完成
pending_count = 0
```

这样可以避免上一阶段最后一个返回数据被错误地送给下一阶段模块。

---

## 10. 推荐状态定义

```verilog
localparam STATE_IDLE         = 4'd0;
localparam STATE_WRITE        = 4'd1;
localparam STATE_START_BASE   = 4'd2;
localparam STATE_WAIT_BASE    = 4'd3;
localparam STATE_START_ENERGY = 4'd4;
localparam STATE_WAIT_ENERGY  = 4'd5;
localparam STATE_FRAME_DONE   = 4'd6;
localparam STATE_ERROR        = 4'd7;
```

---

## 11. 后续完整版本的目标接口框架

下面的接口是加入基频检测和能量计算后的目标，并非当前
`fpga/src/hdl/spectrol.sv` 已实现的端口集合。

```verilog
module spectrol #(
    parameter POWER_WIDTH     = 32,
    parameter BRAM_RD_LATENCY = 2
)(
    input                         clk,
    input                         rst,
    input                         clear_error,

    // 整体控制
    input                         start,
    output reg                    busy,
    output reg                    frame_done,
    output reg                    protocol_error,

    // 功率谱写入
    input                         power_valid,
    output                        power_ready,
    input      [10:0]             power_bin,
    input      [POWER_WIDTH-1:0]  power_data,
    input                         power_first,
    input                         power_last,

    // 基频检测控制
    output reg                    base_start,
    input                         base_done,
    input                         base_valid,

    // 基频检测读取请求
    input                         base_mem_req,
    input      [10:0]             base_mem_addr,
    output                        base_mem_ready,
    output                        base_mem_rvalid,
    output     [POWER_WIDTH-1:0]  base_mem_rdata,

    // 能量计算控制
    output reg                    energy_start,
    input                         energy_done,

    // 能量计算读取请求
    input                         energy_mem_req,
    input      [10:0]             energy_mem_addr,
    output                        energy_mem_ready,
    output                        energy_mem_rvalid,
    output     [POWER_WIDTH-1:0]  energy_mem_rdata,

    // 频谱BRAM物理接口
    output reg                    spectrum_bram_en,
    output reg                    spectrum_bram_we,
    output reg [10:0]             spectrum_bram_addr,
    output reg [POWER_WIDTH-1:0]  spectrum_bram_din,
    input      [POWER_WIDTH-1:0]  spectrum_bram_dout
);
```

`base_index_500` 不一定需要经过 Spectrol。

更简单的连接方式是：

```text
基频检测模块的 base_index_500
              ↓
直接连接到能量计算模块
```

Spectrol 只负责产生 `energy_start`。

---

## 12. 最终职责边界

Spectrol 的数据流程为：

```text
写入功率谱
    ↓
启动基频检测
    ↓
为基频检测提供频谱读取
    ↓
启动能量计算
    ↓
为能量计算提供频谱读取
    ↓
等待能量计算完成
```

在整个频域处理部分中：

* Spectrol 只控制频谱 BRAM；
* 能量计算模块只写能量结果 BRAM；
* 两块 BRAM职责完全分离。
