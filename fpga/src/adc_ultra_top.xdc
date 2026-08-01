# adc_ultra_top / Mizar Z7 (xc7z020clg400-2) 管脚约束。
# ADC 转接板位于 GPIO2/JP2，DAC 转接板位于 GPIO1/JP1。

# 板载50 MHz时钟与低有效复位。
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports clk_50m]
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports rst_n]
set_false_path -from [get_ports rst_n]

# -----------------------------------------------------------------------------
# ADC / GPIO2：严格采用 AD_DA_Test 的数据位、发送时钟和返回时钟定义。
# 通道A：adc_data_a[13:0] 对应参考工程 adc0_data[13:0]。
set_property -dict {PACKAGE_PIN K19 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a[13]}]
set_property -dict {PACKAGE_PIN J19 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a[12]}]
set_property -dict {PACKAGE_PIN L14 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a[11]}]
set_property -dict {PACKAGE_PIN L15 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a[10]}]
set_property -dict {PACKAGE_PIN J20 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a[9]}]
set_property -dict {PACKAGE_PIN H20 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a[8]}]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a[7]}]
set_property -dict {PACKAGE_PIN G15 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a[6]}]
set_property -dict {PACKAGE_PIN K14 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a[5]}]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a[4]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a[3]}]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a[2]}]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a[1]}]
set_property -dict {PACKAGE_PIN H18 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a[0]}]
set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS33}    [get_ports adc_clk_a]
set_property -dict {PACKAGE_PIN L20 IOSTANDARD HSTL_II_18} [get_ports adc_clk_return_a]

# 通道B：adc_data_b[13:0] 对应参考工程 adc1_data[13:0]。
set_property -dict {PACKAGE_PIN N16 IOSTANDARD HSTL_II_18} [get_ports {adc_data_b[0]}]
set_property -dict {PACKAGE_PIN N15 IOSTANDARD HSTL_II_18} [get_ports {adc_data_b[1]}]
set_property -dict {PACKAGE_PIN P16 IOSTANDARD HSTL_II_18} [get_ports {adc_data_b[2]}]
set_property -dict {PACKAGE_PIN P15 IOSTANDARD HSTL_II_18} [get_ports {adc_data_b[3]}]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD HSTL_II_18} [get_ports {adc_data_b[4]}]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD HSTL_II_18} [get_ports {adc_data_b[5]}]
set_property -dict {PACKAGE_PIN V18 IOSTANDARD HSTL_II_18} [get_ports {adc_data_b[6]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD HSTL_II_18} [get_ports {adc_data_b[7]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD HSTL_II_18} [get_ports {adc_data_b[8]}]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD HSTL_II_18} [get_ports {adc_data_b[9]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD HSTL_II_18} [get_ports {adc_data_b[10]}]
set_property -dict {PACKAGE_PIN T14 IOSTANDARD HSTL_II_18} [get_ports {adc_data_b[11]}]
set_property -dict {PACKAGE_PIN R14 IOSTANDARD HSTL_II_18} [get_ports {adc_data_b[12]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD HSTL_II_18} [get_ports {adc_data_b[13]}]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33}    [get_ports adc_clk_b]
set_property -dict {PACKAGE_PIN L16 IOSTANDARD HSTL_II_18} [get_ports adc_clk_return_b]

set_property INTERNAL_VREF 0.9 [get_iobanks 34]
set_property INTERNAL_VREF 0.9 [get_iobanks 35]
set_property -dict {SLEW FAST DRIVE 12 OFFCHIP_TERM NONE} [get_ports {adc_clk_a adc_clk_b}]

# L20/L16不是专用时钟管脚；与参考工程一致，允许返回时钟使用普通I/O路由。
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports adc_clk_return_a]]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports adc_clk_return_b]]
create_clock -name adc_return_a -period 31.250 [get_ports adc_clk_return_a]
create_clock -name adc_return_b -period 31.250 [get_ports adc_clk_return_b]

# 数据由各自返回时钟捕获。精确 set_input_delay 必须结合 ADS6149 的 SEN 配置、
# 转接板走线和板级实测结果确定；目前不虚构 max/min 数值。

# -----------------------------------------------------------------------------
# DAC / GPIO1：保持原工程双路10位 DAC 管脚分配。
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports dac_clk_a]
set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVCMOS33} [get_ports {dac_data_a[0]}]
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS33} [get_ports {dac_data_a[1]}]
set_property -dict {PACKAGE_PIN T20 IOSTANDARD LVCMOS33} [get_ports {dac_data_a[2]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {dac_data_a[3]}]
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports {dac_data_a[4]}]
set_property -dict {PACKAGE_PIN P20 IOSTANDARD LVCMOS33} [get_ports {dac_data_a[5]}]
set_property -dict {PACKAGE_PIN N20 IOSTANDARD LVCMOS33} [get_ports {dac_data_a[6]}]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {dac_data_a[7]}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {dac_data_a[8]}]
set_property -dict {PACKAGE_PIN P19 IOSTANDARD LVCMOS33} [get_ports {dac_data_a[9]}]

set_property -dict {PACKAGE_PIN W20 IOSTANDARD LVCMOS33} [get_ports dac_clk_b]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {dac_data_b[0]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {dac_data_b[1]}]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {dac_data_b[2]}]
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports {dac_data_b[3]}]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports {dac_data_b[4]}]
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports {dac_data_b[5]}]
set_property -dict {PACKAGE_PIN Y17 IOSTANDARD LVCMOS33} [get_ports {dac_data_b[6]}]
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33} [get_ports {dac_data_b[7]}]
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} [get_ports {dac_data_b[8]}]
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports {dac_data_b[9]}]

set_property -dict {SLEW FAST DRIVE 12} [get_ports {dac_clk_a dac_clk_b}]
set_property -dict {SLEW FAST DRIVE 8}  [get_ports {dac_data_a[*] dac_data_b[*]}]
