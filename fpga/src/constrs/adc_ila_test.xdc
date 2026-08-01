# =============================================================================
# Minimal ADC + ILA test constraints for ADC_ILA_test_wrapper.
# Expected BD external ports:
#   clk_50m_0, rst_n_0, adc_data_a_0[13:0], adc_clk_a_0
# The ADS6149 returned clock is intentionally unused.
# =============================================================================

set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} \
    [get_ports {clk_50m_0}]

set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} \
    [get_ports {rst_n_0}]

set_property -dict {PACKAGE_PIN H18 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a_0[0]}]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a_0[1]}]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a_0[2]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a_0[3]}]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a_0[4]}]
set_property -dict {PACKAGE_PIN K14 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a_0[5]}]
set_property -dict {PACKAGE_PIN G15 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a_0[6]}]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a_0[7]}]
set_property -dict {PACKAGE_PIN H20 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a_0[8]}]
set_property -dict {PACKAGE_PIN J20 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a_0[9]}]
set_property -dict {PACKAGE_PIN L15 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a_0[10]}]
set_property -dict {PACKAGE_PIN L14 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a_0[11]}]
set_property -dict {PACKAGE_PIN J19 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a_0[12]}]
set_property -dict {PACKAGE_PIN K19 IOSTANDARD HSTL_II_18} [get_ports {adc_data_a_0[13]}]

set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS33} \
    [get_ports {adc_clk_a_0}]
set_property -dict {SLEW FAST DRIVE 12 OFFCHIP_TERM NONE} \
    [get_ports {adc_clk_a_0}]

set_property INTERNAL_VREF 0.9 [get_iobanks 34]
set_property INTERNAL_VREF 0.9 [get_iobanks 35]

set_false_path -to [get_ports {adc_clk_a_0}]
set_false_path -from [get_ports {rst_n_0}]

