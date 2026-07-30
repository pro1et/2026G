
一、模块设计指导

1. 模块定位

创建：

measurement_bram_writer.sv

模块负责将以下三路数据写入同一块 32 位 BRAM：

Vpp：32 位无符号数；
Vrms：32 位无符号数；
FIR 波形：前 32768 个有效输出点，每点为 16 位有符号数，每两个点拼成一个 32 位字。

模块只负责：

数据锁存
波形拼接
BRAM写仲裁
地址生成
完成状态产生

不要在模块内部实现：

AXI协议
AXI寄存器
PS中断
Block Memory Generator实例

BRAM IP 应由顶层或 Block Design 实例化。

2. 固定 BRAM 数据布局

无论单路测试还是三路联合工作，地址布局始终保持不变。

32 位字序号	PS 字节偏移	内容
0	0x0000	Vpp
1	0x0004	Vrms
2	0x0008	波形样本 0、1
3	0x000C	波形样本 2、3
……	……	……
16385	0x10004	波形样本 32766、32767

波形拼接顺序固定为：

bram_wrdata[15:0]  = wave_sample[2*n];
bram_wrdata[31:16] = wave_sample[2*n+1];

即时间上较早的数据放在低 16 位：

bram_wrdata = {wave_data, sample_hold};

总共使用：

2+32768/2=16386

个 32 位字，即 65544 Byte。

3. 推荐模块接口
   module measurement_bram_writer #(
   parameter int WAVE_SAMPLE_COUNT = 32768,
   parameter int BRAM_ADDR_WIDTH   = 17
   ) (
   input  logic                clk,
   input  logic                rst,

   // 启动一次新的写入过程
   input  logic                start,

   // bit[0]：启用Vpp
   // bit[1]：启用Vrms
   // bit[2]：启用波形
   input  logic [2:0]          channel_enable,

   // Vpp输入
   input  logic [31:0]         vpp_data,
   input  logic                vpp_valid,

   // Vrms输入
   input  logic [31:0]         vrms_data,
   input  logic                vrms_valid,

   // FIR波形输入
   input  logic signed [15:0]  wave_data,
   input  logic                wave_valid,

   // 状态输出
   output logic                busy,
   output logic                frame_done,
   output logic                vpp_done,
   output logic                vrms_done,
   output logic                wave_done,
   output logic                error,

   // BRAM写端口
   output logic                bram_en,
   output logic [3:0]          bram_we,
   output logic [BRAM_ADDR_WIDTH-1:0] bram_addr,
   output logic [31:0]         bram_wrdata
   );

所有端口和内部关键寄存器均使用详细中文注释。

4. 通道选择

channel_enable 在 start 到来时锁存，之后本帧过程中不再改变：

active_mask <= channel_enable;

模式定义：

channel_enable	工作模式
3'b001	只写 Vpp
3'b010	只写 Vrms
3'b100	只写波形
3'b011	写 Vpp 和 Vrms
3'b111	三路全部写入

3'b000 视为非法模式，可以拒绝启动并置 error。

未启用通道：

不锁存其输入；
不写对应地址；
不参与 frame_done 判断。

这样不需要为了单路测试创建不同版本的核心模块。

5. Vpp 和 Vrms 的处理

由于 Vpp、Vrms 可能在任意时间到达，必须在 valid 出现时立即锁存：

logic [31:0] vpp_reg;
logic [31:0] vrms_reg;

logic vpp_pending;
logic vrms_pending;

处理原则：

vpp_valid到达
    ↓
立即保存到vpp_reg
    ↓
vpp_pending置1
    ↓
等待BRAM空闲后写地址0

Vrms 同理，写入地址 1。

即使 valid 只持续一个时钟周期，也不会丢失数据。

6. 波形拼接

只在：

wave_valid == 1'b1

时统计一个有效波形样本。

内部需要：

logic signed [15:0] sample_hold;
logic [15:0]        sample_count;
logic [14:0]        wave_word_count;

处理过程：

偶数编号样本：
    保存到sample_hold
    不访问BRAM

奇数编号样本：
    将当前样本与sample_hold拼成32位
    写入BRAM

写入地址为：

wave_word_index = 2 + wave_word_count;

如果 BRAM 接口使用字节地址：

bram_addr = wave_word_index << 2;

因此：

第一个波形字：0x0008
第二个波形字：0x000C
……
最后一个波形字：0x10004

捕获满 32768 个有效样本后：

wave_done <= 1'b1;

之后忽略额外的波形数据。

7. BRAM 写仲裁

每个时钟最多执行一次 BRAM 写操作，优先级固定为：

1. 波形32位拼接数据
2. 待写入的Vpp
3. 待写入的Vrms
4. BRAM不写

波形只在收到奇数编号样本时实际占用 BRAM 写口。

例如波形连续有效时：

时钟0：暂存样本0，可写Vpp或Vrms
时钟1：写样本0、1
时钟2：暂存样本2，可写Vpp或Vrms
时钟3：写样本2、3

因此 Vpp 和 Vrms 可以利用波形拼接产生的空闲周期完成写入。

每个周期默认：

bram_en <= 1'b0;
bram_we <= 4'b0000;

发生完整 32 位写入时：

bram_en <= 1'b1;
bram_we <= 4'b1111;
8. 完成条件

完成条件只检查本次启用的通道：

all_enabled_channels_done =
    (!active_mask[0] || vpp_done ) &&
    (!active_mask[1] || vrms_done) &&
    (!active_mask[2] || wave_done);

例如只测试波形时：

wave_done = 1
Vpp和Vrms未启用
    ↓
允许产生frame_done

不要固定等待三路，否则单路测试时模块无法结束。

9. 状态机

采用简单的三个状态即可：

IDLE
  等待start
  ↓

CAPTURE
  接收三路输入
  完成波形拼接和BRAM写入
  等待所有启用通道写完
  ↓

FINISH
  frame_done拉高一个时钟周期
  ↓

IDLE

行为要求：

IDLE
busy=0
接受 start
锁存 channel_enable
清除计数器和完成标志
CAPTURE
busy=1
接收并写入数据
忽略新的 start，或者将 error 置位
FINISH
busy=0
frame_done=1
只保持一个 clk 周期
下一周期返回 IDLE

应保证 frame_done 出现在最后一次 BRAM 写操作完成之后。

后续 AXI 状态模块负责将这个单周期脉冲锁存为 PS 可以轮询的状态位。

10. 地址表示方式

建议模块内部始终使用“32 位字序号”：

logic [14:0] word_index;

地址定义：

localparam int VPP_WORD_ADDR   = 0;
localparam int VRMS_WORD_ADDR  = 1;
localparam int WAVE_WORD_BASE  = 2;

连接到 BRAM 时再统一转换。

BRAM 使用字地址
bram_addr = word_index;
BRAM 使用字节地址
bram_addr = word_index << 2;

后面推荐的 BRAM Controller 配置采用字节地址，因此建议最终接口输出字节地址。

Block Memory Generator/Embedded Memory Generator 的“Generate Byte-Wide Address”用于决定地址是按字节还是按存储字生成，默认通常启用字节地址。

二、BRAM IP 核配置

1. 总体连接
   PS
   │
   AXI
   │
   AXI BRAM Controller
   │
   Port A
   │
   Block Memory Generator
   │
   Port B
   │
   measurement_bram_writer

分工为：

Port A：PS通过AXI读取
Port B：PL汇总模块写入

应选择 True Dual Port RAM。真双口 RAM 的两个端口可以独立访问同一存储阵列；Vivado 的连接自动化也支持将已有的 BMG 配置成真双口并连接到 AXI BRAM Controller。

2. Block Memory Generator 配置

不同 Vivado 版本中可能显示为：

Block Memory Generator

或者：

Embedded Memory Generator

推荐配置如下。

Basic / 基本配置
配置项	设置
Operating Mode	Memory Controller / BRAM Controller
Memory Type	True Dual Port RAM
Memory Primitive	BRAM
Generate Byte-Wide Address	Enabled
ECC	No ECC
Initialization File	None
Algorithm	Minimum Area 或 Auto

Memory Controller 模式本身就是为 AXI BRAM Controller 或 LMB Controller 配套设计的；在该模式下，宽度和深度通常由控制器设置以及 Address Editor 中的地址范围生成。

3. 数据宽度

Port A 和 Port B 均配置为：

Write Width：32
Read Width：32

不使用非对称端口宽度。

Byte Write Enable

建议启用：

Byte Write Enable：Enabled
Byte Size：8 bit

这样写使能为：

bram_we[3:0]

当前模块每次完整写入 32 位，因此始终使用：

bram_we = 4'b1111;

虽然当前不需要局部字节写入，但这种接口与 AXI BRAM Controller 的 32 位数据通路更容易匹配。

4. BRAM 深度

实际需求是：

16386 × 32 bit

但采用标准 AXI 地址空间和最简单配置时，建议分配：

32768 × 32 bit

即：

128 KiB

地址范围：

0x00000 ～ 0x1FFFF

实际只使用：

0x00000 ～ 0x10007

其中最后一个 32 位字的起始地址是：

0x10004

之所以使用 128 KiB，是因为 64 KiB 只能容纳 16384 个 32 位字，而本设计需要 16386 个字，超出了 8 Byte。

这种配置比较浪费 BRAM，但最适合开发初期，因为：

地址空间规整；
AXI Address Editor 配置简单；
不需要特殊地址适配；
单路和联合测试都使用同一个 BRAM。

若后续 BRAM 资源紧张，再考虑：

Vpp、Vrms 改放 AXI 状态寄存器；
或使用可配置精确深度的独立存储器模式；
或改用外部 DDR。
5. 时钟配置
Port A 和 Port B 使用同一时钟

选择：

Clocking Mode：Common Clock

例如两者都使用：

FCLK_CLK0 = 100 MHz

这是最简单的方案。

Port A 和 Port B 使用不同时钟

选择：

Clocking Mode：Independent Clock

例如：

Port A：AXI时钟
Port B：FIR数据处理时钟

官方配置说明规定：两个端口由同一个时钟缓冲驱动时选择 Common Clock，否则选择 Independent Clock。

但需要注意：

Vpp、Vrms、波形输入必须已经处于写入模块的 clk 时钟域；
frame_done 送入 AXI 时钟域时必须进行 CDC；
PS 不应在 PL 正在覆盖同一地址时读取。

初期最好让写入模块也运行在 AXI 所使用的 PL 时钟域，降低调试难度。

6. 读写模式和延迟

推荐：

Port A Read Latency：1
Port B Read Latency：1

Port B 的读数据没有使用，可以悬空。

WRITE_FIRST、READ_FIRST 或 NO_CHANGE 对当前设计影响不大，因为：

Port A 只供 PS 读取；
Port B 只供 PL 写入；
系统协议应避免 PS 和 PL 同时访问正在更新的地址。

可以保持 IP 默认值，不要依赖同地址同时读写的具体结果。读延迟配置决定 douta/doutb 在多少个对应端口时钟后有效。

三、AXI BRAM Controller 配置

添加：

AXI BRAM Controller

推荐配置：

配置项	设置
AXI Data Width	32 bit
Number of BRAM Interfaces	1
ECC	Disabled
AXI Protocol	保持默认 AXI4
BRAM Port	连接 BMG Port A

波形数据较多，保留 AXI4 突发访问比只使用 AXI4-Lite 逐字读取更合适。

在 Address Editor 中给该 BRAM 分配：

Range：128K

基地址由 Vivado 自动分配，例如：

0x4000_0000

则 PS 端读取地址为：

Vpp         ：BASE + 0x0000
Vrms        ：BASE + 0x0004
波形样本0/1 ：BASE + 0x0008
最后一组波形：BASE + 0x10004
四、Port B 信号连接

写入模块连接到 BMG Port B：

measurement_bram_writer.clk
    → clkb

measurement_bram_writer.bram_en
    → enb

measurement_bram_writer.bram_we[3:0]
    → web[3:0]

measurement_bram_writer.bram_addr
    → addrb

measurement_bram_writer.bram_wrdata
    → dinb

Port B 的：

doutb

不使用。

如果 IP 暴露的是 32 位地址，而模块只输出低 17 位，可以：

assign bram_addr_32 = {{15{1'b0}}, bram_addr_17};

不要依靠隐式截断。Vivado 允许连接不同位宽的端口，并会只连接低位，但可能产生位宽警告；最好在 wrapper 中显式补零。

五、开发测试要求

至少建立以下测试：

只测试 Vpp
channel_enable = 3'b001;

检查：

BRAM[0]写入正确
frame_done正常产生
模块不等待Vrms和波形
只测试 Vrms
channel_enable = 3'b010;

检查 BRAM 字节偏移 0x0004。

只测试波形
channel_enable = 3'b100;

输入递增数据：

0，1，2，3，4，5……

预期：

地址0x0008：32'h0001_0000
地址0x000C：32'h0003_0002
地址0x0010：32'h0005_0004
三路联合测试
channel_enable = 3'b111;

随机改变：

Vpp 到达时刻；
Vrms 到达时刻；
wave_valid 中的空拍。

检查：

波形数据不丢失；
相邻样本顺序正确；
Vpp、Vrms 最终均写入；
frame_done 只出现一次；
frame_done 出现在最后一次 BRAM 写入之后。

最终结构保持为：

measurement_bram_writer
    只处理数据与BRAM写入

Block Memory Generator
    提供双口存储

AXI BRAM Controller
    提供PS读BRAM能力

后续AXI状态模块
    锁存frame_done并供PS读取
