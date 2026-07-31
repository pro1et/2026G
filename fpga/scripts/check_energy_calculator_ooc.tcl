# 能量计算模块的OOC综合、资源和100 MHz时序检查。
# 必须从fpga/work目录运行，工程及报告全部保留在该工作区。

set script_dir    [file dirname [file normalize [info script]]]
set fpga_dir      [file normalize [file join $script_dir ..]]
set expected_work [file normalize [file join $fpga_dir work]]
set current_work  [file normalize [pwd]]

if {$current_work ne $expected_work} {
    error "请从fpga/work目录运行此脚本，当前目录为：$current_work"
}

set rtl_file [file normalize \
    [file join $fpga_dir src hdl energy_calculator.sv]]
set project_dir [file normalize \
    [file join $current_work energy_calculator_ooc_project]]

create_project energy_calculator_ooc $project_dir \
    -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]

add_files -norecurse $rtl_file
set_property file_type SystemVerilog [get_files $rtl_file]
set_property top energy_calculator [current_fileset]

launch_runs synth_1 -jobs 2
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
    error "能量计算模块综合失败，状态为：$synth_status"
}

open_run synth_1
create_clock -name clk -period 10.000 [get_ports clk]

set_input_delay -clock clk -max 0.000 \
    [get_ports {rst start base_valid base_index_500[*] absolute_threshold[*] ratio_num[*] ratio_den[*] mem_ready mem_rvalid mem_rdata[*]}]
set_input_delay -clock clk -min 0.000 \
    [get_ports {rst start base_valid base_index_500[*] absolute_threshold[*] ratio_num[*] ratio_den[*] mem_ready mem_rvalid mem_rdata[*]}]
set_output_delay -clock clk -max 0.000 \
    [get_ports {busy done mem_req mem_addr[*] result_bram_en result_bram_we result_bram_addr[*] result_bram_din[*] harmonic_present_mask[*] position_valid_mask[*] result_valid energy_overflow}]
set_output_delay -clock clk -min 0.000 \
    [get_ports {busy done mem_req mem_addr[*] result_bram_en result_bram_we result_bram_addr[*] result_bram_din[*] harmonic_present_mask[*] position_valid_mask[*] result_valid energy_overflow}]

report_utilization -hierarchical \
    -file [file join $current_work energy_calculator_utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $current_work energy_calculator_timing.rpt]
check_timing -verbose \
    -file [file join $current_work energy_calculator_check_timing.rpt]

set worst_path [get_timing_paths -delay_type max -max_paths 1]
if {[llength $worst_path] == 0} {
    error "未找到可用于100 MHz检查的时序路径"
}
set worst_slack [get_property SLACK $worst_path]
if {$worst_slack < 0.0} {
    error "能量计算模块未满足100 MHz时序，WNS为${worst_slack} ns"
}

puts "ENERGY_CALCULATOR_OOC_CHECK_PASSED"
close_project
