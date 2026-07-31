# 使用真实xfft_0 IP完成fft_4096_wrapper的OOC综合、资源和100 MHz时序检查。
# 必须从fpga/work目录运行，全部工程与报告均保留在该工作区。

set script_dir    [file dirname [file normalize [info script]]]
set fpga_dir      [file normalize [file join $script_dir ..]]
set expected_work [file normalize [file join $fpga_dir work]]
set current_work  [file normalize [pwd]]

if {$current_work ne $expected_work} {
    error "请从fpga/work目录运行此脚本，当前目录为：$current_work"
}

set rtl_file   [file normalize [file join $fpga_dir src hdl fft_4096_wrapper.sv]]
set source_xci [file normalize [file join $fpga_dir src ip xfft_0 xfft_0.xci]]

set project_dir [file normalize [file join $current_work fft_4096_wrapper_ooc_project]]
create_project fft_4096_wrapper_ooc $project_dir -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -norecurse $rtl_file
set_property file_type SystemVerilog [get_files $rtl_file]
set_property top fft_4096_wrapper [current_fileset]

import_ip -files $source_xci -name xfft_0
generate_target synthesis [get_ips xfft_0]

launch_runs synth_1 -jobs 2
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
    error "fft_4096_wrapper综合失败，状态为：$synth_status"
}

open_run synth_1
create_clock -name clk -period 10.000 [get_ports clk]

set_input_delay -clock clk -max 0.000 \
    [get_ports {rst clear_error window_data[*] window_valid window_first window_last fft_ready}]
set_input_delay -clock clk -min 0.000 \
    [get_ports {rst clear_error window_data[*] window_valid window_first window_last fft_ready}]
set_output_delay -clock clk -max 0.000 \
    [get_ports {window_ready fft_re[*] fft_im[*] fft_bin[*] fft_valid fft_first fft_last config_done protocol_error channel_halt}]
set_output_delay -clock clk -min 0.000 \
    [get_ports {window_ready fft_re[*] fft_im[*] fft_bin[*] fft_valid fft_first fft_last config_done protocol_error channel_halt}]

report_utilization -hierarchical \
    -file [file join $current_work fft_4096_wrapper_utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $current_work fft_4096_wrapper_timing.rpt]
check_timing -verbose \
    -file [file join $current_work fft_4096_wrapper_check_timing.rpt]

puts "FFT_4096_WRAPPER_REAL_IP_CHECK_PASSED"
close_project
