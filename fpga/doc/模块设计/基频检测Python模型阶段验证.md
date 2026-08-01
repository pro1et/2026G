# 基频检测 Python 模型阶段验证

## 1. 本阶段范围

本阶段只建立和验证 Python 参考模型，不修改任何 RTL、Vivado IP、Block
Design 或 `work` 工程文件。待算法和真实板级频谱数据验证通过、用户确认后，
再设计 Verilog/SystemVerilog 状态机。

模型直接读取工程中的真实系数：

- `fir_coe_128.coe`
- `hann_4096_half_q15.coe`

完整数值链路为：

```text
32 MHz ADC S16
→ 129 tap FIR（Q19系数、舍入、S16饱和）
→ 16倍抽取
→ 4096点周期Hann窗（Q1.15）
→ 4096点FFT
→ FFT结果右移9位、收敛舍入到S20
→ Re²+Im²
→ 功率右移8位、舍入到U32
→ 正频率bin 0～2047
```

基频有效范围只检查 bin 20～1024，约对应 10 kHz～500 kHz。

## 2. 现有算法复现出的根因

现有 PL 算法从低频向高频寻找第一个 7-bin 邻域能量局部峰。仿真确认其有
三个结构性问题：

1. 7-bin 能量适合衡量谱峰强度，但不适合确定谱峰位置。Hann 主瓣被7点滑窗
   后会形成平台或偏移，容易把基频位置报告到真实峰左侧。
2. 固定能量阈值 `500` 对输入幅度变化不鲁棒，弱基波经定点缩放后会直接
   被漏掉。
3. “第一个可信峰”会把低频噪声、泄漏或伪峰当作基波，并且不检查后续峰
   是否具有整数谐波关系。

这与板上观察到的约 500 Hz 或 1 kHz 偏低，以及含谐波帧偶发检测失败相符。

## 3. 当前候选模型

候选模型保留7-bin能量用于强度判断，但用原始功率谱 `P[k]` 的局部最大值
确定频率位置。

处理步骤：

1. 顺序扫描 bin 20～1024，识别原始功率谱局部峰或平台中心。
2. 同时计算每个候选峰的7-bin邻域能量。
3. 将频带按64个bin分块，取最安静完整块的平均功率作为噪声底估计。
   该结构在RTL中只需要累加器、比较器和右移，不需要中位数排序器。
4. 保存能量最大的最多24个候选峰。
5. 对每个候选基频检查2次及以上整数倍位置是否存在候选峰。
6. 谐波匹配容差随次数增加，以覆盖FFT整数bin取整的必然误差：

   ```text
   tolerance(order) = max(2, ceil((order + 1) / 2)) bin
   ```

7. 优先选择获得最多谐波支持的候选；支持数相同时再参考总能量/SNR，并
   轻微偏向较低频候选。
8. 对标定用纯正弦，如果没有任何谐波支持，只允许能量达到更严格门限的
   最强孤立峰作为单频结果。
9. 最终频率仍输出500 Hz整数编号：

   ```text
   base_index_500 = round(125 × base_bin / 128)
   frequency = base_index_500 × 500 Hz
   ```

关键点是“定位”和“测能量”分离：原始单bin峰负责频率，7-bin累加负责
抗泄漏的能量判断。

### 3.1 输入、输出与固定参数

算法输入为一帧正频率功率谱：

```text
power[k] = Re[k]² + Im[k]²经过PL缩放后的U32结果
k = 0～2047
```

实际基频搜索范围：

```text
VALID_MIN_BIN = 20
VALID_MAX_BIN = 1024
```

对应频率约为10 kHz～500 kHz。bin 0～19不参与基频判断，bin 1025～2047
也不参与基频判断。

当前 Python 模型冻结的参数为：

| 参数 | 数值 | 含义 |
|---|---:|---|
| `WINDOW_RADIUS` | 3 | 候选峰左右各累加3根谱线 |
| `WINDOW_SIZE` | 7 | 邻域能量总谱线数 |
| `NOISE_BLOCK_SIZE` | 64 | 噪声估计分块长度 |
| `NOISE_MULTIPLIER` | 12 | 噪声能量门限倍率 |
| `ABSOLUTE_THRESHOLD` | 1 | 最低候选能量门限 |
| `MAX_CANDIDATES` | 24 | 最多保存的候选峰数 |
| `MINIMUM_BASE_ENERGY` | 2 | 含谐波候选的最低基波能量 |
| `MINIMUM_SUPPORTED_ENERGY` | 16 | 极弱基波所需的谐波支持能量 |
| `SINGLE_TONE_THRESHOLD` | 16 | 纯单频回退门限 |

输出为：

```text
base_valid
base_bin
base_index_500
base_energy
```

其中 `base_energy` 是以最终 `base_bin` 为中心的7-bin能量。

### 3.2 7-bin邻域能量

先对全部正频率谱线计算：

\[
E_7[k]=\sum_{i=-3}^{3}P[k+i]
\]

实现时需要使用足够宽的无符号累加器，不能让7个U32加法溢出。Python模型
使用U64。最终是否压缩或饱和，应在RTL设计阶段根据结果BRAM位宽决定。

必须注意：`E7[k]`只用于判断谱峰强弱，不能用 `E7[k]` 的局部峰位置作为
频率位置。

### 3.3 原始功率谱局部峰检测

频率位置直接在原始功率谱 `P[k]` 上寻找。

普通局部峰满足：

```text
P[k] > P[k-1]
P[k] > P[k+1]
```

如果连续若干bin功率相等，形成平台：

```text
P[start] = P[start+1] = ... = P[end]
```

只有同时满足：

```text
P[start] > P[start-1]
P[end]   > P[end+1]
```

才把它视为一个谱峰，峰位置取平台中心：

```text
peak_bin = floor((start + end) / 2)
```

局部峰判断可以读取边界外的相邻bin，但加入候选表前必须再次检查：

```text
20 <= peak_bin <= 1024
```

这条检查用于防止9 kHz或9.5 kHz峰通过单频回退被误报为有效基频。

### 3.4 硬件友好的噪声底估计

不采用需要大量排序资源的中位数算法。将搜索频带从bin 20开始按64个bin
划分完整块：

```text
block_sum[j] = sum(P[20 + 64j ... 20 + 64j + 63])
```

当前范围包含15个完整块，共960根谱线；末尾不足64点的部分不参与噪声
估计，但仍参与候选峰检测。

取能量最小的完整块：

```text
quiet_block_sum = min(block_sum[j])
noise_power     = quiet_block_sum / 64
noise_energy_7  = noise_power * 7
```

候选峰能量门限为：

```text
candidate_threshold =
    max(ABSOLUTE_THRESHOLD,
        NOISE_MULTIPLIER * noise_energy_7)
```

即当前参数下：

```text
candidate_threshold = max(1, 12 * 7 * quiet_block_sum / 64)
```

RTL中除以64可直接右移6位。正式RTL必须明确乘法、右移的先后顺序及舍入
规则，并在与Python逐拍比较时保持一致。

### 3.5 建立候选峰表

一个原始功率谱局部峰只有满足：

```text
E7[peak_bin] > candidate_threshold
```

才是可信候选峰。

所有可信候选按 `E7` 从大到小排序，只保留能量最大的24个：

```text
candidate_bin[0 ... candidate_count-1]
candidate_energy[0 ... candidate_count-1]
candidate_count <= 24
```

RTL不需要对全部1005个bin排序。顺序扫描时维护一个长度24的有序插入表
即可，扫描结束后候选表已经按能量降序排列。

### 3.6 谐波位置预测与匹配容差

依次把候选表中的每个峰当作潜在基频 `candidate_bin`。检查二次及以上整数
谐波：

```text
expected_bin = candidate_bin * order
order = 2, 3, 4, ...
```

最高检查次数为：

```text
max_order = floor(1024 / candidate_bin) + 1
```

这里额外检查一次是为了覆盖边界取整情况。例如100 kHz可能定位在bin 205，
其五倍为1025，但真实500 kHz谐波仍可能定位在bin 1024。

第 `order` 次谐波的允许误差为：

```text
tolerance(order) =
    max(2, ceil((order + 1) / 2)) bin
```

等价整数形式为：

```text
tolerance = max(2, (order + 2) / 2向下取整)
```

在候选表中寻找：

```text
abs(candidate_peak_bin - expected_bin) <= tolerance
```

若范围内有多个候选峰，选择7-bin能量最大的一个作为该次谐波。每个
`order` 最多记一次支持。

容差随次数增加的原因是：基频本身从连续频率取整到整数bin时最多有约
0.5 bin误差，该误差在第N次谐波位置会被放大约N倍。

### 3.7 含谐波候选的有效条件

对每个潜在基频统计：

```text
support_count  = 匹配到的不同谐波次数数量
support_energy = 所有匹配谐波的7-bin能量之和
base_energy    = E7[candidate_bin]
```

它必须同时满足：

```text
support_count >= 1
base_energy >= 2
```

当基波能量处于极弱边界：

```text
base_energy < 3
```

还必须满足：

```text
support_energy >= 16
```

该附加条件允许“能量2的弱基波＋明显强谐波”通过，同时拒绝“能量2的
噪声峰＋能量2的另一个噪声峰”偶然形成整数倍关系。

### 3.8 多个基频候选之间的选择

Python模型当前使用的评分为：

\[
score =
1000\times support\_count
+\ln\left(1+\frac{base\_energy+support\_energy}
{\max(1,noise\_energy_7)}\right)
+\frac{1}{1+candidate\_bin}
\]

含义为：

1. `support_count` 权重最高，优先选择能解释更多谱峰的候选。
2. 支持数相同时，优先选择基波与谐波总能量更强的候选。
3. 前两项相同或非常接近时，轻微偏向较低频率，避免把高次谐波当成基波。

RTL无需实现对数。因为同一帧的噪声分母相同，对数也是单调函数，可以使用
如下整数优先级比较，作为硬件等价实现：

```text
优先级1：support_count更大
优先级2：base_energy + support_energy更大
优先级3：candidate_bin更小
```

RTL实现前，需要用Python把浮点评分切换为上述字典序比较，再重新运行全部
回归，以冻结软件模型和RTL的逐项一致行为。

### 3.9 纯单频回退

标定输入可能是没有任何谐波的纯正弦。如果所有候选都没有通过谐波一致性
判断，则允许执行一次单频回退：

```text
single_peak = 候选表中7-bin能量最大的峰
```

只有满足：

```text
E7[single_peak] >= 16
```

才输出该峰为基频。否则输出 `base_valid=0`。

因此，普通噪声中的微小孤立峰不会被当成标定单频；较强的标定正弦仍可
正常检测。

### 3.10 频率输出换算

最终选定的频率位置必须使用原始功率谱峰位置 `base_bin`，不能使用7-bin
能量窗口的位置。

500 Hz编号换算为：

```text
base_index_500 = floor((125 * base_bin + 64) / 128)
base_frequency = base_index_500 * 500 Hz
```

该换算对应：

\[
f = base\_bin\times\frac{2\,MHz}{4096}
\]

再舍入到最接近的500 Hz整数编号。

### 3.11 完整伪代码

```text
输入：power[0...2047]
输出：base_valid, base_bin, base_index_500, base_energy

1. 对power计算每个bin的7点能量E7。
2. 扫描bin 20...1024：
   a. 统计每个完整64-bin块的block_sum；
   b. 在原始power上检测局部峰/平台中心；
   c. 暂存局部峰位置及E7。
3. quiet_block_sum = 所有完整块block_sum的最小值。
4. threshold = max(1, 12 * 7 * quiet_block_sum / 64)。
5. 删除E7 <= threshold或超出20...1024范围的峰。
6. 按E7降序保留最多24个候选峰。
7. best_valid = 0。
8. 对每个候选candidate_bin：
   a. base_energy = E7[candidate_bin]；
   b. 从order=2开始检查整数倍位置；
   c. tolerance = max(2, ceil((order+1)/2))；
   d. 在候选表中找expected_bin±tolerance内能量最大的峰；
   e. 累加support_count与support_energy；
   f. 若support_count=0，跳过；
   g. 若base_energy<2，跳过；
   h. 若base_energy<3且support_energy<16，跳过；
   i. 按“支持数、总能量、低频优先”更新best候选。
9. 若存在best候选，输出best。
10. 否则检查候选表最强峰：
    a. 若其E7>=16，按纯单频输出；
    b. 否则输出base_valid=0。
11. 对有效结果计算：
    base_index_500 = (125*base_bin + 64) >> 7。
```

### 3.12 异常和边界行为

- 候选表为空：`base_valid=0`。
- 只有微弱噪声峰：`base_valid=0`。
- 只有足够强的单频峰：通过单频回退输出。
- 基波弱但至少一个谐波明显：通过谐波支持输出基波。
- 多个谐波比基波更强：优先选择能解释最多整数倍峰的低阶候选。
- 10 kHz以下的峰：不能进入候选表。
- 500 kHz以上的峰：不能作为基频或有效谐波候选。
- 500 kHz边界谐波：允许通过最后一次越界预测和容差匹配到bin 1024。
- 所有累加、乘法和地址计算必须在RTL中显式扩位，禁止依赖默认表达式位宽。

## 4. 验证结果

### 4.1 快速频域随机验证

用例：

- 定向边界/谐波/噪声用例：30组
- 随机有效基波加1～2个谐波：10000组
- 随机噪声、直流、10 kHz以下和500 kHz以上无效输入：10000组

结果：

| 指标 | 现有算法 | 候选模型 |
|---|---:|---:|
| 应输出有效的用例 | 10028 | 10028 |
| ±1 kHz内通过 | 0 | 10028 |
| 通过率 | 0% | 100% |
| 最大频率误差 | 不适用/大量误检 | 523.61 Hz |
| 平均绝对误差 | 168105.45 Hz | 166.05 Hz |
| 平均有符号误差 | +168105.45 Hz | -12.83 Hz |
| 无效输入误报 | 635 | 0 |

现有算法“±1 kHz内通过为0”并非完全不产生 `base_valid`，而是其437次
有效输出都被7-bin窗口边缘或错误低频峰带到了允许误差以外。

### 4.2 完整32 MHz定点链路

完整执行真实 FIR、抽取、Hann、FFT量化和功率缩放：

| 指标 | 结果 |
|---|---:|
| 有效用例 | 528 |
| ±1 kHz内通过 | 528 |
| 通过率 | 100% |
| 最大绝对误差 | 548.97 Hz |
| 平均有符号误差 | -9.61 Hz |
| 无效输入误报 | 0 |
| ADC削顶用例 | 0 |

这说明快速2 MHz模型没有掩盖FIR帧首瞬态或定点缩放造成的系统性偏差。

### 4.3 边界和FFT栅格压力测试

| 测试 | 用例数 | ±1 kHz内通过 | 最大误差 |
|---|---:|---:|---:|
| 10～500 kHz纯单频均匀扫描 | 1001 | 1001 | 480 Hz |
| 弱基波12 code、强谐波150 code，2～5次谐波 | 1604 | 1604 | 500 Hz |

额外完整链路定向测试中，在基波加谐波存在时叠加200 code、1～15 MHz
单频干扰，所测基频均正确；只有高频干扰而没有有效带内信号时未产生
基频有效结果。

### 4.4 灵敏度

在强谐波为100 code、随机2～5次谐波的条件下：

- 基波峰值12 code时，在0～16 code RMS噪声下为100%通过。
- 基波峰值10 code时，通过率约86%～95.5%。
- 基波峰值8 code时处于量化过渡区，通过率约39.5%～49.5%。
- 基波峰值6 code及以下通常无法稳定检测。

这里的 code 是 FIR 输出并送入抽取/FFT的有符号样点峰值，不是输入端mV。
最终必须用板级标定数据确认赛题最小输入在该节点能达到多少code。

## 5. 当前结论与确认门槛

当前候选模型已经消除现有算法的系统性左偏，并在合成用例中满足赛题
±1 kHz要求。它使用的主要结构均可实现为顺序BRAM扫描状态机，但还不能
立即搬到Vivado，尚需完成：

1. 从板上导出若干检测成功和检测失败帧的2048点 `SPECTRUM_BRAM` 原始值。
2. 用 Python 原样回放这些U32数据，确认候选模型能修复真实失败帧。
3. 覆盖10 kHz、接近500 kHz、弱基波强谐波、频率不落整bin和高频干扰。
4. 根据真实噪声底确定绝对能量门限、单频回退门限和最多候选数。
5. 用户确认模型后，才冻结RTL接口、状态机周期和结果BRAM协议。

## 6. 复现实验

目录：

```text
fpga/tools/base_detector_model
```

命令：

```powershell
.\.venv\Scripts\Activate.ps1
$env:MPLCONFIGDIR="$PWD\.matplotlib"
python -m pytest -q
python run_validation.py --random-cases 10000 --invalid-cases 10000
python run_full_validation.py --random-cases 500 --invalid-cases 500
python run_stress_validation.py
```

详细结果位于 `fpga/tools/base_detector_model/results`。
