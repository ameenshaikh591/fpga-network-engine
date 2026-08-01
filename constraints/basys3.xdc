###############################################################################
# RMII clock
###############################################################################

set_property PACKAGE_PIN L17 [get_ports i_ref_clk]
    set_property IOSTANDARD LVCMOS33 [get_ports i_ref_clk]
    create_clock -name rmii_clk -period 20.000 -waveform {0.000 10.000} [get_ports i_ref_clk]


###############################################################################
# RMII receive: PHY -> FPGA
###############################################################################

set_property PACKAGE_PIN K17 [get_ports i_crs_dv]
    set_property IOSTANDARD LVCMOS33 [get_ports i_crs_dv]

set_property PACKAGE_PIN M18 [get_ports {i_rxd[0]}]
    set_property IOSTANDARD LVCMOS33 [get_ports {i_rxd[0]}]

set_property PACKAGE_PIN M19 [get_ports {i_rxd[1]}]
    set_property IOSTANDARD LVCMOS33 [get_ports {i_rxd[1]}]

set_input_delay -clock rmii_clk -max 5.0 [get_ports {i_crs_dv i_rxd[*]}]

set_input_delay -clock rmii_clk -min 1.4 [get_ports {i_crs_dv i_rxd[*]}]


###############################################################################
# RMII transmit: FPGA -> PHY
###############################################################################

set_property PACKAGE_PIN N17 [get_ports o_tx_en]
    set_property IOSTANDARD LVCMOS33 [get_ports o_tx_en]

set_property PACKAGE_PIN P17 [get_ports {o_txd[0]}]
    set_property IOSTANDARD LVCMOS33 [get_ports {o_txd[0]}]

set_property PACKAGE_PIN P18 [get_ports {o_txd[1]}]
    set_property IOSTANDARD LVCMOS33 [get_ports {o_txd[1]}]

set_property SLEW SLOW [get_ports {o_tx_en o_txd[*]}]

set_property DRIVE 4 [get_ports {o_tx_en o_txd[*]}]

set_output_delay -clock rmii_clk -max 7.0 [get_ports {o_tx_en o_txd[*]}]

set_output_delay -clock rmii_clk -min -2.0 [get_ports {o_tx_en o_txd[*]}]

set_clock_groups -asynchronous \
    -group [get_clocks {sys_clock clk_out1_design_1_clk_wiz_1_0}] \
    -group [get_clocks rmii_clk]