library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

use work.udp_engine_pkg.all;

entity udp_engine is
    generic (
        G_LOCAL_MAC : std_logic_vector(47 downto 0) := x"001122334455";
        G_ARP_RETRY_INTERVAL_CYCLES : positive := 500000000;
        G_ARP_MAX_REQUESTS : positive := 3
    );
    port (
        -- AXI/protocol domain
        aclk    : in std_logic;
        aresetn : in std_logic;

        -- RMII 50 MHz reference-clock domain
        i_ref_clk     : in std_logic;
        i_rxd         : in std_logic_vector(1 downto 0);
        i_crs_dv      : in std_logic;
        o_txd         : out std_logic_vector(1 downto 0);
        o_tx_en       : out std_logic;

        -- AXI4-Lite control slave
        S_AXI_AWADDR  : in  std_logic_vector(31 downto 0);
        S_AXI_AWPROT  : in  std_logic_vector(2 downto 0);
        S_AXI_AWVALID : in  std_logic;
        S_AXI_AWREADY : out std_logic;
        S_AXI_WDATA   : in  std_logic_vector(31 downto 0);
        S_AXI_WSTRB   : in  std_logic_vector(3 downto 0);
        S_AXI_WVALID  : in  std_logic;
        S_AXI_WREADY  : out std_logic;
        S_AXI_BRESP   : out std_logic_vector(1 downto 0);
        S_AXI_BVALID  : out std_logic;
        S_AXI_BREADY  : in  std_logic;
        S_AXI_ARADDR  : in  std_logic_vector(31 downto 0);
        S_AXI_ARPROT  : in  std_logic_vector(2 downto 0);
        S_AXI_ARVALID : in  std_logic;
        S_AXI_ARREADY : out std_logic;
        S_AXI_RDATA   : out std_logic_vector(31 downto 0);
        S_AXI_RRESP   : out std_logic_vector(1 downto 0);
        S_AXI_RVALID  : out std_logic;
        S_AXI_RREADY  : in  std_logic;

        -- Independent AXI4 read master
        M_AXI_RD_ARADDR  : out std_logic_vector(31 downto 0);
        M_AXI_RD_ARLEN   : out std_logic_vector(7 downto 0);
        M_AXI_RD_ARSIZE  : out std_logic_vector(2 downto 0);
        M_AXI_RD_ARBURST : out std_logic_vector(1 downto 0);
        M_AXI_RD_ARPROT  : out std_logic_vector(2 downto 0);
        M_AXI_RD_ARVALID : out std_logic;
        M_AXI_RD_ARREADY : in  std_logic;
        M_AXI_RD_RDATA   : in  std_logic_vector(31 downto 0);
        M_AXI_RD_RRESP   : in  std_logic_vector(1 downto 0);
        M_AXI_RD_RLAST   : in  std_logic;
        M_AXI_RD_RVALID  : in  std_logic;
        M_AXI_RD_RREADY  : out std_logic;

        -- Independent AXI4 write master
        M_AXI_WR_AWADDR  : out std_logic_vector(31 downto 0);
        M_AXI_WR_AWLEN   : out std_logic_vector(7 downto 0);
        M_AXI_WR_AWSIZE  : out std_logic_vector(2 downto 0);
        M_AXI_WR_AWBURST : out std_logic_vector(1 downto 0);
        M_AXI_WR_AWPROT  : out std_logic_vector(2 downto 0);
        M_AXI_WR_AWVALID : out std_logic;
        M_AXI_WR_AWREADY : in  std_logic;
        M_AXI_WR_WDATA   : out std_logic_vector(31 downto 0);
        M_AXI_WR_WSTRB   : out std_logic_vector(3 downto 0);
        M_AXI_WR_WLAST   : out std_logic;
        M_AXI_WR_WVALID  : out std_logic;
        M_AXI_WR_WREADY  : in  std_logic;
        M_AXI_WR_BRESP   : in  std_logic_vector(1 downto 0);
        M_AXI_WR_BVALID  : in  std_logic;
        M_AXI_WR_BREADY  : out std_logic
    );
end entity;

architecture rtl of udp_engine is
    signal dma_base_addr, local_ip, subnet_mask, gateway : std_logic_vector(31 downto 0);
    signal socket0_enable, socket1_enable : std_logic;
    signal socket0_port, socket1_port : std_logic_vector(15 downto 0);
    signal rx0_head, rx0_tail, rx1_head, rx1_tail, tx_head, tx_tail : t_queue_ptr;
    signal config_changed : std_logic;
    signal rx_commit_valid, rx_commit_socket, tx_release_valid : std_logic;

    signal rx_fifo_din, rx_fifo_dout : std_logic_vector(9 downto 0);
    signal rx_fifo_write, rx_fifo_read, rx_fifo_full, rx_fifo_empty, rx_fifo_prog_full : std_logic;
    signal rx_fifo_wr_busy, rx_fifo_rd_busy, rx_fifo_reset : std_logic;

    signal write_req_valid, write_req_ready : std_logic;
    signal write_base_addr : std_logic_vector(31 downto 0);
    signal write_metadata : std_logic_vector(127 downto 0);
    signal write_payload_length : std_logic_vector(15 downto 0);
    signal rx_payload_valid, rx_payload_ready, rx_payload_last, write_abort : std_logic;
    signal rx_payload_data : std_logic_vector(7 downto 0);
    signal write_done, write_error, write_aborted : std_logic;

    signal arp_event_valid : std_logic;
    signal arp_event_opcode : std_logic_vector(15 downto 0);
    signal arp_event_sender_mac, arp_event_target_mac : std_logic_vector(47 downto 0);
    signal arp_event_sender_ip, arp_event_target_ip : std_logic_vector(31 downto 0);

    signal read_req_valid, read_req_ready : std_logic;
    signal read_addr : std_logic_vector(31 downto 0);
    signal read_length : std_logic_vector(15 downto 0);
    signal read_data_valid, read_data_ready, read_last, read_done, read_error : std_logic;
    signal read_data : std_logic_vector(31 downto 0);
    signal read_valid_bytes : std_logic_vector(1 downto 0);

    signal resolve_req_valid, resolve_req_ready, resolve_rsp_valid, resolve_rsp_failed : std_logic;
    signal resolve_ip : std_logic_vector(31 downto 0);
    signal resolve_mac : std_logic_vector(47 downto 0);

    signal arp_req_valid, arp_req_ready, arp_data_valid, arp_data_ready, arp_last, arp_abort : std_logic;
    signal arp_dest_mac : std_logic_vector(47 downto 0);
    signal arp_ethertype, arp_length : std_logic_vector(15 downto 0);
    signal arp_data : std_logic_vector(31 downto 0);
    signal arp_valid_bytes : std_logic_vector(1 downto 0);

    signal udp_req_valid, udp_req_ready, udp_data_valid, udp_data_ready, udp_last, udp_abort : std_logic;
    signal udp_dest_mac : std_logic_vector(47 downto 0);
    signal udp_ethertype, udp_length : std_logic_vector(15 downto 0);
    signal udp_data : std_logic_vector(31 downto 0);
    signal udp_valid_bytes : std_logic_vector(1 downto 0);

    signal frame_req_valid, frame_req_ready, frame_data_valid, frame_data_ready, frame_last, frame_abort : std_logic;
    signal frame_dest_mac : std_logic_vector(47 downto 0);
    signal frame_ethertype, frame_length : std_logic_vector(15 downto 0);
    signal frame_data : std_logic_vector(31 downto 0);
    signal frame_valid_bytes : std_logic_vector(1 downto 0);

    signal axi_to_rmii_resetn_sync1 : std_logic;
    signal axi_to_rmii_resetn_sync2 : std_logic;

    signal i_rmii_resetn : std_logic;
    signal i_rxer        : std_logic;

begin

    process(i_ref_clk) is
    begin
        if rising_edge(i_ref_clk) then
            axi_to_rmii_resetn_sync1 <= aresetn;
            axi_to_rmii_resetn_sync2 <= axi_to_rmii_resetn_sync1;
        end if;
    end process;

    i_rmii_resetn <= axi_to_rmii_resetn_sync2;
    rx_fifo_reset <= not (aresetn and i_rmii_resetn);
    i_rxer <= '0';

    status_inst : entity work.udp_status_manager
        port map (
            axi_aclk => aclk, axi_aresetn => aresetn,
            S_AXI_AWADDR => S_AXI_AWADDR, S_AXI_AWPROT => S_AXI_AWPROT,
            S_AXI_AWVALID => S_AXI_AWVALID, S_AXI_AWREADY => S_AXI_AWREADY,
            S_AXI_WDATA => S_AXI_WDATA, S_AXI_WSTRB => S_AXI_WSTRB,
            S_AXI_WVALID => S_AXI_WVALID, S_AXI_WREADY => S_AXI_WREADY,
            S_AXI_BRESP => S_AXI_BRESP, S_AXI_BVALID => S_AXI_BVALID, S_AXI_BREADY => S_AXI_BREADY,
            S_AXI_ARADDR => S_AXI_ARADDR, S_AXI_ARPROT => S_AXI_ARPROT,
            S_AXI_ARVALID => S_AXI_ARVALID, S_AXI_ARREADY => S_AXI_ARREADY,
            S_AXI_RDATA => S_AXI_RDATA, S_AXI_RRESP => S_AXI_RRESP,
            S_AXI_RVALID => S_AXI_RVALID, S_AXI_RREADY => S_AXI_RREADY,
            i_rx_commit_valid => rx_commit_valid, i_rx_commit_socket => rx_commit_socket,
            i_tx_release_valid => tx_release_valid,
            o_dma_base_addr => dma_base_addr, o_local_ipv4_addr => local_ip,
            o_subnet_mask => subnet_mask, o_default_gateway => gateway,
            o_socket0_enable => socket0_enable, o_socket0_port => socket0_port,
            o_socket1_enable => socket1_enable, o_socket1_port => socket1_port,
            o_rx0_head_ptr => rx0_head, o_rx0_tail_ptr => rx0_tail,
            o_rx1_head_ptr => rx1_head, o_rx1_tail_ptr => rx1_tail,
            o_tx_head_ptr => tx_head, o_tx_tail_ptr => tx_tail,
            o_network_config_changed => config_changed
        );

    rx_mac_inst : entity work.udp_rmii_rx
        port map (
            i_ref_clk => i_ref_clk, i_resetn => i_rmii_resetn,
            i_rxd => i_rxd, i_rxer => i_rxer, i_crs_dv => i_crs_dv,
            i_fifo_almost_full => rx_fifo_prog_full or rx_fifo_wr_busy,
            i_fifo_full => rx_fifo_full or rx_fifo_wr_busy,
            o_fifo_write => rx_fifo_write, o_fifo_data => rx_fifo_din
        );

    rx_async_fifo_inst : xpm_fifo_async
        generic map (
            FIFO_MEMORY_TYPE => "block", FIFO_WRITE_DEPTH => 2048,
            WRITE_DATA_WIDTH => 10, READ_DATA_WIDTH => 10,
            READ_MODE => "fwft", FIFO_READ_LATENCY => 0,
            CDC_SYNC_STAGES => 2, RELATED_CLOCKS => 0,
            DOUT_RESET_VALUE => "0", ECC_MODE => "no_ecc", FULL_RESET_VALUE => 0,
            PROG_EMPTY_THRESH => 10, PROG_FULL_THRESH => 2043,
            RD_DATA_COUNT_WIDTH => 11, WR_DATA_COUNT_WIDTH => 11,
            USE_ADV_FEATURES => "0707", EN_SIM_ASSERT_ERR => "warning",
            SIM_ASSERT_CHK => 0, WAKEUP_TIME => 0, CASCADE_HEIGHT => 0
        )
        port map (
            dout => rx_fifo_dout, empty => rx_fifo_empty, full => rx_fifo_full,
            rd_rst_busy => rx_fifo_rd_busy, wr_rst_busy => rx_fifo_wr_busy,
            almost_empty => open, almost_full => open, data_valid => open,
            dbiterr => open, overflow => open, prog_empty => open,
            prog_full => rx_fifo_prog_full, rd_data_count => open,
            sbiterr => open, underflow => open, wr_ack => open, wr_data_count => open,
            din => rx_fifo_din, wr_en => rx_fifo_write and not rx_fifo_full and not rx_fifo_wr_busy,
            rd_en => rx_fifo_read and not rx_fifo_empty and not rx_fifo_rd_busy,
            wr_clk => i_ref_clk, rd_clk => aclk, rst => rx_fifo_reset,
            sleep => '0', injectdbiterr => '0', injectsbiterr => '0'
        );

    rx_engine_inst : entity work.udp_rx_engine
        generic map (G_LOCAL_MAC => G_LOCAL_MAC)
        port map (
            axi_aclk => aclk, axi_aresetn => aresetn,
            i_fifo_data => rx_fifo_dout,
            i_fifo_empty => rx_fifo_empty or rx_fifo_rd_busy,
            o_fifo_read => rx_fifo_read,
            i_dma_base_addr => dma_base_addr, i_local_ipv4_addr => local_ip,
            i_socket0_enable => socket0_enable, i_socket0_port => socket0_port,
            i_socket1_enable => socket1_enable, i_socket1_port => socket1_port,
            i_rx0_head_ptr => rx0_head, i_rx0_tail_ptr => rx0_tail,
            i_rx1_head_ptr => rx1_head, i_rx1_tail_ptr => rx1_tail,
            o_write_req_valid => write_req_valid, i_write_req_ready => write_req_ready,
            o_write_base_addr => write_base_addr, o_write_metadata => write_metadata,
            o_write_payload_length => write_payload_length,
            o_payload_valid => rx_payload_valid, i_payload_ready => rx_payload_ready,
            o_payload_data => rx_payload_data, o_payload_last => rx_payload_last,
            o_write_abort => write_abort, i_write_done => write_done,
            i_write_error => write_error, i_write_aborted => write_aborted,
            o_rx_commit_valid => rx_commit_valid, o_rx_commit_socket => rx_commit_socket,
            o_arp_event_valid => arp_event_valid, o_arp_event_opcode => arp_event_opcode,
            o_arp_event_sender_mac => arp_event_sender_mac,
            o_arp_event_sender_ip => arp_event_sender_ip,
            o_arp_event_target_mac => arp_event_target_mac,
            o_arp_event_target_ip => arp_event_target_ip
        );

    writer_inst : entity work.udp_axi_writer
        port map (
            axi_aclk => aclk, axi_aresetn => aresetn,
            i_write_req_valid => write_req_valid, o_write_req_ready => write_req_ready,
            i_write_base_addr => write_base_addr, i_write_metadata => write_metadata,
            i_write_payload_length => write_payload_length,
            i_payload_valid => rx_payload_valid, o_payload_ready => rx_payload_ready,
            i_payload_data => rx_payload_data, i_payload_last => rx_payload_last,
            i_write_abort => write_abort, o_write_done => write_done,
            o_write_error => write_error, o_write_aborted => write_aborted,
            M_AXI_AWADDR => M_AXI_WR_AWADDR, M_AXI_AWLEN => M_AXI_WR_AWLEN,
            M_AXI_AWSIZE => M_AXI_WR_AWSIZE, M_AXI_AWBURST => M_AXI_WR_AWBURST,
            M_AXI_AWPROT => M_AXI_WR_AWPROT, M_AXI_AWVALID => M_AXI_WR_AWVALID,
            M_AXI_AWREADY => M_AXI_WR_AWREADY, M_AXI_WDATA => M_AXI_WR_WDATA,
            M_AXI_WSTRB => M_AXI_WR_WSTRB, M_AXI_WLAST => M_AXI_WR_WLAST,
            M_AXI_WVALID => M_AXI_WR_WVALID, M_AXI_WREADY => M_AXI_WR_WREADY,
            M_AXI_BRESP => M_AXI_WR_BRESP, M_AXI_BVALID => M_AXI_WR_BVALID,
            M_AXI_BREADY => M_AXI_WR_BREADY
        );

    reader_inst : entity work.udp_axi_reader
        port map (
            axi_aclk => aclk, axi_aresetn => aresetn,
            i_read_req_valid => read_req_valid, o_read_req_ready => read_req_ready,
            i_read_addr => read_addr, i_read_length => read_length,
            o_read_data_valid => read_data_valid, i_read_data_ready => read_data_ready,
            o_read_data => read_data, o_read_valid_bytes => read_valid_bytes,
            o_read_last => read_last, o_read_done => read_done, o_read_error => read_error,
            o_debug_state => open,
            M_AXI_ARADDR => M_AXI_RD_ARADDR, M_AXI_ARLEN => M_AXI_RD_ARLEN,
            M_AXI_ARSIZE => M_AXI_RD_ARSIZE, M_AXI_ARBURST => M_AXI_RD_ARBURST,
            M_AXI_ARPROT => M_AXI_RD_ARPROT, M_AXI_ARVALID => M_AXI_RD_ARVALID,
            M_AXI_ARREADY => M_AXI_RD_ARREADY, M_AXI_RDATA => M_AXI_RD_RDATA,
            M_AXI_RRESP => M_AXI_RD_RRESP, M_AXI_RLAST => M_AXI_RD_RLAST,
            M_AXI_RVALID => M_AXI_RD_RVALID, M_AXI_RREADY => M_AXI_RD_RREADY
        );

    arp_inst : entity work.arp_manager
        generic map (
            G_LOCAL_MAC => G_LOCAL_MAC,
            G_RETRY_INTERVAL_CYCLES => G_ARP_RETRY_INTERVAL_CYCLES,
            G_MAX_REQUESTS => G_ARP_MAX_REQUESTS
        )
        port map (
            axi_aclk => aclk, axi_aresetn => aresetn,
            i_local_ipv4_addr => local_ip, i_network_config_changed => config_changed,
            i_arp_event_valid => arp_event_valid, i_arp_event_opcode => arp_event_opcode,
            i_arp_event_sender_mac => arp_event_sender_mac,
            i_arp_event_sender_ip => arp_event_sender_ip,
            i_arp_event_target_mac => arp_event_target_mac,
            i_arp_event_target_ip => arp_event_target_ip,
            i_resolve_req_valid => resolve_req_valid, o_resolve_req_ready => resolve_req_ready,
            i_resolve_ip => resolve_ip, o_resolve_rsp_valid => resolve_rsp_valid,
            o_resolve_rsp_mac => resolve_mac, o_resolve_rsp_failed => resolve_rsp_failed,
            o_debug_resolve_state => open,
            o_debug_tx_state => open,
            o_frame_req_valid => arp_req_valid, i_frame_req_ready => arp_req_ready,
            o_frame_dest_mac => arp_dest_mac, o_frame_ethertype => arp_ethertype,
            o_frame_payload_length => arp_length, o_frame_data_valid => arp_data_valid,
            i_frame_data_ready => arp_data_ready, o_frame_data => arp_data,
            o_frame_valid_bytes => arp_valid_bytes, o_frame_last => arp_last,
            o_frame_abort => arp_abort
        );

    udp_tx_inst : entity work.udp_tx_engine
        port map (
            axi_aclk => aclk, axi_aresetn => aresetn,
            i_dma_base_addr => dma_base_addr, i_local_ipv4_addr => local_ip,
            i_subnet_mask => subnet_mask, i_default_gateway => gateway,
            i_tx_head_ptr => tx_head, i_tx_tail_ptr => tx_tail,
            o_tx_release_valid => tx_release_valid,
            o_debug_state => open,
            o_read_req_valid => read_req_valid, i_read_req_ready => read_req_ready,
            o_read_addr => read_addr, o_read_length => read_length,
            i_read_data_valid => read_data_valid, o_read_data_ready => read_data_ready,
            i_read_data => read_data, i_read_valid_bytes => read_valid_bytes,
            i_read_last => read_last, i_read_done => read_done, i_read_error => read_error,
            o_resolve_req_valid => resolve_req_valid, i_resolve_req_ready => resolve_req_ready,
            o_resolve_ip => resolve_ip, i_resolve_rsp_valid => resolve_rsp_valid,
            i_resolve_rsp_mac => resolve_mac, i_resolve_rsp_failed => resolve_rsp_failed,
            o_frame_req_valid => udp_req_valid, i_frame_req_ready => udp_req_ready,
            o_frame_dest_mac => udp_dest_mac, o_frame_ethertype => udp_ethertype,
            o_frame_payload_length => udp_length, o_frame_data_valid => udp_data_valid,
            i_frame_data_ready => udp_data_ready, o_frame_data => udp_data,
            o_frame_valid_bytes => udp_valid_bytes, o_frame_last => udp_last,
            o_frame_abort => udp_abort
        );

    arbiter_inst : entity work.tx_frame_arbiter
        port map (
            clk => aclk, resetn => aresetn,
            i_arp_req_valid => arp_req_valid, o_arp_req_ready => arp_req_ready,
            i_arp_dest_mac => arp_dest_mac, i_arp_ethertype => arp_ethertype,
            i_arp_length => arp_length, i_arp_data_valid => arp_data_valid,
            o_arp_data_ready => arp_data_ready, i_arp_data => arp_data,
            i_arp_valid_bytes => arp_valid_bytes, i_arp_last => arp_last, i_arp_abort => arp_abort,
            i_udp_req_valid => udp_req_valid, o_udp_req_ready => udp_req_ready,
            i_udp_dest_mac => udp_dest_mac, i_udp_ethertype => udp_ethertype,
            i_udp_length => udp_length, i_udp_data_valid => udp_data_valid,
            o_udp_data_ready => udp_data_ready, i_udp_data => udp_data,
            i_udp_valid_bytes => udp_valid_bytes, i_udp_last => udp_last, i_udp_abort => udp_abort,
            o_frame_req_valid => frame_req_valid, i_frame_req_ready => frame_req_ready,
            o_frame_dest_mac => frame_dest_mac, o_frame_ethertype => frame_ethertype,
            o_frame_length => frame_length, o_frame_data_valid => frame_data_valid,
            i_frame_data_ready => frame_data_ready, o_frame_data => frame_data,
            o_frame_valid_bytes => frame_valid_bytes, o_frame_last => frame_last,
            o_frame_abort => frame_abort
        );

    tx_buffer_mac_inst : entity work.udp_tx_buffer_mac
        generic map (G_LOCAL_MAC => G_LOCAL_MAC)
        port map (
            axi_aclk => aclk, axi_aresetn => aresetn,
            i_ref_clk => i_ref_clk, i_rmii_resetn => i_rmii_resetn,
            i_frame_req_valid => frame_req_valid, o_frame_req_ready => frame_req_ready,
            i_frame_dest_mac => frame_dest_mac, i_frame_ethertype => frame_ethertype,
            i_frame_length => frame_length, i_frame_data_valid => frame_data_valid,
            o_frame_data_ready => frame_data_ready, i_frame_data => frame_data,
            i_frame_valid_bytes => frame_valid_bytes, i_frame_last => frame_last,
            i_frame_abort => frame_abort, o_tx_en => o_tx_en, o_txd => o_txd,
            o_debug_mac_state => open
        );
end architecture;
