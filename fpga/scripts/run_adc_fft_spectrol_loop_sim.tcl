# Build and simulate the complete ADC/FIFO/FIR/FFT/spectrol/energy loop.

set script_dir [file dirname [file normalize [info script]]]
set fpga_dir [file normalize [file join $script_dir ..]]
set work_dir [file normalize [file join $fpga_dir work]]
set result_dir [file normalize [file join $fpga_dir sim_results]]
set project_dir [file normalize \
    [file join $work_dir adc_fft_spectrol_loop_project]]
file mkdir $work_dir
file mkdir $result_dir

create_project adc_fft_spectrol_loop $project_dir \
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
    [file join $fpga_dir src hdl fft_4096_wrapper.sv] \
    [file join $fpga_dir src hdl power_spectrum_calculator.sv] \
    [file join $fpga_dir src hdl spectrol.sv] \
    [file join $fpga_dir src hdl base_detector.sv] \
    [file join $fpga_dir src hdl energy_calculator.sv] \
    [file join $fpga_dir src testmoudle adc-FFT-spectrol-loop.sv]]
add_files -norecurse $rtl_files
foreach rtl_file $rtl_files {
    set_property file_type SystemVerilog [get_files $rtl_file]
}

# Work on staged IP copies because Vivado rewrites metadata around imported XCI
# files.  This keeps fpga/src/ip unchanged on repeated simulations.
set ip_stage [file join $project_dir staged_ip]
set fifo_stage [file join $ip_stage fifo_generator_0]
set fir_stage [file join $ip_stage fir_compiler_0]
set hann_stage [file join $ip_stage hann_rom_0]
set fft_stage [file join $ip_stage xfft_0]
file mkdir $fifo_stage
file mkdir $fir_stage
file mkdir $hann_stage
file mkdir $fft_stage

file copy -force \
    [file join $fpga_dir src ip fifo_generator_0 fifo_generator_0.xci] \
    [file join $fifo_stage fifo_generator_0.xci]
file copy -force [file join $fpga_dir src ip fir_compiler_0.xci] \
    [file join $fir_stage fir_compiler_0.xci]
file copy -force [file join $fpga_dir src ip fir_coe_128.coe] \
    [file join $fir_stage fir_coe_128.coe]
file copy -force \
    [file join $fpga_dir src ip hann_rom_0 hann_rom_0.xci] \
    [file join $hann_stage hann_rom_0.xci]
file copy -force [file join $fpga_dir src ip hann_4096_half_q15.coe] \
    [file join $ip_stage hann_4096_half_q15.coe]
file copy -force [file join $fpga_dir src ip xfft_0 xfft_0.xci] \
    [file join $fft_stage xfft_0.xci]

import_ip -files [file join $fifo_stage fifo_generator_0.xci] \
    -name fifo_generator_0
import_ip -files [file join $fir_stage fir_compiler_0.xci] \
    -name fir_compiler_0
import_ip -files [file join $hann_stage hann_rom_0.xci] \
    -name hann_rom_0
import_ip -files [file join $fft_stage xfft_0.xci] -name xfft_0
# The ROM XCI stores "../hann_4096_half_q15.coe".  import_ip copies the XCI
# into sources_1/ip/hann_rom_0 but does not copy that relative external file.
set imported_hann_xci [get_property IP_FILE [get_ips hann_rom_0]]
set imported_hann_ip_dir [file dirname [file dirname $imported_hann_xci]]
file copy -force [file join $fpga_dir src ip hann_4096_half_q15.coe] \
    [file join $imported_hann_ip_dir hann_4096_half_q15.coe]
generate_target all \
    [get_ips {fifo_generator_0 fir_compiler_0 hann_rom_0 xfft_0}]

set tb_file [file join $fpga_dir src sim adc_fft_spectrol_loop_tb.sv]
add_files -fileset sim_1 -norecurse $tb_file
set_property file_type SystemVerilog [get_files $tb_file]
set_property top adc_fft_spectrol_loop_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]

set adc_mem [file normalize \
    [file join $fpga_dir src sim simdata adc_input_u10.mem]]
set energy_out [file normalize \
    [file join $result_dir adc_fft_spectrol_loop_energy_writes.csv]]
set spectrum_out [file normalize \
    [file join $result_dir adc_fft_spectrol_loop_spectrum.csv]]
set summary_out [file normalize \
    [file join $result_dir adc_fft_spectrol_loop_summary.txt]]
set sim_options "-testplusarg ADC_MEM=$adc_mem \
    -testplusarg ENERGY_OUT=$energy_out \
    -testplusarg SPECTRUM_OUT=$spectrum_out \
    -testplusarg SUMMARY_OUT=$summary_out"
set_property -name {xsim.simulate.xsim.more_options} -value $sim_options \
    -objects [get_filesets sim_1]

launch_simulation -mode behavioral
close_sim
puts "ADC_FFT_SPECTROL_LOOP_SIMULATION_PASSED"
puts "ENERGY_OUTPUT=$energy_out"
puts "SUMMARY_OUTPUT=$summary_out"
close_project
