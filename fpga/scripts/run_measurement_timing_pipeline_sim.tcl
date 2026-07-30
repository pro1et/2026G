# Build and simulate the full measurement timing pipeline with real Xilinx IP.
# Usage:
#   vivado -mode batch -source run_measurement_timing_pipeline_sim.tcl \
#          -tclargs behavioral|timing

set mode [lindex $argv 0]
if {$mode eq ""} {
    set mode behavioral
}
if {$mode ni {behavioral timing}} {
    error "mode must be behavioral or timing"
}

set script_dir [file dirname [file normalize [info script]]]
set fpga_dir   [file normalize [file join $script_dir ..]]
set work_dir   [file normalize [file join $fpga_dir work]]
set result_dir [file normalize [file join $fpga_dir sim_results]]
set project_dir [file normalize [file join $work_dir measurement_timing_pipeline_project]]
file mkdir $work_dir
file mkdir $result_dir

create_project measurement_timing_pipeline $project_dir \
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
    [file join $fpga_dir src testmodule measurement_timing_pipeline_top.sv]]

add_files -norecurse $rtl_files
foreach rtl_file $rtl_files {
    set_property file_type SystemVerilog [get_files $rtl_file]
}
set_property top measurement_timing_pipeline_top [current_fileset]

set fifo_xci [file join $fpga_dir src ip fifo_generator_0 fifo_generator_0.xci]
set fir_xci  [file join $fpga_dir src ip fir_compiler_0.xci]
import_ip -files $fifo_xci -name fifo_generator_0
import_ip -files $fir_xci  -name fir_compiler_0
generate_target all [get_ips {fifo_generator_0 fir_compiler_0}]

set xdc_file [file join $fpga_dir src constrs measurement_timing_pipeline.xdc]
add_files -fileset constrs_1 -norecurse $xdc_file

set tb_file [file join $fpga_dir src sim measurement_timing_pipeline_top_tb.sv]
add_files -fileset sim_1 -norecurse $tb_file
set_property file_type SystemVerilog [get_files $tb_file]
set_property top measurement_timing_pipeline_top_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

set adc_mem [file normalize [file join $fpga_dir src sim simdata adc_input_u10.mem]]
set csv_out [file normalize [file join $result_dir measurement_${mode}_bram_writes.csv]]
set summary_out [file normalize [file join $result_dir measurement_${mode}_summary.txt]]
set sim_options "-testplusarg ADC_MEM=$adc_mem -testplusarg CSV_OUT=$csv_out -testplusarg SUMMARY_OUT=$summary_out"
set_property -name {xsim.simulate.xsim.more_options} -value $sim_options \
    -objects [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} \
    -objects [get_filesets sim_1]

if {$mode eq "behavioral"} {
    launch_simulation -mode behavioral
    close_sim
} else {
    launch_runs synth_1 -jobs 2
    wait_on_run synth_1
    if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} {
        error "synth_1 failed: [get_property STATUS [get_runs synth_1]]"
    }

    launch_runs impl_1 -to_step route_design -jobs 2
    wait_on_run impl_1
    if {![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} {
        error "impl_1 failed: [get_property STATUS [get_runs impl_1]]"
    }

    open_run impl_1
    report_timing_summary -delay_type min_max -max_paths 20 \
        -file [file join $result_dir measurement_timing_summary_routed.rpt]
    report_methodology \
        -file [file join $result_dir measurement_methodology_routed.rpt]
    close_design

    launch_simulation -mode post-implementation -type timing
    close_sim
}

puts "SIMULATION_MODE=$mode"
puts "CSV_OUTPUT=$csv_out"
puts "SUMMARY_OUTPUT=$summary_out"
close_project
