# 汇总数据BRAM写控制器的OOC综合、时序和CDC检查脚本。
# 必须从fpga/work目录运行，报告和临时产物仅保留在该工作区。

set script_dir    [file dirname [file normalize [info script]]]
set expected_work [file normalize [file join $script_dir .. work]]
set current_work  [file normalize [pwd]]

if {$current_work ne $expected_work} {
    error "请从 fpga/work 目录运行此脚本，当前目录为：$current_work"
}

set rtl_file [file normalize [file join $script_dir .. src hdl measurement_bram_writer.sv]]
read_verilog -sv $rtl_file

synth_design \
    -top measurement_bram_writer \
    -part xc7z020clg400-2 \
    -mode out_of_context \
    -flatten_hierarchy rebuilt

# 模块计划与AXI侧逻辑共同工作在100 MHz时钟域。
create_clock -name clk -period 10.000 [get_ports clk]

set_input_delay -clock clk -max 0.000 \
    [get_ports {rst start channel_enable[*] vpp_data[*] vpp_valid vrms_data[*] vrms_valid wave_data[*] wave_valid}]
set_input_delay -clock clk -min 0.000 \
    [get_ports {rst start channel_enable[*] vpp_data[*] vpp_valid vrms_data[*] vrms_valid wave_data[*] wave_valid}]
set_output_delay -clock clk -max 0.000 \
    [get_ports {busy frame_done vpp_done vrms_done wave_done error bram_en bram_we[*] bram_addr[*] bram_wrdata[*]}]
set_output_delay -clock clk -min 0.000 \
    [get_ports {busy frame_done vpp_done vrms_done wave_done error bram_en bram_we[*] bram_addr[*] bram_wrdata[*]}]

report_utilization -file measurement_bram_writer_utilization.rpt
report_timing_summary -delay_type max -max_paths 10 \
    -file measurement_bram_writer_timing.rpt
check_timing -verbose -file measurement_bram_writer_check_timing.rpt
report_cdc -details -file measurement_bram_writer_cdc.rpt
