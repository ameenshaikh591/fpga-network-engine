library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.udp_engine_pkg.all;

entity udp_rx_engine is
    generic (
        G_LOCAL_MAC : std_logic_vector(47 downto 0) := x"001122334455"
    );
    port (
        axi_aclk    : in std_logic;
        axi_aresetn : in std_logic;

        i_fifo_data  : in  std_logic_vector(9 downto 0);
        i_fifo_empty : in  std_logic;
        o_fifo_read  : out std_logic;

        i_dma_base_addr   : in std_logic_vector(31 downto 0);
        i_local_ipv4_addr : in std_logic_vector(31 downto 0);
        i_socket0_enable  : in std_logic;
        i_socket0_port    : in std_logic_vector(15 downto 0);
        i_socket1_enable  : in std_logic;
        i_socket1_port    : in std_logic_vector(15 downto 0);
        i_rx0_head_ptr    : in t_queue_ptr;
        i_rx0_tail_ptr    : in t_queue_ptr;
        i_rx1_head_ptr    : in t_queue_ptr;
        i_rx1_tail_ptr    : in t_queue_ptr;

        o_write_req_valid : out std_logic;
        i_write_req_ready : in  std_logic;
        o_write_base_addr : out std_logic_vector(31 downto 0);
        o_write_metadata  : out std_logic_vector(127 downto 0);
        o_write_payload_length : out std_logic_vector(15 downto 0);
        o_payload_valid : out std_logic;
        i_payload_ready : in  std_logic;
        o_payload_data  : out std_logic_vector(7 downto 0);
        o_payload_last  : out std_logic;
        o_write_abort   : out std_logic;
        i_write_done    : in  std_logic;
        i_write_error   : in  std_logic;
        i_write_aborted : in  std_logic;

        o_rx_commit_valid  : out std_logic;
        o_rx_commit_socket : out std_logic;

        o_arp_event_valid      : out std_logic;
        o_arp_event_opcode     : out std_logic_vector(15 downto 0);
        o_arp_event_sender_mac : out std_logic_vector(47 downto 0);
        o_arp_event_sender_ip  : out std_logic_vector(31 downto 0);
        o_arp_event_target_mac : out std_logic_vector(47 downto 0);
        o_arp_event_target_ip  : out std_logic_vector(31 downto 0)
    );
end entity;

architecture rtl of udp_rx_engine is
    type t_state is (
        RX_IDLE, RX_ETH_HEADER, RX_DISPATCH,
        RX_ARP_BODY, RX_ARP_DRAIN,
        RX_IPV4_HEADER, RX_IPV4_VALIDATE,
        RX_UDP_HEADER, RX_SOCKET_SELECT, RX_WRITE_REQ,
        RX_UDP_PAYLOAD, RX_IP_DRAIN, RX_WAIT_WRITE, RX_DROP
    );
    signal state : t_state;

    signal eth_count : natural range 0 to 13;
    signal eth_dest_mac, eth_source_mac : std_logic_vector(47 downto 0);
    signal ethertype : std_logic_vector(15 downto 0);

    signal arp_count : natural range 0 to 27;
    signal arp_htype, arp_ptype, arp_opcode : std_logic_vector(15 downto 0);
    signal arp_hlen, arp_plen : std_logic_vector(7 downto 0);
    signal arp_sender_mac, arp_target_mac : std_logic_vector(47 downto 0);
    signal arp_sender_ip, arp_target_ip : std_logic_vector(31 downto 0);

    signal ip_count : natural range 0 to 19;
    signal ip_version_ihl, ip_protocol : std_logic_vector(7 downto 0);
    signal ip_total_length, ip_flags_fragment : std_logic_vector(15 downto 0);
    signal ip_source, ip_destination : std_logic_vector(31 downto 0);
    signal ip_checksum_sum : unsigned(19 downto 0);
    signal ip_checksum_high_byte : std_logic_vector(7 downto 0);

    signal udp_count : natural range 0 to 7;
    signal udp_source_port, udp_destination_port : std_logic_vector(15 downto 0);
    signal udp_length : std_logic_vector(15 downto 0);
    signal udp_payload_length : natural range 0 to C_MAX_UDP_PAYLOAD_BYTES;
    signal payload_count : natural range 0 to C_MAX_UDP_PAYLOAD_BYTES;

    signal selected_socket : std_logic;
    signal selected_tail : t_queue_ptr;
    signal selected_port : std_logic_vector(15 downto 0);
    signal selected_entry_addr : std_logic_vector(31 downto 0);
    signal frame_complete_good : std_logic;
    signal writer_started : std_logic;
    signal writer_done_seen, writer_error_seen, writer_aborted_seen : std_logic;

    signal fifo_take : std_logic;
    signal write_abort_reg : std_logic;
    signal commit_valid_reg, commit_socket_reg : std_logic;
    signal arp_event_valid_reg : std_logic;

    function checksum_is_valid(sum_value : unsigned(19 downto 0)) return boolean is
        variable folded : unsigned(20 downto 0);
    begin
        folded := resize(sum_value(15 downto 0), 21) + resize(sum_value(19 downto 16), 21);
        folded := resize(folded(15 downto 0), 21) + resize(folded(20 downto 16), 21);
        return folded(15 downto 0) = x"FFFF" and
               folded(20 downto 16) = to_unsigned(0, 5);
    end function;

    function is_data(entry : std_logic_vector(9 downto 0)) return boolean is
    begin
        return entry(9 downto 8) = "00";
    end function;
begin
    o_fifo_read <= fifo_take;

    o_write_req_valid <= '1' when state = RX_WRITE_REQ else '0';
    o_write_base_addr <= selected_entry_addr;
    o_write_payload_length <= std_logic_vector(to_unsigned(udp_payload_length, 16));
    o_write_metadata(31 downto 0) <= ip_source;
    o_write_metadata(63 downto 32) <= udp_destination_port & udp_source_port;
    o_write_metadata(95 downto 64) <= x"0000" & std_logic_vector(to_unsigned(udp_payload_length, 16));
    o_write_metadata(127 downto 96) <= (others => '0');

    o_payload_valid <= '1' when state = RX_UDP_PAYLOAD and i_fifo_empty = '0' and
                                i_fifo_data(9 downto 8) = "00" else '0';
    o_payload_data <= i_fifo_data(7 downto 0);
    o_payload_last <= '1' when state = RX_UDP_PAYLOAD and
                               payload_count + 1 = udp_payload_length else '0';
    o_write_abort <= write_abort_reg;

    o_rx_commit_valid <= commit_valid_reg;
    o_rx_commit_socket <= commit_socket_reg;
    o_arp_event_valid <= arp_event_valid_reg;
    o_arp_event_opcode <= arp_opcode;
    o_arp_event_sender_mac <= arp_sender_mac;
    o_arp_event_sender_ip <= arp_sender_ip;
    o_arp_event_target_mac <= arp_target_mac;
    o_arp_event_target_ip <= arp_target_ip;

    process(all)
    begin
        fifo_take <= '0';
        if i_fifo_empty = '0' then
            case state is
                when RX_IDLE | RX_ETH_HEADER | RX_ARP_BODY | RX_ARP_DRAIN |
                     RX_IPV4_HEADER | RX_UDP_HEADER | RX_IP_DRAIN | RX_DROP =>
                    fifo_take <= '1';
                when RX_UDP_PAYLOAD =>
                    if i_fifo_data(9 downto 8) /= "00" or i_payload_ready = '1' then
                        fifo_take <= '1';
                    end if;
                when others =>
                    fifo_take <= '0';
            end case;
        end if;
    end process;

    process(axi_aclk)
        variable entry_byte : std_logic_vector(7 downto 0);
        variable final_ethertype : std_logic_vector(15 downto 0);
        variable total_length_int, udp_length_int : natural;
        variable socket0_match, socket1_match : boolean;
        variable header_valid : boolean;
        variable checksum_word : unsigned(15 downto 0);
    begin
        if rising_edge(axi_aclk) then
            write_abort_reg <= '0';
            commit_valid_reg <= '0';
            arp_event_valid_reg <= '0';

            if axi_aresetn = '0' then
                state <= RX_IDLE;
                eth_count <= 0;
                eth_dest_mac <= (others => '0');
                eth_source_mac <= (others => '0');
                ethertype <= (others => '0');
                arp_count <= 0;
                arp_htype <= (others => '0');
                arp_ptype <= (others => '0');
                arp_hlen <= (others => '0');
                arp_plen <= (others => '0');
                arp_opcode <= (others => '0');
                arp_sender_mac <= (others => '0');
                arp_sender_ip <= (others => '0');
                arp_target_mac <= (others => '0');
                arp_target_ip <= (others => '0');
                ip_count <= 0;
                ip_version_ihl <= (others => '0');
                ip_protocol <= (others => '0');
                ip_total_length <= (others => '0');
                ip_flags_fragment <= (others => '0');
                ip_source <= (others => '0');
                ip_destination <= (others => '0');
                ip_checksum_sum <= (others => '0');
                ip_checksum_high_byte <= (others => '0');
                udp_count <= 0;
                udp_source_port <= (others => '0');
                udp_destination_port <= (others => '0');
                udp_length <= (others => '0');
                udp_payload_length <= 0;
                payload_count <= 0;
                selected_socket <= '0';
                selected_tail <= (others => '0');
                selected_port <= (others => '0');
                selected_entry_addr <= (others => '0');
                frame_complete_good <= '0';
                writer_started <= '0';
                writer_done_seen <= '0';
                writer_error_seen <= '0';
                writer_aborted_seen <= '0';
                commit_socket_reg <= '0';
            else
                if writer_started = '1' then
                    if i_write_done = '1' then writer_done_seen <= '1'; end if;
                    if i_write_error = '1' then writer_error_seen <= '1'; end if;
                    if i_write_aborted = '1' then writer_aborted_seen <= '1'; end if;
                end if;

                -- A writer failure must never leave the parser waiting to feed
                -- a mover which has already returned to idle.
                if writer_started = '1' and (i_write_error = '1' or i_write_aborted = '1') and
                   state = RX_UDP_PAYLOAD then
                    frame_complete_good <= '0';
                    state <= RX_DROP;
                else
                    case state is
                        when RX_IDLE =>
                            writer_started <= '0';
                            writer_done_seen <= '0';
                            writer_error_seen <= '0';
                            writer_aborted_seen <= '0';
                            frame_complete_good <= '0';
                            if fifo_take = '1' then
                                if is_data(i_fifo_data) then
                                    eth_dest_mac <= (others => '0');
                                    eth_source_mac <= (others => '0');
                                    ethertype <= (others => '0');
                                    eth_dest_mac(7 downto 0) <= i_fifo_data(7 downto 0);
                                    eth_count <= 1;
                                    state <= RX_ETH_HEADER;
                                end if;
                            end if;

                        when RX_ETH_HEADER =>
                            if fifo_take = '1' then
                                if not is_data(i_fifo_data) then
                                    state <= RX_IDLE;
                                else
                                    entry_byte := i_fifo_data(7 downto 0);
                                    if eth_count < 6 then
                                        eth_dest_mac <= eth_dest_mac(39 downto 0) & entry_byte;
                                    elsif eth_count < 12 then
                                        eth_source_mac <= eth_source_mac(39 downto 0) & entry_byte;
                                    else
                                        ethertype <= ethertype(7 downto 0) & entry_byte;
                                    end if;

                                    if eth_count = 13 then
                                        final_ethertype := ethertype(7 downto 0) & entry_byte;
                                        if eth_dest_mac /= G_LOCAL_MAC and eth_dest_mac /= x"FFFFFFFFFFFF" then
                                            state <= RX_DROP;
                                        elsif final_ethertype = C_ETHERTYPE_ARP then
                                            arp_count <= 0;
                                            arp_htype <= (others => '0');
                                            arp_ptype <= (others => '0');
                                            arp_hlen <= (others => '0');
                                            arp_plen <= (others => '0');
                                            arp_opcode <= (others => '0');
                                            arp_sender_mac <= (others => '0');
                                            arp_sender_ip <= (others => '0');
                                            arp_target_mac <= (others => '0');
                                            arp_target_ip <= (others => '0');
                                            state <= RX_ARP_BODY;
                                        elsif final_ethertype = C_ETHERTYPE_IPV4 then
                                            ip_count <= 0;
                                            ip_checksum_sum <= (others => '0');
                                            state <= RX_IPV4_HEADER;
                                        else
                                            state <= RX_DROP;
                                        end if;
                                    else
                                        eth_count <= eth_count + 1;
                                    end if;
                                end if;
                            end if;

                        when RX_DISPATCH =>
                            state <= RX_DROP; -- unreachable defensive state

                        when RX_ARP_BODY =>
                            if fifo_take = '1' then
                                if not is_data(i_fifo_data) then
                                    state <= RX_IDLE;
                                else
                                    entry_byte := i_fifo_data(7 downto 0);
                                    case arp_count is
                                        when 0 | 1 => arp_htype <= arp_htype(7 downto 0) & entry_byte;
                                        when 2 | 3 => arp_ptype <= arp_ptype(7 downto 0) & entry_byte;
                                        when 4 => arp_hlen <= entry_byte;
                                        when 5 => arp_plen <= entry_byte;
                                        when 6 | 7 => arp_opcode <= arp_opcode(7 downto 0) & entry_byte;
                                        when 8 to 13 => arp_sender_mac <= arp_sender_mac(39 downto 0) & entry_byte;
                                        when 14 to 17 => arp_sender_ip <= arp_sender_ip(23 downto 0) & entry_byte;
                                        when 18 to 23 => arp_target_mac <= arp_target_mac(39 downto 0) & entry_byte;
                                        when others => arp_target_ip <= arp_target_ip(23 downto 0) & entry_byte;
                                    end case;
                                    if arp_count = 27 then
                                        state <= RX_ARP_DRAIN;
                                    else
                                        arp_count <= arp_count + 1;
                                    end if;
                                end if;
                            end if;

                        when RX_ARP_DRAIN =>
                            if fifo_take = '1' and not is_data(i_fifo_data) then
                                if i_fifo_data(9 downto 8) = "10" and
                                   arp_htype = x"0001" and arp_ptype = x"0800" and
                                   arp_hlen = x"06" and arp_plen = x"04" and
                                   (arp_opcode = x"0001" or arp_opcode = x"0002") then
                                    arp_event_valid_reg <= '1';
                                end if;
                                state <= RX_IDLE;
                            end if;

                        when RX_IPV4_HEADER =>
                            if fifo_take = '1' then
                                if not is_data(i_fifo_data) then
                                    state <= RX_IDLE;
                                else
                                    entry_byte := i_fifo_data(7 downto 0);
                                    if (ip_count mod 2) = 0 then
                                        ip_checksum_high_byte <= entry_byte;
                                    else
                                        checksum_word(15 downto 8) := unsigned(ip_checksum_high_byte);
                                        checksum_word(7 downto 0) := unsigned(entry_byte);
                                        ip_checksum_sum <= ip_checksum_sum + checksum_word;
                                    end if;
                                    case ip_count is
                                        when 0 => ip_version_ihl <= entry_byte;
                                        when 2 | 3 => ip_total_length <= ip_total_length(7 downto 0) & entry_byte;
                                        when 6 | 7 => ip_flags_fragment <= ip_flags_fragment(7 downto 0) & entry_byte;
                                        when 9 => ip_protocol <= entry_byte;
                                        when 12 to 15 => ip_source <= ip_source(23 downto 0) & entry_byte;
                                        when 16 to 19 => ip_destination <= ip_destination(23 downto 0) & entry_byte;
                                        when others => null;
                                    end case;
                                    if ip_count = 19 then
                                        state <= RX_IPV4_VALIDATE;
                                    else
                                        ip_count <= ip_count + 1;
                                    end if;
                                end if;
                            end if;

                        when RX_IPV4_VALIDATE =>
                            total_length_int := to_integer(unsigned(ip_total_length));
                            header_valid := ip_version_ihl = x"45" and
                                total_length_int >= 28 and total_length_int <= C_MAX_IPV4_BYTES and
                                ip_protocol = C_IP_PROTOCOL_UDP and
                                ip_destination = i_local_ipv4_addr and
                                ip_flags_fragment(13) = '0' and
                                ip_flags_fragment(12 downto 0) = "0000000000000" and
                                checksum_is_valid(ip_checksum_sum);
                            if header_valid then
                                udp_count <= 0;
                                udp_source_port <= (others => '0');
                                udp_destination_port <= (others => '0');
                                udp_length <= (others => '0');
                                state <= RX_UDP_HEADER;
                            else
                                state <= RX_DROP;
                            end if;

                        when RX_UDP_HEADER =>
                            if fifo_take = '1' then
                                if not is_data(i_fifo_data) then
                                    state <= RX_IDLE;
                                else
                                    entry_byte := i_fifo_data(7 downto 0);
                                    case udp_count is
                                        when 0 | 1 => udp_source_port <= udp_source_port(7 downto 0) & entry_byte;
                                        when 2 | 3 => udp_destination_port <= udp_destination_port(7 downto 0) & entry_byte;
                                        when 4 | 5 => udp_length <= udp_length(7 downto 0) & entry_byte;
                                        when others => null; -- checksum intentionally ignored
                                    end case;
                                    if udp_count = 7 then
                                        state <= RX_SOCKET_SELECT;
                                    else
                                        udp_count <= udp_count + 1;
                                    end if;
                                end if;
                            end if;

                        when RX_SOCKET_SELECT =>
                            total_length_int := to_integer(unsigned(ip_total_length));
                            udp_length_int := to_integer(unsigned(udp_length));
                            socket0_match := i_socket0_enable = '1' and i_socket0_port = udp_destination_port;
                            socket1_match := i_socket1_enable = '1' and i_socket1_port = udp_destination_port;
                            if udp_length_int < 8 then
                                state <= RX_DROP;
                            elsif udp_length_int /= total_length_int - 20 then
                                state <= RX_DROP;
                            elsif udp_length_int - 8 > C_MAX_UDP_PAYLOAD_BYTES or
                                  udp_destination_port = x"0000" or socket0_match = socket1_match then
                                state <= RX_DROP;
                            elsif socket0_match then
                                if queue_full(i_rx0_head_ptr, i_rx0_tail_ptr) then
                                    state <= RX_DROP;
                                else
                                    selected_socket <= '0';
                                    selected_tail <= i_rx0_tail_ptr;
                                    selected_port <= udp_destination_port;
                                    selected_entry_addr <= rx_entry_address(i_dma_base_addr, '0', i_rx0_tail_ptr(1 downto 0));
                                    udp_payload_length <= udp_length_int - 8;
                                    state <= RX_WRITE_REQ;
                                end if;
                            else
                                if queue_full(i_rx1_head_ptr, i_rx1_tail_ptr) then
                                    state <= RX_DROP;
                                else
                                    selected_socket <= '1';
                                    selected_tail <= i_rx1_tail_ptr;
                                    selected_port <= udp_destination_port;
                                    selected_entry_addr <= rx_entry_address(i_dma_base_addr, '1', i_rx1_tail_ptr(1 downto 0));
                                    udp_payload_length <= udp_length_int - 8;
                                    state <= RX_WRITE_REQ;
                                end if;
                            end if;

                        when RX_WRITE_REQ =>
                            if i_write_req_ready = '1' then
                                writer_started <= '1';
                                writer_done_seen <= '0';
                                writer_error_seen <= '0';
                                writer_aborted_seen <= '0';
                                payload_count <= 0;
                                if udp_payload_length = 0 then
                                    state <= RX_IP_DRAIN;
                                else
                                    state <= RX_UDP_PAYLOAD;
                                end if;
                            end if;

                        when RX_UDP_PAYLOAD =>
                            if fifo_take = '1' then
                                if not is_data(i_fifo_data) then
                                    write_abort_reg <= '1';
                                    frame_complete_good <= '0';
                                    state <= RX_WAIT_WRITE;
                                elsif payload_count + 1 = udp_payload_length then
                                    payload_count <= payload_count + 1;
                                    state <= RX_IP_DRAIN;
                                else
                                    payload_count <= payload_count + 1;
                                end if;
                            end if;

                        when RX_IP_DRAIN =>
                            if fifo_take = '1' and not is_data(i_fifo_data) then
                                if i_fifo_data(9 downto 8) = "10" then
                                    frame_complete_good <= '1';
                                else
                                    frame_complete_good <= '0';
                                    write_abort_reg <= '1';
                                end if;
                                state <= RX_WAIT_WRITE;
                            end if;

                        when RX_WAIT_WRITE =>
                            if writer_error_seen = '1' or writer_aborted_seen = '1' or
                               i_write_error = '1' or i_write_aborted = '1' then
                                writer_started <= '0';
                                state <= RX_IDLE;
                            elsif writer_done_seen = '1' or i_write_done = '1' then
                                writer_started <= '0';
                                if frame_complete_good = '1' then
                                    if selected_socket = '0' and i_socket0_enable = '1' and
                                       i_socket0_port = selected_port and i_rx0_tail_ptr = selected_tail then
                                        commit_valid_reg <= '1';
                                        commit_socket_reg <= '0';
                                    elsif selected_socket = '1' and i_socket1_enable = '1' and
                                          i_socket1_port = selected_port and i_rx1_tail_ptr = selected_tail then
                                        commit_valid_reg <= '1';
                                        commit_socket_reg <= '1';
                                    end if;
                                end if;
                                state <= RX_IDLE;
                            end if;

                        when RX_DROP =>
                            if writer_started = '1' then
                                write_abort_reg <= '1';
                            end if;
                            if fifo_take = '1' and not is_data(i_fifo_data) then
                                if writer_started = '1' then
                                    frame_complete_good <= '0';
                                    state <= RX_WAIT_WRITE;
                                else
                                    state <= RX_IDLE;
                                end if;
                            end if;
                    end case;
                end if;
            end if;
        end if;
    end process;
end architecture;
