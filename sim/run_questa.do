# Requires the Xilinx XPM simulation library to be compiled and mapped as xpm.
if {![info exists env(XILINX_VIVADO)]} {
    error "Set XILINX_VIVADO to the Vivado installation directory before running this script"
}
vlib work
vcom -2008 ../../src/udp/udp_engine_pkg.vhd
vcom -2008 ../../src/udp/udp_status_manager.vhd
vcom -2008 ../../src/udp/udp_rmii_rx.vhd
vcom -2008 ../../src/udp/udp_axi_writer.vhd
vcom -2008 ../../src/udp/udp_rx_engine.vhd
vcom -2008 ../../src/udp/udp_axi_reader.vhd
vcom -2008 ../../src/udp/arp_manager.vhd
vcom -2008 ../../src/udp/udp_tx_engine.vhd
vcom -2008 ../../src/udp/tx_frame_arbiter.vhd
vcom -2008 ../../src/udp/udp_tx_buffer_mac.vhd
vcom -2008 ../../src/udp/udp_engine.vhd
vlog -sv tb_udp_axi_reader.sv tb_udp_engine.sv
vlog $env(XILINX_VIVADO)/data/verilog/src/glbl.v
vsim -voptargs=+acc work.tb_udp_axi_reader work.glbl
run -all
quit -sim
vsim -voptargs=+acc work.tb_udp_engine work.glbl
run -all
