# af_cdc 默认参数的 OOC 综合、时序和 CDC 检查脚本。
# 必须从 fpga/work 目录运行，报告和临时产物仅保留在该工作区。

set script_dir    [file dirname [file normalize [info script]]]
set expected_work [file normalize [file join $script_dir .. work]]
set current_work  [file normalize [pwd]]

if {$current_work ne $expected_work} {
    error "请从 fpga/work 目录运行此脚本，当前目录为：$current_work"
}

set rtl_file [file normalize [file join $script_dir .. src hdl af_cdc.sv]]
read_verilog -sv $rtl_file

synth_design \
    -top af_cdc \
    -part xc7z020clg400-2 \
    -mode out_of_context \
    -flatten_hierarchy rebuilt

# 采用当前系统的 30 MHz 源域与 100 MHz 目标域进行模块级初步检查。
create_clock -name src_clk -period 33.333 [get_ports src_clk]
create_clock -name dst_clk -period 10.000 [get_ports dst_clk]
set_clock_groups -asynchronous \
    -group [get_clocks src_clk] \
    -group [get_clocks dst_clk]

report_utilization -file af_cdc_utilization.rpt
report_timing_summary \
    -delay_type max \
    -max_paths 10 \
    -file af_cdc_timing.rpt
check_timing -verbose -file af_cdc_check_timing.rpt
report_cdc -details -file af_cdc_cdc.rpt
