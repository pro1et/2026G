# 使用真实hann_rom_0 IP完成行为仿真、OOC综合、资源和100 MHz时序检查。
# 必须从fpga/work目录运行，全部工程与报告均保留在该工作区。

set script_dir    [file dirname [file normalize [info script]]]
set fpga_dir      [file normalize [file join $script_dir ..]]
set expected_work [file normalize [file join $fpga_dir work]]
set current_work  [file normalize [pwd]]

if {$current_work ne $expected_work} {
    error "请从fpga/work目录运行此脚本，当前目录为：$current_work"
}

set rtl_file   [file normalize [file join $fpga_dir src hdl hann_window_4096.sv]]
set tb_file    [file normalize [file join $fpga_dir src sim hann_window_4096_tb.sv]]
set source_xci [file normalize [file join $fpga_dir src ip hann_rom_0 hann_rom_0.xci]]

set project_dir [file normalize [file join $current_work hann_window_4096_ip_project]]
create_project hann_window_4096_ip $project_dir -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -norecurse $rtl_file
set_property file_type SystemVerilog [get_files $rtl_file]
set_property top hann_window_4096 [current_fileset]

import_ip -files $source_xci -name hann_rom_0
generate_target all [get_ips hann_rom_0]

add_files -fileset sim_1 -norecurse $tb_file
set_property file_type SystemVerilog [get_files $tb_file]
set_property top hann_window_4096_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property verilog_define {USE_REAL_HANN_ROM} [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]

launch_simulation -mode behavioral
close_sim

launch_runs synth_1 -jobs 2
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
    error "hann_window_4096综合失败，状态为：$synth_status"
}

open_run synth_1
create_clock -name clk -period 10.000 [get_ports clk]
set_input_delay -clock clk -max 0.000 \
    [get_ports {rst clear_error sample_data[*] sample_valid sample_first sample_last window_ready}]
set_input_delay -clock clk -min 0.000 \
    [get_ports {rst clear_error sample_data[*] sample_valid sample_first sample_last window_ready}]
set_output_delay -clock clk -max 0.000 \
    [get_ports {sample_ready window_data[*] window_valid window_first window_last protocol_error}]
set_output_delay -clock clk -min 0.000 \
    [get_ports {sample_ready window_data[*] window_valid window_first window_last protocol_error}]

report_utilization -hierarchical \
    -file [file join $current_work hann_window_4096_utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $current_work hann_window_4096_timing.rpt]
check_timing -verbose \
    -file [file join $current_work hann_window_4096_check_timing.rpt]

puts "HANN_WINDOW_REAL_IP_CHECK_PASSED"
close_project
