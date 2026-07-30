# =============================================================================
# 文件名称：mizar_z7_adc_uart.xdc
# 目标器件：XC7Z020-CLG400-2
# 开发板：Mizar Z7
#
# 主要功能：
#   约束 50 MHz 系统时钟、PL 总复位键、双路 AD 模块和 HMI UART1 管脚。
#
# 参考来源：
#   E:/FPGA_PJ/Prepare/work/PL/constraints/pl_top_mizar_adda_hmi.xdc
#
# 顶层端口命名要求：
#   clk_50m、rst_n                         -> 系统时钟和 PL 总复位
#   adc_data_a[9:0]、adc_clk_a、adc_oe_a -> AD 通道 1
#   adc_data_b[9:0]、adc_clk_b、adc_oe_b -> AD 通道 2
#   UART1_TX_0、UART1_RX_0               -> PS UART1 的 EMIO 外部端口
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
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports clk_50m]
create_clock -period 20.000 -name clk_50m [get_ports clk_50m]

# -----------------------------------------------------------------------------
# PL 总复位键：PL_KEY1 / K4，R19，按下为低
# 直接连接 clock_tree.rst_n。
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports rst_n]

# -----------------------------------------------------------------------------
# 双路 AD 输入模块：JP2 / GPIO2
# -----------------------------------------------------------------------------

# AD 通道 1：D0_1～D9_1
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} [get_ports {adc_data_a[0]}]
set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS33} [get_ports {adc_data_a[1]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {adc_data_a[2]}]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports {adc_data_a[3]}]
set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS33} [get_ports {adc_data_a[4]}]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports {adc_data_a[5]}]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports {adc_data_a[6]}]
set_property -dict {PACKAGE_PIN G15 IOSTANDARD LVCMOS33} [get_ports {adc_data_a[7]}]
set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVCMOS33} [get_ports {adc_data_a[8]}]
set_property -dict {PACKAGE_PIN H20 IOSTANDARD LVCMOS33} [get_ports {adc_data_a[9]}]
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33} [get_ports adc_clk_a]
set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS33} [get_ports adc_oe_a]

# AD 通道 2：D0_2～D9_2
set_property -dict {PACKAGE_PIN K19 IOSTANDARD LVCMOS33} [get_ports {adc_data_b[0]}]
set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVCMOS33} [get_ports {adc_data_b[1]}]
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS33} [get_ports {adc_data_b[2]}]
set_property -dict {PACKAGE_PIN J16 IOSTANDARD LVCMOS33} [get_ports {adc_data_b[3]}]
set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS33} [get_ports {adc_data_b[4]}]
set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS33} [get_ports {adc_data_b[5]}]
set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS33} [get_ports {adc_data_b[6]}]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} [get_ports {adc_data_b[7]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {adc_data_b[8]}]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports {adc_data_b[9]}]
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports adc_clk_b]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports adc_oe_b]

# -----------------------------------------------------------------------------
# HMI UART1：PS UART1 经 EMIO 引出到 JP1 / GPIO1
# 屏幕 RX <- UART1_TX_0
# 屏幕 TX -> UART1_RX_0
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN T11 IOSTANDARD LVCMOS33} [get_ports UART1_TX_0]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports UART1_RX_0]
