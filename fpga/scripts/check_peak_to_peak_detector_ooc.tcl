# 峰峰值检测模块的OOC综合、时序和CDC检查脚本。
# 必须从fpga/work目录运行，报告和临时产物仅保留在该工作区。

set script_dir    [file dirname [file normalize [info script]]]
set expected_work [file normalize [file join $script_dir .. work]]
set current_work  [file normalize [pwd]]

if {$current_work ne $expected_work} {
    error "请从 fpga/work 目录运行此脚本，当前目录为：$current_work"
}

set rtl_file [file normalize [file join $script_dir .. src hdl peak_to_peak_detector.sv]]
read_verilog -sv $rtl_file

synth_design \
    -top peak_to_peak_detector \
    -part xc7z020clg400-2 \
    -mode out_of_context \
    -flatten_hierarchy rebuilt

# 当前按100 MHz业务时钟进行初步OOC时序约束；顶层集成后应使用实际FIR时钟复查。
create_clock -name clk -period 10.000 [get_ports clk]

set_input_delay -clock clk -max 0.000 \
    [get_ports {rst sample_data[*] sample_valid sample_first sample_last}]
set_input_delay -clock clk -min 0.000 \
    [get_ports {rst sample_data[*] sample_valid sample_first sample_last}]
set_output_delay -clock clk -max 0.000 \
    [get_ports {vpp_out[*] vpp_valid vpp_busy vpp_error}]
set_output_delay -clock clk -min 0.000 \
    [get_ports {vpp_out[*] vpp_valid vpp_busy vpp_error}]

report_utilization -file peak_to_peak_detector_utilization.rpt
report_timing_summary -delay_type max -max_paths 10 \
    -file peak_to_peak_detector_timing.rpt
check_timing -verbose -file peak_to_peak_detector_check_timing.rpt
report_cdc -details -file peak_to_peak_detector_cdc.rpt
