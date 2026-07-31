# Build and simulate ADC -> FIFO -> FIR -> four-way measurement/decimation/Hann
# with the project's real FIFO, FIR Compiler and Block Memory Generator IP.

set script_dir [file dirname [file normalize [info script]]]
set fpga_dir [file normalize [file join $script_dir ..]]
set work_dir [file normalize [file join $fpga_dir work]]
set result_dir [file normalize [file join $fpga_dir sim_results]]
set project_dir [file normalize [file join $work_dir measurement_window_pipeline_project]]
file mkdir $work_dir
file mkdir $result_dir

create_project measurement_window_pipeline $project_dir \
    -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl_files [list \
    [file join $fpga_dir src hdl adc_capture.sv] \
    [file join $fpga_dir src hdl adc_write_controller.sv] \
    [file join $fpga_dir src hdl af_cdc.sv] \
    [file join $fpga_dir src hdl fifo_ctrl.sv] \
    [file join $fpga_dir src hdl fifo_wrap.v] \
    [file join $fpga_dir src hdl fir_wrap.sv] \
    [file join $fpga_dir src hdl measurement_stream_splitter.sv] \
    [file join $fpga_dir src hdl peak_to_peak_detector.sv] \
    [file join $fpga_dir src hdl mean_square_calculator.sv] \
    [file join $fpga_dir src hdl measurement_bram_writer.sv] \
    [file join $fpga_dir src hdl downsampler_16.sv] \
    [file join $fpga_dir src hdl hann_window_4096.sv] \
    [file join $fpga_dir src testmodule measurement_window_pipeline_top.sv]]
add_files -norecurse $rtl_files
foreach rtl_file $rtl_files {
    set_property file_type SystemVerilog [get_files $rtl_file]
}
set_property top measurement_window_pipeline_top [current_fileset]

# Stage copies of the XCI/COE sources inside the disposable work project.  Vivado
# rewrites IP metadata and generates many companion files next to an XCI passed
# directly to read_ip; staging keeps src/ip immutable on repeat runs.
set ip_stage [file join $project_dir staged_ip]
set fifo_stage [file join $ip_stage fifo_generator_0]
set fir_stage [file join $ip_stage fir_compiler_0]
set hann_stage [file join $ip_stage hann_rom_0]
file mkdir $fifo_stage
file mkdir $fir_stage
file mkdir $hann_stage
file copy -force [file join $fpga_dir src ip fifo_generator_0 fifo_generator_0.xci] \
    [file join $fifo_stage fifo_generator_0.xci]
file copy -force [file join $fpga_dir src ip fir_compiler_0.xci] \
    [file join $fir_stage fir_compiler_0.xci]
file copy -force [file join $fpga_dir src ip fir_coe_128.coe] \
    [file join $fir_stage fir_coe_128.coe]
file copy -force [file join $fpga_dir src ip hann_rom_0 hann_rom_0.xci] \
    [file join $hann_stage hann_rom_0.xci]
file copy -force [file join $fpga_dir src ip hann_4096_half_q15.coe] \
    [file join $ip_stage hann_4096_half_q15.coe]
set fifo_xci [file join $fifo_stage fifo_generator_0.xci]
set fir_xci [file join $fir_stage fir_compiler_0.xci]
set hann_xci [file join $hann_stage hann_rom_0.xci]
import_ip -files $fifo_xci -name fifo_generator_0
import_ip -files $fir_xci -name fir_compiler_0
import_ip -files $hann_xci -name hann_rom_0
generate_target all [get_ips {fifo_generator_0 fir_compiler_0 hann_rom_0}]

set tb_file [file join $fpga_dir src sim measurement_window_pipeline_top_tb.sv]
add_files -fileset sim_1 -norecurse $tb_file
set_property file_type SystemVerilog [get_files $tb_file]
set_property top measurement_window_pipeline_top_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]

set adc_mem [file normalize [file join $fpga_dir src sim simdata adc_input_u10.mem]]
set fir_out [file normalize [file join $result_dir window_pipeline_fir.csv]]
set decim_out [file normalize [file join $result_dir window_pipeline_decim.csv]]
set window_out [file normalize [file join $result_dir window_pipeline_window.csv]]
set summary_out [file normalize [file join $result_dir window_pipeline_summary.txt]]
set sim_options "-testplusarg ADC_MEM=$adc_mem \
    -testplusarg FIR_OUT=$fir_out \
    -testplusarg DECIM_OUT=$decim_out \
    -testplusarg WINDOW_OUT=$window_out \
    -testplusarg SUMMARY_OUT=$summary_out"
set_property -name {xsim.simulate.xsim.more_options} -value $sim_options \
    -objects [get_filesets sim_1]

launch_simulation -mode behavioral
close_sim
puts "WINDOW_PIPELINE_SIMULATION_PASSED"
puts "WINDOW_OUTPUT=$window_out"
close_project
