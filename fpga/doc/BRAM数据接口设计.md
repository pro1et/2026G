# PS/PL BRAM 数据接口设计

## 1. 总体方案

系统使用两块 32 bit BRAM：

| BRAM | 内容 | 有效数据规模 |
| --- | --- | ---: |
| Time BRAM | Vpp、Vrms 平方、基频、32768 个时域点 | 16388 个 32 bit 字 |
| Spectrum BRAM | 有效峰表、1024 个频谱图点 | 520 个 32 bit 字 |

为了减少空间，每两个 16 bit 波形点打包为一个 32 bit BRAM 字。BRAM 中不保存 magic、版本号、状态、时间戳等信息。测量启动、忙和完成状态通过 AXI-Lite 寄存器传递。

所有地址表中的 `Wn` 表示第 n 个 32 bit 字：

```text
AXI byte offset = Wn * 4
```

## 2. 固定数据格式

### 2.1 时域数据

- 每个时域点为 16 bit 有符号二补码；
- 数值单位是 PL 算法使用的原始码值；
- PS 使用标定系数将原始码值转换为 mV；
- 时域数据固定为 32768 点；
- `time_sample[0]` 应从上升过零点开始。

第 i 个 32 bit 数据字的打包方式：

```text
bit 15:0  = time_sample[2*i]
bit 31:16 = time_sample[2*i+1]
```

PS 解包：

```c
int16_t s0 = (int16_t)(word & 0xFFFFU);
int16_t s1 = (int16_t)(word >> 16);
```

### 2.2 Vpp 和 Vrms 平方

`Vpp_raw` 与时域点使用相同的原始码值单位：

```text
Vpp_raw = max(sample) - min(sample)
```

PL 写入的是均方值，不是平方和：

```text
Vrms_sq_raw = round(sum(sample[n]^2) / 32768)
```

输入已完成直流偏置去除时，PS 计算：

```text
Vrms_raw = sqrt(Vrms_sq_raw)
Vrms_mV  = Vrms_raw * calibration_mV_per_code
```

16 bit 有符号点的平方最大不超过 30 bit，因此 `Vrms_sq_raw` 使用一个 32 bit 无符号字即可。

### 2.3 频谱图数据

- 每个频谱图点为 16 bit 无符号数；
- 频谱图点仅用于相对幅度绘图；
- 可以保存线性幅值或功率值，但整个系统必须固定使用一种定义；
- 当前按 PL 输出的 16 bit 功率值保存；
- 两个频谱点打包到一个 32 bit 字。

```text
bit 15:0  = spectrum_point[2*i]
bit 31:16 = spectrum_point[2*i+1]
```

谱峰表中的 `peak_amp_raw` 必须是可标定为输入电压的线性幅值，不能直接填 16 bit 功率值。若谱峰搜索基于功率完成，应在 PL 或 PS 中完成开根号、FFT 缩放及 Hamming 窗相干增益补偿后，再生成 `peak_amp_raw`。

## 3. Time BRAM

### 3.1 地址表

| 字地址 | 字节偏移 | 字段 | 格式 | 说明 |
| ---: | ---: | --- | --- | --- |
| W0 | 0x0000 | `vpp_raw` | U32 | 峰峰值原始码值 |
| W1 | 0x0004 | `vrms_sq_raw` | U32 | 32768 点均方值 |
| W2 | 0x0008 | `f1_hz` | U32 | 基频，单位 Hz |
| W3 | 0x000C | `sample_count` | U32 | 固定为 32768 |
| W4～W16387 | 0x0010～0x1000C | `time_data` | 2 x S16/word | 32768 个时域点 |

最后一个有效字为 W16387，总有效容量：

```text
4 + 32768 / 2 = 16388 words
16388 * 4 = 65552 bytes
```

### 3.2 建议 BRAM 配置

```text
Port A/Port B width = 32 bit
Memory depth        >= 16388 words
Recommended depth   = 16388 words
```

如果工程流程要求使用 2 的幂深度，可配置为 32768 x 32 bit；其中 W16388～W32767 不使用。

PL 端每接收两个 16 bit 样点后写一个 32 bit 字。

### 3.3 PS 选择 1 周期和 3 周期

BRAM 中保存的是完整 32768 点采集数据，不需要另外保存 1 周期或 3 周期副本。

设：

```text
Fs = 32 MHz
period_samples = Fs / f1_hz
```

显示 1 周期时，从 `time_sample[0]` 起选择约 `period_samples` 点并重采样为 480 个 HMI 点；显示 3 周期时选择约 `3*period_samples` 点并重采样为 480 个 HMI 点。

10 kHz 测试信号：

```text
period_samples = 32,000,000 / 10,000 = 3200
1 周期读取范围 = sample[0...3199]
3 周期读取范围 = sample[0...9599]
```

PS 使用相位累加或线性插值映射到 480 点，不要使用固定整数抽取倍数。

## 4. Spectrum BRAM

### 4.1 地址表

| 字地址 | 字节偏移 | 字段 | 格式 | 说明 |
| ---: | ---: | --- | --- | --- |
| W0 | 0x0000 | `peak_count` | U32 | 有效峰数，范围 0～3 |
| W1 | 0x0004 | `f1_hz` | U32 | 第 1 个峰的频率 |
| W2 | 0x0008 | `a1_raw` | U32 | 第 1 个峰的线性幅值 |
| W3 | 0x000C | `f2_hz` | U32 | 第 2 个峰的频率 |
| W4 | 0x0010 | `a2_raw` | U32 | 第 2 个峰的线性幅值 |
| W5 | 0x0014 | `f3_hz` | U32 | 第 3 个峰的频率 |
| W6 | 0x0018 | `a3_raw` | U32 | 第 3 个峰的线性幅值 |
| W7 | 0x001C | `spectrum_count` | U32 | 固定为 1024 |
| W8～W519 | 0x0020～0x081C | `spectrum_data` | 2 x U16/word | 1024 个频谱图点 |

未使用的峰槽必须把频率和幅值都写 0。峰表按频率由低到高排列；由于输入仅由基波和谐波组成，第一个有效峰通常为基波。

总有效容量：

```text
8 + 1024 / 2 = 520 words
520 * 4 = 2080 bytes
```

### 4.2 建议 BRAM 配置

```text
Port A/Port B width = 32 bit
Memory depth        >= 520 words
Recommended depth   = 1024 words
```

1024 x 32 bit 总容量为 4 KiB，W520～W1023 不使用。

## 5. 频谱点与频率对应关系

ADC 采样率为 32 MHz，16 倍抽取后：

```text
FFT Fs = 32 MHz / 16 = 2 MHz
FFT size = 4096
bin_width = 2 MHz / 4096
          = 488.28125 Hz
```

保存自然顺序 FFT 输出的 bin 0～1023：

```text
spectrum_point[i] 对应频率 = i * 488.28125 Hz
0 <= i <= 1023
```

最高频率：

```text
1023 * 488.28125 Hz = 499511.71875 Hz
```

因此 1024 点覆盖 0～499.51171875 kHz，可近似表述为 0～500 kHz。恰好 500 kHz 位于 bin 1024；当前协议不保存该点。

FFT IP 必须配置为自然顺序输出。若输出为位倒序，不能直接截取前 1024 个输出点。

16 倍抽取前必须完成抗混叠滤波；否则 1 MHz 以上干扰可能在抽取后混叠到 0～500 kHz 测量带内。

## 6. PL/PS 使用时序

BRAM 中不保存状态。AXI-Lite 至少提供：

| 信号/寄存器位 | 方向 | 说明 |
| --- | --- | --- |
| `start` | PS -> PL | 启动一次测量 |
| `busy` | PL -> PS | PL 正在采集或处理 |
| `done` | PL -> PS | 两块 BRAM 均已写完 |
| `error` | PL -> PS | 数据通路溢出或处理失败 |

推荐流程：

1. PS 写 `start=1`；
2. PL 清除 `done`，置 `busy`；
3. PL 写两个 BRAM 的头部和数据；
4. PL 完成全部写入后清 `busy`、置 `done`；
5. PS 只在 `done=1` 时读取；
6. PS 读取期间不再次启动测量；
7. 页面切换只重用 PS 缓存，不要求 PL 重写 BRAM。

该规则保证不需要在 BRAM 中加入 valid、版本号或帧号。

## 7. 10 kHz、100 mVpp HMI 测试值

最小 HMI 验证可临时规定：

```text
1 raw code = 1 mV
```

测试信号：

```text
sample[n] = round(50 * sin(2*pi*10000*n/30000000))
0 <= n < 32768
```

Time BRAM 头部：

```text
W0 Vpp_raw       = 100
W1 Vrms_sq_raw   = 1250
W2 f1_hz         = 10000
W3 sample_count  = 32768
```

因为：

```text
Vpeak = 50 mV
Vrms = 50 / sqrt(2) = 35.355339 mV
Vrms^2 = 1250 mV^2
```

Spectrum BRAM 头部：

```text
W0 peak_count     = 1
W1 f1_hz          = 10000
W2 a1_raw         = 50
W3...W6           = 0
W7 spectrum_count = 1024
```

PS 应显示：

```text
Vpp  = 0.100 V
Vrms = 0.0354 V
f1   = 10000 Hz
A1   = 0.050 V
```

## 8. HMI 绘图

### 8.1 时域

- PS 解包 32768 个 S16 点；
- 根据 32 MHz 和 BRAM 中的 `f1_hz` 计算周期长度；
- 选择 1 周期或 3 周期；
- 重采样为 480 点；
- 映射到 0～230；
- 当前时域页面逐点发送 `add s0.id,0,value`。

### 8.2 频域

- PS 解包 1024 个 U16 点；
- 将 1024 点按区间最大值压缩为 480 点；
- 按本帧最大功率值归一化到 0～230；
- 当前频域页面逐点发送 `add s0.id,0,value`。

使用区间最大值而不是固定隔点抽取，可以防止窄谱峰在 1024 到 480 点压缩时消失。
