# DAC 输出模块的 OOC 综合、时序和 CDC 检查脚本。
# 必须从 fpga/work 目录运行，报告和临时产物仅保留在该工作区。

set script_dir    [file dirname [file normalize [info script]]]
set expected_work [file normalize [file join $script_dir .. work]]
set current_work  [file normalize [pwd]]

if {$current_work ne $expected_work} {
    error "请从 fpga/work 目录运行此脚本，当前目录为：$current_work"
}

set rtl_file [file normalize [file join $script_dir .. src hdl dac_output.sv]]
read_verilog -sv $rtl_file

synth_design \
    -top dac_output \
    -part xc7z020clg400-2 \
    -mode out_of_context \
    -flatten_hierarchy rebuilt

# 按手册最高 125 MHz（8 ns）检查模块级内部路径和转发时钟结构。模块契约要求
# clk 与 clk_drive 同源同相，因此在 OOC 中把两个根端口建模为同一个时钟对象。
create_clock -name clk -period 8.000 [get_ports {clk clk_drive}]

# 上游数据与本模块同属 clk 域，此处用零端口延迟把完整 8 ns 留给模块内部转换；
# DAC 数据在内部上升沿推出，并在随后下降沿对应的外部 DAC 上升沿被器件锁存。
set_input_delay  -clock clk -max 0.000 \
    [get_ports {data_a[*] data_b[*] in_valid rst}]
set_input_delay  -clock clk -min 0.000 \
    [get_ports {data_a[*] data_b[*] in_valid rst}]
set_output_delay -clock clk -clock_fall -max 0.000 \
    [get_ports {dac_data_a[*] dac_data_b[*]}]
set_output_delay -clock clk -clock_fall -min 0.000 \
    [get_ports {dac_data_a[*] dac_data_b[*]}]

# 两个转发时钟端口本身是接口时钟源，不作为普通数据输出执行端口延迟检查。
set_false_path -to [get_ports {dac_clk_a dac_clk_b}]

report_utilization \
    -file dac_output_utilization.rpt
report_timing_summary \
    -delay_type max \
    -max_paths 10 \
    -file dac_output_timing.rpt
check_timing \
    -verbose \
    -file dac_output_check_timing.rpt
report_cdc \
    -details \
    -file dac_output_cdc.rpt
