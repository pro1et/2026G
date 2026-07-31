# BRAM 地址映射总表

## 1. 文档用途

本文档是本工程中 PL、Block Design 和 PS 共同使用的 BRAM 地址与数据格式总表。

后续新增或修改任何 BRAM 时，必须同步更新本文档，至少记录：

1. BRAM 名称和用途；
2. 当前状态：已实现、已规划或待确认；
3. 数据宽度和深度；
4. PL 端使用字地址还是字节地址；
5. PS AXI 基地址和地址范围；
6. 每个地址对应的数据内容、位宽、符号和缩放方式；
7. 数据何时有效，以及 PS 何时允许读取；
8. 与旧版本不兼容的布局变化。

本文档中的“已实现”定义具有约束作用；“已规划”和“待确认”内容不能在 PS
代码中作为已经存在的硬件接口使用。

## 2. 地址术语

### 2.1 32 位字序号

本文档使用 `Wn` 表示第 `n` 个 32 位字：

```text
W0、W1、W2……
```

对于 PS 可见的 32 位 AXI BRAM，字节偏移为：

```text
byte_offset = word_index × 4
```

PS 访问地址为：

```text
ps_address = axi_base_address + byte_offset
```

例如 `W2` 的字节偏移为 `0x0008`。

### 2.2 PL 侧地址

当前时域 BRAM 的 PL 写接口采用 AXI BRAM Controller 兼容的字节地址：

```text
W0 -> 0x0000
W1 -> 0x0004
W2 -> 0x0008
```

PL 端地址必须四字节对齐，写完整 32 位字时：

```text
bram_en = 1
bram_we = 4'b1111
```

### 2.3 数据拼接顺序

两个 16 位时域样点拼成一个 32 位字时：

```text
bit[15:0]  = 时间较早的偶数序号样点
bit[31:16] = 时间较晚的奇数序号样点
```

即：

```systemverilog
bram_wrdata = {sample_odd, sample_even};
```

Zynq PS 按小端读取 32 位字时，仍应按上述位定义提取两个有符号样点。

## 3. PS 地址空间总览

| 名称 | 状态 | PS 基地址 | 地址范围 | 说明 |
|---|---|---:|---:|---|
| `TIME_BRAM` | 已实现 | `0x4200_0000` | `0x4200_0000`～`0x4201_FFFF` | 时域标量结果和原始波形 |
| `SPECTRUM_BRAM` | 已实现 | `0x4300_0000` | `0x4300_0000`～`0x4300_1FFF` | 4096 点实 FFT 的 2048 点正频率功率谱 |
| `ENERGY_RESULT_BRAM` | 已规划 | 待 BD 分配 | 待 BD 分配 | 基波、二次谐波、三次谐波结果 |

补充说明：

- 当前 `HMI Capture Control AXI` 位于 `0x44A0_0000`～`0x44A0_0FFF`，
  但它是 AXI-Lite 寄存器，不是 BRAM。
- 当前 `FFT_chain` BD 已将频谱 BRAM 正式分配到 `0x4300_0000`，地址范围
  为 8 KiB。
- 后续在 Vivado Address Editor 中分配新地址后，必须先更新本表，再更新 PS
  头文件或地址宏。

## 4. TIME_BRAM

### 4.1 当前状态

```text
状态：已实现
写入模块：measurement_bram_writer
PL 集成顶层：time_domain_amplitude_calibration
PS 读取模块：AXI BRAM Controller
```

当前硬件参数：

```text
数据宽度：32 bit
物理深度：32768 × 32 bit
物理容量：131072 Byte，即 128 KiB
PL 字节地址宽度：17 bit
PS AXI 基地址：0x4200_0000
PS AXI 高地址：0x4201_FFFF
```

一次采集的处理范围：

```text
参与 Vpp 计算：完整 65536 个样点
参与均方值计算：完整 65536 个样点
写入 BRAM 的波形：前 32768 个样点
```

### 4.2 正式布局

| 32 位字 | 字节偏移 | PS 绝对地址 | 字段 | 数据格式 |
|---:|---:|---:|---|---|
| W0 | `0x0000` | `0x4200_0000` | `vpp_raw` | 32 位无符号峰峰值码数 |
| W1 | `0x0004` | `0x4200_0004` | `mean_square_raw` | 32 位无符号均方值 |
| W2 | `0x0008` | `0x4200_0008` | 波形样点 0、1 | 两个有符号 S16 |
| W3 | `0x000C` | `0x4200_000C` | 波形样点 2、3 | 两个有符号 S16 |
| … | … | … | … | … |
| W16385 | `0x10004` | `0x4201_0004` | 波形样点 32766、32767 | 两个有符号 S16 |
| W16386～W32767 | `0x10008`～`0x1FFFC` | `0x4201_0008`～`0x4201_FFFC` | 未使用 | PS 不得依赖其内容 |

有效使用量：

```text
2 + 32768 / 2 = 16386 个 32 位字
16386 × 4 = 65544 Byte
```

### 4.3 字段定义

#### W0：峰峰值码数

`vpp_raw` 来自 `peak_to_peak_detector`：

- 输入为完整 65536 点有符号数据；
- 分成 16 段，每段 4096 点；
- 删除 2 个最大和 2 个最小的分段峰峰值；
- 对中间 12 个结果四舍五入平均；
- 输出数值尺度与输入 S16 样点一致；
- PL 不在此处执行电压标定。

PS 电压标定公式见 `时域幅度标定.md`。

#### W1：均方值

`mean_square_raw` 来自 `mean_square_calculator`：

```text
mean_square_raw =
round(sum(sample[n]²) / 65536)
```

这里保存的是均方值，不是已经开方的有效值。PS 必须执行：

```text
rms_code = integer_sqrt(mean_square_raw)
```

然后再使用与峰峰值相同的 `μV/code` 标定比例换算有效值。

如果输入仍包含直流偏置，该均方值对应包含直流分量的总 RMS。若比赛最终要求
纯交流 RMS，必须在进入本模块前完成去直流，并在本文件中记录新的数据格式。

#### W2 起：时域波形

每个样点为 16 位有符号二进制补码：

```text
sample[2n]   = signed(W[2+n][15:0])
sample[2n+1] = signed(W[2+n][31:16])
```

当前只保存完整 65536 点帧的前 32768 点。样点数是硬件/软件共同使用的编译期
常量，不再单独占用 BRAM 字。

### 4.4 数据有效时序

PS 必须通过 `HMI Capture Control AXI` 启动采集并等待：

```text
DONE = 1
BUSY = 0
ERROR = 0
```

`time_domain_amplitude_calibration.capture_done` 只能连接
`measurement_bram_writer.frame_done`。该完成脉冲表示：

1. W0 峰峰值已经实际写入；
2. W1 均方值已经实际写入；
3. 前 32768 个波形样点已经实际写入。

PS 不得在 `BUSY=1` 时把正在更新的 TIME_BRAM 当作完整新帧读取。

### 4.5 与旧布局的不兼容变化

旧验证布局曾定义：

```text
W0 = Vpp 占位
W1 = 均方值占位
W2 = 基频占位
W3 = sample_count
W4 起 = 波形
```

该布局已经废止。当前正式布局没有基频字和样点数字：

```text
W0 = Vpp
W1 = mean_square
W2 起 = 波形
```

PS 中所有旧的 `TIME_SAMPLE_COUNT_WORD=3` 和 `TIME_DATA_BASE_WORD=4` 定义
必须同步删除或修改。

## 5. SPECTRUM_BRAM

### 5.1 当前状态

```text
状态：已实现，已加入 FFT_chain BD
管理模块：spectrol
数据来源：FFT 输出功率计算
PL 集成顶层：fft_measurement_chain
PS 读取模块：AXI BRAM Controller 1
PS AXI 基地址：0x4300_0000
PS AXI 高地址：0x4300_1FFF
```

当前频域设计参数：

```text
FFT 输入采样率：2 MHz
FFT 点数：4096
实信号正频率有效下标：0～2047
频率分辨率：2000000 / 4096 = 488.28125 Hz
功率定义：P[k] = Re[k]² + Im[k]²
原始功率计算位宽：40 bit
频谱 BRAM 数据位宽（POWER_WIDTH）：32 bit
功率缩放：原始 U40 功率加 128 后右移 8 位，得到 U32
```

### 5.2 PL 内部谱线定义

频谱 BRAM 的逻辑字地址定义为：

| 谱线地址 `k` | 内容 | 对应频率 |
|---:|---|---|
| 0 | `P[0]`，直流分量 | 0 Hz |
| 1 | `P[1]` | 488.28125 Hz |
| … | … | … |
| 2047 | `P[2047]` | `2047 × 488.28125 Hz` |

通用关系：

```text
frequency_hz = k × 2000000 / 4096
```

该地址是 PL 内部谱线字地址，不等于 PS 字节地址。

### 5.3 PS 地址和数据布局

频谱 BRAM 没有状态字或头部，每个谱线占一个 32 位字：

```text
PS_address(k) = 0x4300_0000 + 4 × k
```

| PS 字序号 | 字节偏移 | PS 绝对地址 | 内容 | 位宽 |
|---:|---:|---:|---|---:|
| W0 | `0x0000` | `0x4300_0000` | `P[0]` | U32 |
| W1 | `0x0004` | `0x4300_0004` | `P[1]` | U32 |
| … | … | … | … | … |
| W2047 | `0x1FFC` | `0x4300_1FFC` | `P[2047]` | U32 |

Block Memory Generator 当前配置应满足：

```text
数据宽度：32 bit
有效深度：2048 words
有效容量：8192 Byte
Port A：PS / AXI BRAM Controller 1
Port B：PL / spectrol
```

### 5.4 当前 PS/HMI 显示处理

PS 必须先把 W0～W2047 全部读取到独立的 2048 点 U32 缓存。当前HMI频谱
横轴暂定显示 0～500 kHz，因此仅使用缓存中的 bin 0～1023 生成800点显示
缓存；bin 1024～2047仍保留在原始缓存中，但不进入当前绘图。第 `x` 个逻辑
显示点使用：

```text
start = floor(x × 1024 / 800)
end_exclusive = floor((x + 1) × 1024 / 800)
display_peak[x] = max(P[start ... end_exclusive - 1])
```

800 个桶分别包含连续的 1 个或 2 个谱线，完整且不重复地覆盖 bin 0～1023。
由于当前HMI波形控件每接收一个新点都在 `x=0` 写入并把旧点向右移动，PS在
传输前必须将800点逻辑数组倒序；这样最终屏幕仍保持低频在左、高频在右。

显示前允许按本帧最大桶值归一化到 HMI 数据高度，但该归一化只用于绘图：

- 不得覆盖 2048 点 U32 原始频谱缓存；
- 不得用 800 点显示缓存执行基频检测或谐波搜索；
- 不得把当前显示归一化值解释为电压；
- 后续频率、电压标定和谐波计算必须使用完整 2048 点数据或 PL 的正式
  结果 BRAM。

当前 `capture_done` 只在 `TIME_BRAM` 和 `SPECTRUM_BRAM` 都提交完整一帧后
才对 PS 可见，因此 PS 在 DONE 后读取两个 BRAM 可以得到同一帧的数据。

### 5.5 尚未冻结的事项

- HMI 频率横轴的最终有效显示范围；
- 频域纵轴的线性或对数显示方式；
- Hann 窗、FFT、FIR 和模拟前端共同作用下的频域电压标定；
- 基频与谐波结果 BRAM 的最终格式。

## 6. ENERGY_RESULT_BRAM

### 6.1 当前状态

```text
状态：已规划，尚未加入当前 Time_Calibration BD
写入模块：后续能量计算模块
数据宽度：32 bit
最小深度：16 个 32 位字
PS AXI 基地址：待分配
```

### 6.2 规划布局

| 32 位字 | 字节偏移 | 字段 | 说明 |
|---:|---:|---|---|
| W0 | `0x0000` | `status_word` | 状态、谐波存在掩码、位置有效掩码 |
| W1 | `0x0004` | `base_index_500` | 基波频率编号 |
| W2 | `0x0008` | `base_energy` | 基波缩放后能量 |
| W3 | `0x000C` | `harmonic2_index_500` | 二次谐波频率编号 |
| W4 | `0x0010` | `harmonic2_energy` | 二次谐波缩放后能量 |
| W5 | `0x0014` | `harmonic3_index_500` | 三次谐波频率编号 |
| W6 | `0x0018` | `harmonic3_energy` | 三次谐波缩放后能量 |
| W7 | `0x001C` | `energy_shift` | 当前规划固定为 3 |
| W8 | `0x0020` | `absolute_threshold` | 本次使用的绝对能量阈值 |
| W9 | `0x0024` | `ratio_parameter` | `{ratio_den[15:0], ratio_num[15:0]}` |
| W10～W15 | `0x0028`～`0x003C` | 保留 | 写 0 |

频率编号换算：

```text
frequency_hz = index_500 × 500 Hz
```

内部使用的 FFT bin 不写入该结果 BRAM。

### 6.3 status_word 规划

| 位 | 名称 | 含义 |
|---:|---|---|
| 0 | `result_valid` | 当前 BRAM 已保存完整新结果 |
| 1 | `busy` | 能量模块正在处理 |
| 2 | `energy_overflow` | 至少一个能量结果溢出或饱和 |
| 3 | `base_invalid` | 基频输入无效或基波窗口越界 |
| 4 | `threshold_invalid` | 谐波判断参数无效 |
| 5 | `read_error` | 频谱读取异常 |
| 7:6 | 保留 | 写 0 |
| 8 | `base_present` | 基波存在 |
| 9 | `harmonic2_present` | 二次谐波存在 |
| 10 | `harmonic3_present` | 三次谐波存在 |
| 11 | `base_position_valid` | 基波读取窗口有效 |
| 12 | `harmonic2_position_valid` | 二次谐波读取窗口有效 |
| 13 | `harmonic3_position_valid` | 三次谐波读取窗口有效 |
| 31:14 | 保留 | 写 0 |

写入顺序要求：

1. 新测量开始时先写 W0，令 `result_valid=0`、`busy=1`；
2. 写 W1～W9 和保留字段；
3. 最后再次写 W0，令 `busy=0`、`result_valid=1`；
4. PS 只有看到最终 `W0[0]=1` 后才允许读取 W1～W9。

该布局来自当前频域设计文档，在 RTL、BD 和 AXI 地址真正完成前仍属于“已规划”
而不是“已实现”。

## 7. PS 端实现要求

PS 代码不得散落硬编码的 BRAM 偏移。应在统一头文件中定义：

```c
#define TIME_BRAM_VPP_WORD          0U
#define TIME_BRAM_MEAN_SQUARE_WORD  1U
#define TIME_BRAM_DATA_BASE_WORD    2U
#define TIME_BRAM_SAMPLE_COUNT      32768U
```

未来加入频域 BRAM 后，也应按照本文件中的最终布局增加独立的：

```text
spectrum_bram_map.h
energy_result_bram_map.h
```

地址优先使用新平台生成的 `xparameters.h` 宏。只有在硬件地址已经冻结且平台宏
无法提供时，才允许在应用层定义绝对基地址。

## 8. 变更检查清单

每次 BRAM 布局变化必须同时检查：

1. 写 BRAM 的 RTL 地址；
2. Block Memory Generator 数据宽度和深度；
3. BRAM 接口地址宽度；
4. AXI BRAM Controller 配置；
5. Vivado Address Editor 基地址和范围；
6. XSA 和 Vitis platform；
7. `xparameters.h` 中的基地址；
8. PS BRAM map 头文件；
9. HMI 数据读取和显示逻辑；
10. testbench 中的期望地址和数据；
11. 本文档。

任何一项没有同步更新，都可能造成 PS 读取旧字段、错位拆包或越界访问。
