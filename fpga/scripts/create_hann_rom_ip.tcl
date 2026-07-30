# 创建16位×2048深度的periodic Hann半窗ROM源XCI。
# 必须从fpga/work目录运行；源XCI保存到fpga/src/ip/hann_rom_0。

set script_dir    [file dirname [file normalize [info script]]]
set fpga_dir      [file normalize [file join $script_dir ..]]
set expected_work [file normalize [file join $fpga_dir work]]
set current_work  [file normalize [pwd]]

if {$current_work ne $expected_work} {
    error "请从fpga/work目录运行此脚本，当前目录为：$current_work"
}

set coe_file [file normalize [file join $fpga_dir src ip hann_4096_half_q15.coe]]
set ip_parent [file normalize [file join $fpga_dir src ip]]
set ip_dir    [file join $ip_parent hann_rom_0]
set xci_file  [file join $ip_dir hann_rom_0.xci]

if {![file exists $coe_file]} {
    error "找不到Hann系数文件：$coe_file"
}
if {[file exists $xci_file]} {
    error "目标XCI已经存在，请先确认是否确实需要重新生成：$xci_file"
}

set project_dir [file normalize [file join $current_work hann_rom_ip_project]]
create_project hann_rom_ip $project_dir -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]

create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 \
    -module_name hann_rom_0 -dir $ip_parent

set_property -dict [list \
    CONFIG.Interface_Type {Native} \
    CONFIG.Memory_Type {Single_Port_ROM} \
    CONFIG.Enable_A {Use_ENA_Pin} \
    CONFIG.Write_Width_A {16} \
    CONFIG.Write_Depth_A {2048} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortA_Output_of_Memory_Core {false} \
    CONFIG.Load_Init_File {true} \
    CONFIG.Coe_File $coe_file \
    CONFIG.Fill_Remaining_Memory_Locations {false} \
] [get_ips hann_rom_0]

set_property generate_synth_checkpoint false [get_files $xci_file]

puts "HANN_ROM_XCI=$xci_file"
puts "MEMORY_TYPE=[get_property CONFIG.Memory_Type [get_ips hann_rom_0]]"
puts "WIDTH=[get_property CONFIG.Write_Width_A [get_ips hann_rom_0]]"
puts "DEPTH=[get_property CONFIG.Write_Depth_A [get_ips hann_rom_0]]"
puts "PRIMITIVE_OUTPUT_REGISTER=[get_property CONFIG.Register_PortA_Output_of_Memory_Primitives [get_ips hann_rom_0]]"
puts "CORE_OUTPUT_REGISTER=[get_property CONFIG.Register_PortA_Output_of_Memory_Core [get_ips hann_rom_0]]"

close_project
