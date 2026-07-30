# fir_wrap默认参数及真实FIR Compiler IP的OOC综合和时序检查脚本。
# 必须从fpga/work目录运行；IP生成物和报告仅保留在该工作区。

set script_dir    [file dirname [file normalize [info script]]]
set expected_work [file normalize [file join $script_dir .. work]]
set current_work  [file normalize [pwd]]

if {$current_work ne $expected_work} {
    error "请从 fpga/work 目录运行此脚本，当前目录为：$current_work"
}

set rtl_file   [file normalize [file join $script_dir .. src hdl fir_wrap.sv]]
set source_xci [file normalize [file join $script_dir .. src ip fir_compiler_0.xci]]

set project_dir [file normalize [file join $current_work fir_wrap_ooc_project]]
create_project fir_wrap_ooc $project_dir -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]

add_files -norecurse $rtl_file
set_property file_type SystemVerilog [get_files $rtl_file]
set_property top fir_wrap [current_fileset]

# import_ip会把XCI和由COE生成的输出产物限制在fpga/work临时工程中。
import_ip -files $source_xci -name fir_compiler_0
generate_target synthesis [get_ips fir_compiler_0]
create_ip_run [get_ips fir_compiler_0]
launch_runs fir_compiler_0_synth_1 -jobs 2
wait_on_run fir_compiler_0_synth_1

set ip_run_status [get_property STATUS [get_runs fir_compiler_0_synth_1]]
if {![string match "*Complete*" $ip_run_status]} {
    error "fir_compiler_0独立综合失败，状态为：$ip_run_status"
}

synth_design \
    -top fir_wrap \
    -part xc7z020clg400-2 \
    -mode out_of_context \
    -flatten_hierarchy rebuilt

create_clock -name clk -period 10.000 [get_ports clk]

set_input_delay -clock clk -max 0.000 \
    [get_ports {rst clear_error fir_data[*] fir_valid fir_first fir_last}]
set_input_delay -clock clk -min 0.000 \
    [get_ports {rst clear_error fir_data[*] fir_valid fir_first fir_last}]
set_output_delay -clock clk -max 0.000 \
    [get_ports {fir_ready sample_data[*] sample_valid sample_first sample_last fir_frame_done busy protocol_error saturation_error}]
set_output_delay -clock clk -min 0.000 \
    [get_ports {fir_ready sample_data[*] sample_valid sample_first sample_last fir_frame_done busy protocol_error saturation_error}]

report_utilization -hierarchical -file fir_wrap_utilization.rpt
report_timing_summary -delay_type max -max_paths 10 \
    -file fir_wrap_timing.rpt
check_timing -verbose -file fir_wrap_check_timing.rpt
report_cdc -details -file fir_wrap_cdc.rpt
