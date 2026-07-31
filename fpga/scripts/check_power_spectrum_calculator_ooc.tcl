# 功率谱计算模块的OOC综合、资源和100 MHz时序检查。
# 必须从fpga/work目录运行，工程及报告全部保留在该工作区。

set script_dir    [file dirname [file normalize [info script]]]
set fpga_dir      [file normalize [file join $script_dir ..]]
set expected_work [file normalize [file join $fpga_dir work]]
set current_work  [file normalize [pwd]]

if {$current_work ne $expected_work} {
    error "请从fpga/work目录运行此脚本，当前目录为：$current_work"
}

set rtl_file [file normalize \
    [file join $fpga_dir src hdl power_spectrum_calculator.sv]]
set project_dir [file normalize \
    [file join $current_work power_spectrum_calculator_ooc_project]]

create_project power_spectrum_calculator_ooc $project_dir \
    -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]

add_files -norecurse $rtl_file
set_property file_type SystemVerilog [get_files $rtl_file]
set_property top power_spectrum_calculator [current_fileset]

launch_runs synth_1 -jobs 2
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
    error "功率谱计算模块综合失败，状态为：$synth_status"
}

open_run synth_1
create_clock -name clk -period 10.000 [get_ports clk]

set_input_delay -clock clk -max 0.000 \
    [get_ports {rst clear_error fft_re[*] fft_im[*] fft_bin[*] fft_valid fft_first fft_last power_ready}]
set_input_delay -clock clk -min 0.000 \
    [get_ports {rst clear_error fft_re[*] fft_im[*] fft_bin[*] fft_valid fft_first fft_last power_ready}]
set_output_delay -clock clk -max 0.000 \
    [get_ports {fft_ready power_data[*] power_bin[*] power_valid power_first power_last fft_frame_done power_frame_done protocol_error}]
set_output_delay -clock clk -min 0.000 \
    [get_ports {fft_ready power_data[*] power_bin[*] power_valid power_first power_last fft_frame_done power_frame_done protocol_error}]

report_utilization -hierarchical \
    -file [file join $current_work power_spectrum_calculator_utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $current_work power_spectrum_calculator_timing.rpt]
check_timing -verbose \
    -file [file join $current_work power_spectrum_calculator_check_timing.rpt]

puts "POWER_SPECTRUM_CALCULATOR_OOC_CHECK_PASSED"
close_project
