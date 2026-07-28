library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.udp_engine_pkg.all;

entity udp_tx_engine is
    port (
        axi_aclk    : in std_logic;
        axi_aresetn : in std_logic;

        i_dma_base_addr   : in std_logic_vector(31 downto 0);
        i_local_ipv4_addr : in std_logic_vector(31 downto 0);
        i_subnet_mask     : in std_logic_vector(31 downto 0);
        i_default_gateway : in std_logic_vector(31 downto 0);
        i_tx_head_ptr     : in t_queue_ptr;
        i_tx_tail_ptr     : in t_queue_ptr;
        o_tx_release_valid : out std_logic;
        o_debug_state      : out std_logic_vector(3 downto 0);

        o_read_req_valid : out std_logic;
        i_read_req_ready : in  std_logic;
        o_read_addr      : out std_logic_vector(31 downto 0);
        o_read_length    : out std_logic_vector(15 downto 0);
        i_read_data_valid : in std_logic;
        o_read_data_ready : out std_logic;
        i_read_data       : in std_logic_vector(31 downto 0);
        i_read_valid_bytes : in std_logic_vector(1 downto 0);
        i_read_last       : in std_logic;
        i_read_done       : in std_logic;
        i_read_error      : in std_logic;

        o_resolve_req_valid : out std_logic;
        i_resolve_req_ready : in  std_logic;
        o_resolve_ip        : out std_logic_vector(31 downto 0);
        i_resolve_rsp_valid  : in std_logic;
        i_resolve_rsp_mac    : in std_logic_vector(47 downto 0);
        i_resolve_rsp_failed : in std_logic;

        o_frame_req_valid   : out std_logic;
        i_frame_req_ready   : in  std_logic;
        o_frame_dest_mac    : out std_logic_vector(47 downto 0);
        o_frame_ethertype   : out std_logic_vector(15 downto 0);
        o_frame_payload_length : out std_logic_vector(15 downto 0);
        o_frame_data_valid  : out std_logic;
        i_frame_data_ready  : in  std_logic;
        o_frame_data        : out std_logic_vector(31 downto 0);
        o_frame_valid_bytes : out std_logic_vector(1 downto 0);
        o_frame_last        : out std_logic;
        o_frame_abort       : out std_logic
    );
end entity;

architecture rtl of udp_tx_engine is
    type t_state is (
        T_IDLE, T_META_REQ, T_META_RECV, T_VALIDATE,
        T_RESOLVE_REQ, T_RESOLVE_WAIT, T_IP_CHECKSUM,
        T_FRAME_REQ, T_HEADER_STREAM, T_PAYLOAD_REQ,
        T_PAYLOAD_STREAM, T_RELEASE, T_DROP
    );
    type t_metadata_word is (
        M_DESTINATION_IP, M_PORTS, M_PAYLOAD_LENGTH, M_RESERVED
    );

    signal state : t_state;
    signal latched_head : t_queue_ptr;
    signal descriptor_addr : std_logic_vector(31 downto 0);
    signal current_metadata_word : t_metadata_word;
    signal destination_ip : std_logic_vector(31 downto 0);
    signal source_port, destination_port : std_logic_vector(15 downto 0);
    signal payload_length : natural range 0 to 65535;
    signal next_hop_ip : std_logic_vector(31 downto 0);
    signal resolved_mac : std_logic_vector(47 downto 0);
    signal ip_identification : unsigned(15 downto 0);
    signal ip_checksum : std_logic_vector(15 downto 0);
    signal checksum_sum : unsigned(19 downto 0);
    signal checksum_index : natural range 0 to 9;
    signal header_word_index : natural range 0 to 6;

    function ip_word(
        index : natural;
        total_length : natural;
        identification : unsigned(15 downto 0);
        source_ip : std_logic_vector(31 downto 0);
        dest_ip : std_logic_vector(31 downto 0)
    ) return unsigned is
    begin
        case index is
            when 0 => 
                return unsigned'(x"4500");
            when 1 => 
                return to_unsigned(total_length, 16);
            when 2 => 
                return identification;
            when 3 => 
                return unsigned'(x"4000");
            when 4 => 
                return unsigned'(x"4011");
            when 5 => 
                return unsigned'(x"0000");
            when 6 => 
                return unsigned(source_ip(31 downto 16));
            when 7 => 
                return unsigned(source_ip(15 downto 0));
            when 8 => 
                return unsigned(dest_ip(31 downto 16));
            when others => 
                return unsigned(dest_ip(15 downto 0));
        end case;
    end function;

    function checksum_finalize(sum_value : unsigned(19 downto 0))
        return std_logic_vector is
        variable folded : unsigned(20 downto 0);
    begin
        folded := resize(sum_value(15 downto 0), 21) + resize(sum_value(19 downto 16), 21);
        folded := resize(folded(15 downto 0), 21) + resize(folded(20 downto 16), 21);
        return not std_logic_vector(folded(15 downto 0));
    end function;

    function make_header_word(
        index : natural;
        app_length : natural;
        identification : unsigned(15 downto 0);
        checksum : std_logic_vector(15 downto 0);
        source_ip, dest_ip : std_logic_vector(31 downto 0);
        src_port, dst_port : std_logic_vector(15 downto 0)
    ) return std_logic_vector is
        variable ip_length : unsigned(15 downto 0);
        variable udp_len : unsigned(15 downto 0);
    begin
        ip_length := to_unsigned(C_IPV4_HEADER_BYTES + C_UDP_HEADER_BYTES + app_length, 16);
        udp_len := to_unsigned(C_UDP_HEADER_BYTES + app_length, 16);
        case index is
            when 0 => return pack4(x"45", x"00", std_logic_vector(ip_length(15 downto 8)),
                                    std_logic_vector(ip_length(7 downto 0)));
            when 1 => return pack4(std_logic_vector(identification(15 downto 8)),
                                    std_logic_vector(identification(7 downto 0)), x"40", x"00");
            when 2 => return pack4(x"40", x"11", checksum(15 downto 8), checksum(7 downto 0));
            when 3 => return pack4(source_ip(31 downto 24), source_ip(23 downto 16),
                                    source_ip(15 downto 8), source_ip(7 downto 0));
            when 4 => return pack4(dest_ip(31 downto 24), dest_ip(23 downto 16),
                                    dest_ip(15 downto 8), dest_ip(7 downto 0));
            when 5 => return pack4(src_port(15 downto 8), src_port(7 downto 0),
                                    dst_port(15 downto 8), dst_port(7 downto 0));
            when others => return pack4(std_logic_vector(udp_len(15 downto 8)),
                                         std_logic_vector(udp_len(7 downto 0)), x"00", x"00");
        end case;
    end function;

    function supported_unicast(ip : std_logic_vector(31 downto 0)) return boolean is
        variable first_octet : natural;
    begin
        first_octet := to_integer(unsigned(ip(31 downto 24)));
        return ip /= x"00000000" and ip /= x"FFFFFFFF" and
               first_octet /= 0 and first_octet /= 127 and not (first_octet >= 224 and first_octet <= 239);
    end function;

    function frame_length_value(app_length : natural) return std_logic_vector is
    begin
        if app_length <= C_MAX_UDP_PAYLOAD_BYTES then
            return std_logic_vector(to_unsigned(
                C_IPV4_HEADER_BYTES + C_UDP_HEADER_BYTES + app_length, 16));
        end if;
        return (15 downto 0 => '0');
    end function;
begin
    -- T_IDLE=0, T_META_REQ=1, T_META_RECV=2, T_VALIDATE=3,
    -- T_RESOLVE_REQ=4, T_RESOLVE_WAIT=5, T_IP_CHECKSUM=6,
    -- T_FRAME_REQ=7, T_HEADER_STREAM=8, T_PAYLOAD_REQ=9,
    -- T_PAYLOAD_STREAM=10, T_RELEASE=11, T_DROP=12.
    o_debug_state <= std_logic_vector(to_unsigned(t_state'pos(state), o_debug_state'length));

    -- T_RELEASE and T_DROP are registered FSM states, so this is a clean
    -- one-cycle synchronous pulse.  The status manager advances TX_HEAD on
    -- the same edge that returns this engine to T_IDLE.
    o_tx_release_valid <= '1' when state = T_RELEASE or state = T_DROP else '0';

    o_read_req_valid <= '1' when state = T_META_REQ or state = T_PAYLOAD_REQ else '0';
    o_read_addr <= descriptor_addr when state = T_META_REQ else std_logic_vector(unsigned(descriptor_addr) + C_DMA_METADATA_BYTES);
    o_read_length <= x"0010" when state = T_META_REQ else std_logic_vector(to_unsigned(payload_length, 16));
    o_read_data_ready <= '1' when state = T_META_RECV else i_frame_data_ready when state = T_PAYLOAD_STREAM else '0';

    o_resolve_req_valid <= '1' when state = T_RESOLVE_REQ else '0';
    o_resolve_ip <= next_hop_ip;

    o_frame_req_valid <= '1' when state = T_FRAME_REQ else '0';
    o_frame_dest_mac <= resolved_mac;
    o_frame_ethertype <= C_ETHERTYPE_IPV4;
    o_frame_payload_length <= frame_length_value(payload_length);
    o_frame_data_valid <= '1' when state = T_HEADER_STREAM else i_read_data_valid when state = T_PAYLOAD_STREAM else '0';
    o_frame_data <= make_header_word(header_word_index, payload_length, ip_identification,
                                     ip_checksum, i_local_ipv4_addr, destination_ip,
                                     source_port, destination_port)
                    when state = T_HEADER_STREAM else i_read_data;
    o_frame_valid_bytes <= "00" when state = T_HEADER_STREAM else i_read_valid_bytes;
    o_frame_last <= '1' when state = T_HEADER_STREAM and header_word_index = 6 and payload_length = 0 else
                    i_read_last when state = T_PAYLOAD_STREAM else '0';
    o_frame_abort <= '1' when state = T_PAYLOAD_STREAM and i_read_error = '1' else '0';

    process(axi_aclk)
        variable region_end : unsigned(32 downto 0);
        variable ip_total_length : natural;
        variable sum_next : unsigned(19 downto 0);
    begin
        if rising_edge(axi_aclk) then
            if axi_aresetn = '0' then
                state <= T_IDLE;
                latched_head <= (others => '0');
                descriptor_addr <= (others => '0');
                current_metadata_word <= M_DESTINATION_IP;
                destination_ip <= (others => '0');
                source_port <= (others => '0');
                destination_port <= (others => '0');
                payload_length <= 0;
                next_hop_ip <= (others => '0');
                resolved_mac <= (others => '0');
                ip_identification <= (others => '0');
                ip_checksum <= (others => '0');
                checksum_sum <= (others => '0');
                checksum_index <= 0;
                header_word_index <= 0;
            else
                case state is
                    when T_IDLE =>
                        if i_tx_head_ptr /= i_tx_tail_ptr then
                            latched_head    <= i_tx_head_ptr;
                            descriptor_addr <= tx_entry_address(i_dma_base_addr, i_tx_head_ptr(1 downto 0));
                            current_metadata_word <= M_DESTINATION_IP;

                            state <= T_META_REQ;
                        end if;

                    when T_META_REQ =>
                        if i_read_req_ready = '1' then
                            state <= T_META_RECV;
                        end if;

                    when T_META_RECV =>
                        -- Metadata field of the TX entry comprises the first four words (0x0 - 0xF)
                        -- AXI Reader provides one word, starting with word at 0x0, upon each valid/ready handshake
                        -- Four valid/ready handshakes (i_read_data_valid/o_read_data_ready) occur to receive the full metadata field
                        if i_read_error = '1' then
                            state <= T_DROP;
                        elsif i_read_data_valid = '1' then
                            case current_metadata_word is
                                when M_DESTINATION_IP =>
                                    destination_ip <= i_read_data;
                                when M_PORTS =>
                                    destination_port <= i_read_data(15 downto 0);
                                    source_port <= i_read_data(31 downto 16);
                                when M_PAYLOAD_LENGTH =>
                                    payload_length <= to_integer(unsigned(i_read_data(15 downto 0)));
                                when M_RESERVED =>
                                    null;
                            end case;
                            if i_read_last = '1' then
                                if current_metadata_word = M_RESERVED then
                                    state <= T_VALIDATE;
                                else
                                    state <= T_DROP;
                                end if;
                            elsif current_metadata_word = M_RESERVED then
                                state <= T_DROP;
                            else
                                current_metadata_word <= t_metadata_word'succ(current_metadata_word);
                            end if;
                        end if;

                    when T_VALIDATE =>
                        region_end := resize(unsigned(i_dma_base_addr), 33) + C_DMA_REGION_BYTES - 1;
                        if payload_length > C_MAX_UDP_PAYLOAD_BYTES or
                           source_port = x"0000" or destination_port = x"0000" or
                           not supported_unicast(destination_ip) or destination_ip = i_local_ipv4_addr or
                           not supported_unicast(i_local_ipv4_addr) or i_subnet_mask = x"00000000" or
                           region_end(32) = '1' then
                            state <= T_DROP;
                        elsif (destination_ip and i_subnet_mask) =
                              (i_local_ipv4_addr and i_subnet_mask) then
                            next_hop_ip <= destination_ip;
                            state <= T_RESOLVE_REQ;
                        elsif supported_unicast(i_default_gateway) and
                              i_default_gateway /= i_local_ipv4_addr then
                            next_hop_ip <= i_default_gateway;
                            state <= T_RESOLVE_REQ;
                        else
                            state <= T_DROP;
                        end if;

                    when T_RESOLVE_REQ =>
                        if i_resolve_req_ready = '1' then
                            state <= T_RESOLVE_WAIT;
                        end if;

                    when T_RESOLVE_WAIT =>
                        if i_resolve_rsp_valid = '1' then
                            if i_resolve_rsp_failed = '1' then
                                state <= T_DROP;
                            else
                                resolved_mac <= i_resolve_rsp_mac;
                                checksum_sum <= (others => '0');
                                checksum_index <= 0;
                                state <= T_IP_CHECKSUM;
                            end if;
                        end if;

                    when T_IP_CHECKSUM =>
                        ip_total_length := C_IPV4_HEADER_BYTES + C_UDP_HEADER_BYTES + payload_length;
                        sum_next := checksum_sum + resize(ip_word(checksum_index, ip_total_length,
                            ip_identification, i_local_ipv4_addr, destination_ip), checksum_sum'length);
                        checksum_sum <= sum_next;
                        if checksum_index = 9 then
                            ip_checksum <= checksum_finalize(sum_next);
                            state <= T_FRAME_REQ;
                        else
                            checksum_index <= checksum_index + 1;
                        end if;

                    when T_FRAME_REQ =>
                        if i_frame_req_ready = '1' then
                            header_word_index <= 0;
                            state <= T_HEADER_STREAM;
                        end if;

                    when T_HEADER_STREAM =>
                        if i_frame_data_ready = '1' then
                            if header_word_index = 6 then
                                if payload_length = 0 then
                                    state <= T_RELEASE;
                                else
                                    state <= T_PAYLOAD_REQ;
                                end if;
                            else
                                header_word_index <= header_word_index + 1;
                            end if;
                        end if;

                    when T_PAYLOAD_REQ =>
                        if i_read_req_ready = '1' then
                            state <= T_PAYLOAD_STREAM;
                        end if;

                    when T_PAYLOAD_STREAM =>
                        if i_read_error = '1' then
                            state <= T_DROP;
                        elsif i_read_data_valid = '1' and i_frame_data_ready = '1' and i_read_last = '1' then
                            state <= T_RELEASE;
                        end if;

                    when T_RELEASE =>
                        ip_identification <= ip_identification + 1;
                        state <= T_IDLE;

                    when T_DROP =>
                        state <= T_IDLE;
                end case;
            end if;
        end if;
    end process;
end architecture;
