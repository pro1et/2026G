# Standalone constraints for measurement_timing_pipeline_top.
# The two ADC clock ports are driven from the same 32 MHz source in this test.
create_clock -name adc_clk -period 31.250 \
    [get_ports {adc_clk adc_clk_drive}]
create_clock -name processing_clk -period 10.000 \
    [get_ports processing_clk]

set_clock_groups -asynchronous \
    -group [get_clocks adc_clk] \
    -group [get_clocks processing_clk]

# Reproduce the current board-interface assumption documented in 时序问题.md.
create_generated_clock -name adc_clk_a_fwd \
    -source [get_ports adc_clk_drive] \
    -divide_by 1 [get_ports adc_clk_a]
create_generated_clock -name adc_clk_b_fwd \
    -source [get_ports adc_clk_drive] \
    -divide_by 1 [get_ports adc_clk_b]

set_input_delay -clock adc_clk_a_fwd -max 26.000 \
    [get_ports {adc_data_a[*]}]
set_input_delay -clock adc_clk_a_fwd -min 0.000 \
    [get_ports {adc_data_a[*]}]
set_input_delay -clock adc_clk_b_fwd -max 26.000 \
    [get_ports {adc_data_b[*]}]
set_input_delay -clock adc_clk_b_fwd -min 0.000 \
    [get_ports {adc_data_b[*]}]

set_property SLEW SLOW [get_ports {adc_clk_a adc_clk_b}]
set_property DRIVE 12  [get_ports {adc_clk_a adc_clk_b}]

# Non-ADC test/control inputs are driven synchronously and ideally by the TB.
set_input_delay -clock adc_clk -max 0.000 \
    [get_ports {adc_rst fifo_rst capture_start adc_channel_select}]
set_input_delay -clock adc_clk -min 0.000 \
    [get_ports {adc_rst fifo_rst capture_start adc_channel_select}]
set_input_delay -clock processing_clk -max 0.000 \
    [get_ports {processing_rst clear_error}]
set_input_delay -clock processing_clk -min 0.000 \
    [get_ports {processing_rst clear_error}]

# Asynchronous assertion/reset pins are not synchronous data paths.
set_false_path -from [get_ports fifo_rst]

