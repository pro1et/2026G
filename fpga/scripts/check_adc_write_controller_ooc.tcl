# ADC 写控制器默认参数的 OOC 综合、时序和 CDC 检查脚本。
# 必须从 fpga/work 目录运行，报告和临时产物仅保留在该工作区。

set script_dir    [file dirname [file normalize [info script]]]
set expected_work [file normalize [file join $script_dir .. work]]
set current_work  [file normalize [pwd]]

if {$current_work ne $expected_work} {
    error "请从 fpga/work 目录运行此脚本，当前目录为：$current_work"
}

set rtl_file [file normalize [file join $script_dir .. src hdl adc_write_controller.sv]]
read_verilog -sv $rtl_file

synth_design \
    -top adc_write_controller \
    -part xc7z020clg400-2 \
    -mode out_of_context \
    -flatten_hierarchy rebuilt

# 当前设计基线为 30 MHz；33.333 ns 约束仅用于模块级初步时序检查。
create_clock -name clk -period 33.333 [get_ports clk]

report_utilization \
    -file adc_write_controller_utilization.rpt
report_timing_summary \
    -delay_type max \
    -max_paths 10 \
    -file adc_write_controller_timing.rpt
check_timing \
    -verbose \
    -file adc_write_controller_check_timing.rpt
report_cdc \
    -details \
    -file adc_write_controller_cdc.rpt
