# Usage with Vitis IDE:
# In Vitis IDE create a Single Application Debug launch configuration,
# change the debug type to 'Attach to running target' and provide this 
# tcl script in 'Execute Script' option.
# Path of this script: E:\FPGA_PJ\2026G\fpga\vitis\include\draw_test2_1_system\_ide\scripts\debugger_draw_test2_1-default.tcl
# 
# 
# Usage with xsct:
# To debug using xsct, launch xsct and run below command
# source E:\FPGA_PJ\2026G\fpga\vitis\include\draw_test2_1_system\_ide\scripts\debugger_draw_test2_1-default.tcl
# 
connect -url tcp:127.0.0.1:3121
targets -set -nocase -filter {name =~"APU*"}
rst -system
after 3000
targets -set -filter {jtag_cable_name =~ "Digilent JTAG-HS2 210241880278" && level==0 && jtag_device_ctx=="jsn-JTAG-HS2-210241880278-23727093-0"}
fpga -file E:/FPGA_PJ/2026G/fpga/vitis/include/draw_test2_1/_ide/bitstream/draw_test2.bit
targets -set -nocase -filter {name =~"APU*"}
loadhw -hw E:/FPGA_PJ/2026G/fpga/vitis/include/draw_test2/export/draw_test2/hw/draw_test2.xsa -mem-ranges [list {0x40000000 0xbfffffff}] -regs
configparams force-mem-access 1
targets -set -nocase -filter {name =~"APU*"}
source E:/FPGA_PJ/2026G/fpga/vitis/include/draw_test2_1/_ide/psinit/ps7_init.tcl
ps7_init
ps7_post_config
targets -set -nocase -filter {name =~ "*A9*#0"}
dow E:/FPGA_PJ/2026G/fpga/vitis/include/draw_test2_1/Debug/draw_test2_1.elf
configparams force-mem-access 0
bpadd -addr &main
