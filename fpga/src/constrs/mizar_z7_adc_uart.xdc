# =============================================================================
# 文件名称：mizar_z7_adc_uart.xdc
# 目标器件：XC7Z020-CLG400-2
# 开发板：Mizar Z7
# 当前顶层：Time_Calibration_wrapper
#
# 主要功能：
#   按 Time_Calibration_wrapper 的实际外部端口名称，约束 50 MHz 系统
#   时钟、PL 总复位键、双路 AD 模块和 HMI UART1 管脚。
#
# 参考来源：
#   E:/FPGA_PJ/Prepare/work/PL/constraints/pl_top_mizar_adda_hmi.xdc
#
# Time_Calibration_wrapper 实际端口：
#   clk_50m_0、rst_n_0                           -> 系统时钟和 PL 总复位
#   adc_data_a_0[9:0]、adc_clk_a_0、adc_oe_a_0 -> AD 通道 1
#   adc_data_b_0[9:0]、adc_clk_b_0、adc_oe_b_0 -> AD 通道 2
#   UART1_TX_0、UART1_RX_0                     -> PS UART1 的 EMIO 外部端口
#   DDR_*、FIXED_IO_*                          -> Zynq PS 专用接口，不在本文件约束
#
# 注意：
#   rst_n 使用 PL_KEY1/K4，按键松开为高、按下为低。
#   板载 K1 是连接 PS_POR_B 的系统硬复位，不属于普通 PL 可约束管脚。
#   UART1_TX_0 连接屏幕 RX；UART1_RX_0 连接屏幕 TX。
#   本文件不包含 DA、LED 或其他用户按键约束。
# =============================================================================

# -----------------------------------------------------------------------------
# 板载 50 MHz PL 系统时钟
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports {clk_50m_0}]
# clk_wiz_0.xdc already creates the 20 ns primary clock on this port.
# Do not create it again here; a duplicate definition causes XDCC-1/XDCC-7.

# -----------------------------------------------------------------------------
# PL 总复位键：PL_KEY1 / K4，R19，按下为低
# 直接连接 clock_tree.rst_n。
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports {rst_n_0}]

# -----------------------------------------------------------------------------
# 双路 AD 输入模块：JP2 / GPIO2
# -----------------------------------------------------------------------------

# AD 通道 1：D0_1～D9_1
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} [get_ports {adc_data_a_0[0]}]
set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS33} [get_ports {adc_data_a_0[1]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {adc_data_a_0[2]}]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports {adc_data_a_0[3]}]
set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS33} [get_ports {adc_data_a_0[4]}]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports {adc_data_a_0[5]}]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports {adc_data_a_0[6]}]
set_property -dict {PACKAGE_PIN G15 IOSTANDARD LVCMOS33} [get_ports {adc_data_a_0[7]}]
set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVCMOS33} [get_ports {adc_data_a_0[8]}]
set_property -dict {PACKAGE_PIN H20 IOSTANDARD LVCMOS33} [get_ports {adc_data_a_0[9]}]
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33} [get_ports {adc_clk_a_0}]
set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS33} [get_ports {adc_oe_a_0}]

# ADC-A is the channel currently retained by the measurement chain.  A FAST
# clock-output edge reduces the OBUF maximum delay while DRIVE 12 provides
# sufficient drive without the unnecessary switching current of DRIVE 16.
set_property SLEW FAST [get_ports {adc_clk_a_0}]
set_property DRIVE 12  [get_ports {adc_clk_a_0}]

# AD 通道 2：D0_2～D9_2
set_property -dict {PACKAGE_PIN K19 IOSTANDARD LVCMOS33} [get_ports {adc_data_b_0[0]}]
set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVCMOS33} [get_ports {adc_data_b_0[1]}]
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS33} [get_ports {adc_data_b_0[2]}]
set_property -dict {PACKAGE_PIN J16 IOSTANDARD LVCMOS33} [get_ports {adc_data_b_0[3]}]
set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS33} [get_ports {adc_data_b_0[4]}]
set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS33} [get_ports {adc_data_b_0[5]}]
set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS33} [get_ports {adc_data_b_0[6]}]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} [get_ports {adc_data_b_0[7]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {adc_data_b_0[8]}]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports {adc_data_b_0[9]}]
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports {adc_clk_b_0}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {adc_oe_b_0}]

# -----------------------------------------------------------------------------
# HMI UART1：PS UART1 经 EMIO 引出到 JP1 / GPIO1
# 屏幕 RX <- UART1_TX_0
# 屏幕 TX -> UART1_RX_0
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN T11 IOSTANDARD LVCMOS33} [get_ports {UART1_TX_0}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {UART1_RX_0}]

# -----------------------------------------------------------------------------
# ADC source-synchronous interface timing
#
# 3PA1030 publishes a 25 ns data-valid delay at CL=20 pF.  The max constraint
# below adds 1 ns for PCB clock/data skew.  No guaranteed minimum is published,
# so 0 ns is used as the conservative hold-side value.  At 32 MHz this leaves
# 5.25 ns before the next sampling edge.
# -----------------------------------------------------------------------------
create_generated_clock -name adc_clk_a_fwd \
    -source [get_pins -hierarchical -regexp \
        {^.*/u_adc_capture/u_oddr_clk_a/C$}] \
    -divide_by 1 [get_ports {adc_clk_a_0}]
set_input_delay -clock adc_clk_a_fwd -max 26.000 \
    [get_ports {adc_data_a_0[*]}]
set_input_delay -clock adc_clk_a_fwd -min 0.000 \
    [get_ports {adc_data_a_0[*]}]

create_generated_clock -name adc_clk_b_fwd \
    -source [get_pins -hierarchical -regexp \
        {^.*/u_adc_capture/u_oddr_clk_b/C$}] \
    -divide_by 1 [get_ports {adc_clk_b_0}]
set_input_delay -clock adc_clk_b_fwd -max 26.000 \
    [get_ports {adc_data_b_0[*]}]
set_input_delay -clock adc_clk_b_fwd -min 0.000 \
    [get_ports {adc_data_b_0[*]}]

# ADC OE is a reset/status control rather than a cycle-level synchronous data
# output.  The forwarded clocks are clocks, not data outputs to be setup-timed.
set_false_path -to [get_ports {adc_clk_a_0 adc_clk_b_0 adc_oe_a_0 adc_oe_b_0}]

# rst_n_0 is the asynchronous assertion source of the reset synchronizers.
# Reset release is handled by the two-flop chains in clock_tree.
set_false_path -from [get_ports {rst_n_0}]

# -----------------------------------------------------------------------------
# Custom single-bit CDC constraints
#
# Only the asynchronous source-to-first-stage paths are ignored.  The first
# synchronizer stage to the second remains timed, so placement and metastability
# resolution are still checked.  FIFO Generator keeps its own scoped CDC XDC.
# -----------------------------------------------------------------------------
set custom_cdc_stage0_pins [get_pins -hierarchical -quiet -regexp \
    {^.*/(req_sync_reg|ack_sync_reg|ready_sync_reg|busy_sync_reg|error_sync_reg|locked_sync_reg)\[0\]/D$}]
set top_status_cdc_stage0_pins [get_pins -hierarchical -quiet -regexp \
    {^.*/fifo_(capture_busy|frame_pending|ready|wr_error)_meta_reg/D$}]

set_false_path -to $custom_cdc_stage0_pins
set_false_path -to $top_status_cdc_stage0_pins

# PS FCLK_CLK0 and the PL Clock Wizard are independent 100 MHz sources.  All
# crossings between them are implemented with af_cdc or two-flop synchronizers.
set ps_clock_group \
    [get_clocks -quiet -include_generated_clocks {clk_fpga_0}]
set pl_clock_group \
    [get_clocks -quiet -include_generated_clocks {clk_50m_0}]
set_clock_groups -asynchronous \
    -group $ps_clock_group \
    -group $pl_clock_group
