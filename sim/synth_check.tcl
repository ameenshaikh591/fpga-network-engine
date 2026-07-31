set root_dir [file normalize [file join [file dirname [info script]] ../..]]
set udp_dir [file join $root_dir src udp]

read_vhdl -vhdl2008 [file join $udp_dir udp_engine_pkg.vhd]
read_vhdl -vhdl2008 [file join $udp_dir udp_status_manager.vhd]
read_vhdl -vhdl2008 [file join $udp_dir udp_rmii_rx.vhd]
read_vhdl -vhdl2008 [file join $udp_dir udp_axi_writer.vhd]
read_vhdl -vhdl2008 [file join $udp_dir udp_rx_engine.vhd]
read_vhdl -vhdl2008 [file join $udp_dir udp_axi_reader.vhd]
read_vhdl -vhdl2008 [file join $udp_dir arp_manager.vhd]
read_vhdl -vhdl2008 [file join $udp_dir udp_tx_engine.vhd]
read_vhdl -vhdl2008 [file join $udp_dir tx_frame_arbiter.vhd]
read_vhdl -vhdl2008 [file join $udp_dir udp_tx_buffer_mac.vhd]
read_vhdl -vhdl2008 [file join $udp_dir udp_engine.vhd]

synth_design -top udp_engine -part xc7a35tcpg236-1
report_utilization -file [file join [file dirname [info script]] utilization.rpt]
