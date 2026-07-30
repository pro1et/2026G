# 
# Usage: To re-create this platform project launch xsct with below options.
# xsct E:\FPGA_PJ\2026G\fpga\vitis\include\draw_test1\platform.tcl
# 
# OR launch xsct and run below command.
# source E:\FPGA_PJ\2026G\fpga\vitis\include\draw_test1\platform.tcl
# 
# To create the platform in a different location, modify the -out option of "platform create" command.
# -out option specifies the output directory of the platform project.

platform create -name {draw_test1}\
-hw {E:\FPGA_PJ\2026G\fpga\work\draw_test1.xsa}\
-proc {ps7_cortexa9_0} -os {standalone} -out {E:/FPGA_PJ/2026G/fpga/vitis/include}

platform write
platform generate -domains 
platform active {draw_test1}
platform generate
