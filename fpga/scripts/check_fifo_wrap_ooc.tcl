# fifo_wrap 默认参数及真实 FIFO IP 的 OOC 综合、时序和 CDC 检查脚本。
# 必须从 fpga/work 目录运行；IP 生成物和报告仅保留在该工作区。

set script_dir    [file dirname [file normalize [info script]]]
set expected_work [file normalize [file join $script_dir .. work]]
set current_work  [file normalize [pwd]]

if {$current_work ne $expected_work} {
    error "请从 fpga/work 目录运行此脚本，当前目录为：$current_work"
}

set wrapper_file [file normalize [file join $script_dir .. src hdl fifo_wrap.v]]
set write_file   [file normalize [file join $script_dir .. src hdl adc_write_controller.sv]]
set cdc_file     [file normalize [file join $script_dir .. src hdl af_cdc.sv]]
set read_file    [file normalize [file join $script_dir .. src hdl fifo_ctrl.sv]]
set source_xci [file normalize [file join $script_dir .. src ip fifo_generator_0 fifo_generator_0.xci]]

# 临时工程明确指定 Zynq-7020，并用 import_ip 把所有 IP 生成物限制在 work 内。
set project_dir [file normalize [file join $current_work fifo_wrap_ooc_project]]
create_project fifo_wrap_ooc $project_dir -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]

add_files -norecurse [list $wrapper_file $write_file $cdc_file $read_file]
set_property file_type SystemVerilog [get_files [list $write_file $cdc_file $read_file]]
set_property top fifo_wrap [current_fileset]

import_ip -files $source_xci -name fifo_generator_0
generate_target synthesis [get_ips fifo_generator_0]
create_ip_run [get_ips fifo_generator_0]
launch_runs fifo_generator_0_synth_1 -jobs 2
wait_on_run fifo_generator_0_synth_1

set ip_run_status [get_property STATUS [get_runs fifo_generator_0_synth_1]]
if {![string match "*Complete*" $ip_run_status]} {
    error "fifo_generator_0 独立综合失败，状态为：$ip_run_status"
}

synth_design \
    -top fifo_wrap \
    -part xc7z020clg400-2 \
    -mode out_of_context \
    -flatten_hierarchy rebuilt

create_clock -name wr_clk -period 33.333 [get_ports wr_clk]
create_clock -name rd_clk -period 10.000 [get_ports rd_clk]
set_clock_groups -asynchronous \
    -group [get_clocks wr_clk] \
    -group [get_clocks rd_clk]

report_utilization -hierarchical -file fifo_wrap_utilization.rpt
report_timing_summary \
    -delay_type max \
    -max_paths 10 \
    -file fifo_wrap_timing.rpt
report_bus_skew -file fifo_wrap_bus_skew.rpt
check_timing -verbose -file fifo_wrap_check_timing.rpt
report_cdc -details -file fifo_wrap_cdc.rpt
