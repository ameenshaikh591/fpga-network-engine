library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.udp_engine_pkg.all;

entity arp_manager is
    generic (
        G_LOCAL_MAC : std_logic_vector(47 downto 0) := x"001122334455";
        G_RETRY_INTERVAL_CYCLES : positive := 500000000;
        G_MAX_REQUESTS : positive := 3
    );
    port (
        axi_aclk    : in std_logic;
        axi_aresetn : in std_logic;
        i_local_ipv4_addr : in std_logic_vector(31 downto 0);
        i_network_config_changed : in std_logic;

        i_arp_event_valid      : in std_logic;
        i_arp_event_opcode     : in std_logic_vector(15 downto 0);
        i_arp_event_sender_mac : in std_logic_vector(47 downto 0);
        i_arp_event_sender_ip  : in std_logic_vector(31 downto 0);
        i_arp_event_target_mac : in std_logic_vector(47 downto 0);
        i_arp_event_target_ip  : in std_logic_vector(31 downto 0);

        i_resolve_req_valid : in  std_logic;
        o_resolve_req_ready : out std_logic;
        i_resolve_ip        : in  std_logic_vector(31 downto 0);
        o_resolve_rsp_valid  : out std_logic;
        o_resolve_rsp_mac    : out std_logic_vector(47 downto 0);
        o_resolve_rsp_failed : out std_logic;
        o_debug_resolve_state : out std_logic_vector(1 downto 0);
        o_debug_tx_state      : out std_logic_vector(1 downto 0);

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

architecture rtl of arp_manager is
    type t_ip_cache is array (0 to 3) of std_logic_vector(31 downto 0);
    type t_mac_cache is array (0 to 3) of std_logic_vector(47 downto 0);
    type t_resolve_state is (R_IDLE, R_LOOKUP, R_WAIT_REQUEST_SENT, R_WAIT_REPLY);
    type t_tx_state is (ATX_IDLE, ATX_FRAME_REQUEST, ATX_STREAM);

    signal cache_valid : std_logic_vector(3 downto 0);
    signal cache_ip : t_ip_cache;
    signal cache_mac : t_mac_cache;
    signal replacement_index : natural range 0 to 3;

    signal resolve_state : t_resolve_state;
    signal pending_ip : std_logic_vector(31 downto 0);
    signal retry_timer : natural range 0 to G_RETRY_INTERVAL_CYCLES - 1;
    signal request_count : natural range 0 to G_MAX_REQUESTS;
    signal resolver_request_pending : std_logic;
    signal resolve_rsp_valid_reg, resolve_rsp_failed_reg : std_logic;
    signal resolve_rsp_mac_reg : std_logic_vector(47 downto 0);

    signal reply_pending : std_logic;
    signal reply_mac : std_logic_vector(47 downto 0);
    signal reply_ip : std_logic_vector(31 downto 0);

    signal tx_state : t_tx_state;
    signal tx_is_reply : std_logic;
    signal tx_dest_mac, tx_target_mac : std_logic_vector(47 downto 0);
    signal tx_target_ip : std_logic_vector(31 downto 0);
    signal tx_word_index : natural range 0 to 6;
    signal request_sent_pulse : std_logic;

    function mac_byte(mac : std_logic_vector(47 downto 0); index : natural)
        return std_logic_vector is
    begin
        return mac(47 - index * 8 downto 40 - index * 8);
    end function;

    function ip_byte(ip : std_logic_vector(31 downto 0); index : natural)
        return std_logic_vector is
    begin
        return ip(31 - index * 8 downto 24 - index * 8);
    end function;

    function make_arp_word(
        word_index : natural;
        is_reply : std_logic;
        target_mac : std_logic_vector(47 downto 0);
        target_ip : std_logic_vector(31 downto 0);
        local_ip : std_logic_vector(31 downto 0)
    ) return std_logic_vector is
        variable opcode_low : std_logic_vector(7 downto 0);
    begin
        if is_reply = '1' then opcode_low := x"02"; else opcode_low := x"01"; end if;
        case word_index is
            when 0 => return pack4(x"00", x"01", x"08", x"00");
            when 1 => return pack4(x"06", x"04", x"00", opcode_low);
            when 2 => return pack4(mac_byte(G_LOCAL_MAC, 0), mac_byte(G_LOCAL_MAC, 1),
                                   mac_byte(G_LOCAL_MAC, 2), mac_byte(G_LOCAL_MAC, 3));
            when 3 => return pack4(mac_byte(G_LOCAL_MAC, 4), mac_byte(G_LOCAL_MAC, 5),
                                   ip_byte(local_ip, 0), ip_byte(local_ip, 1));
            when 4 => return pack4(ip_byte(local_ip, 2), ip_byte(local_ip, 3),
                                   mac_byte(target_mac, 0), mac_byte(target_mac, 1));
            when 5 => return pack4(mac_byte(target_mac, 2), mac_byte(target_mac, 3),
                                   mac_byte(target_mac, 4), mac_byte(target_mac, 5));
            when others => return pack4(ip_byte(target_ip, 0), ip_byte(target_ip, 1),
                                        ip_byte(target_ip, 2), ip_byte(target_ip, 3));
        end case;
    end function;
begin
    -- Resolver: R_IDLE=0, R_LOOKUP=1, R_WAIT_REQUEST_SENT=2, R_WAIT_REPLY=3.
    o_debug_resolve_state <= std_logic_vector(
        to_unsigned(t_resolve_state'pos(resolve_state), o_debug_resolve_state'length));

    -- ARP producer: ATX_IDLE=0, ATX_FRAME_REQUEST=1, ATX_STREAM=2.
    o_debug_tx_state <= std_logic_vector(
        to_unsigned(t_tx_state'pos(tx_state), o_debug_tx_state'length));

    o_resolve_req_ready <= '1' when resolve_state = R_IDLE else '0';
    o_resolve_rsp_valid <= resolve_rsp_valid_reg;
    o_resolve_rsp_mac <= resolve_rsp_mac_reg;
    o_resolve_rsp_failed <= resolve_rsp_failed_reg;

    o_frame_req_valid <= '1' when tx_state = ATX_FRAME_REQUEST else '0';
    o_frame_dest_mac <= tx_dest_mac;
    o_frame_ethertype <= C_ETHERTYPE_ARP;
    o_frame_payload_length <= std_logic_vector(to_unsigned(C_ARP_PAYLOAD_BYTES, 16));
    o_frame_data_valid <= '1' when tx_state = ATX_STREAM else '0';
    o_frame_data <= make_arp_word(tx_word_index, tx_is_reply, tx_target_mac,
                                  tx_target_ip, i_local_ipv4_addr);
    o_frame_valid_bytes <= "00";
    o_frame_last <= '1' when tx_state = ATX_STREAM and tx_word_index = 6 else '0';
    o_frame_abort <= '0';

    process(axi_aclk)
        variable cache_hit : boolean;
        variable hit_mac : std_logic_vector(47 downto 0);
        variable update_index : integer range -1 to 3;
        variable first_invalid : integer range -1 to 3;
        variable valid_sender : boolean;
        variable local_request : boolean;
        variable local_reply : boolean;
        variable learn_sender : boolean;
        variable pending_match : boolean;
    begin
        if rising_edge(axi_aclk) then
            resolve_rsp_valid_reg <= '0';
            resolve_rsp_failed_reg <= '0';
            request_sent_pulse <= '0';

            if axi_aresetn = '0' then
                cache_valid <= (others => '0');
                cache_ip <= (others => (others => '0'));
                cache_mac <= (others => (others => '0'));
                replacement_index <= 0;
                resolve_state <= R_IDLE;
                pending_ip <= (others => '0');
                retry_timer <= 0;
                request_count <= 0;
                resolver_request_pending <= '0';
                resolve_rsp_mac_reg <= (others => '0');
                reply_pending <= '0';
                reply_mac <= (others => '0');
                reply_ip <= (others => '0');
                tx_state <= ATX_IDLE;
                tx_is_reply <= '0';
                tx_dest_mac <= (others => '0');
                tx_target_mac <= (others => '0');
                tx_target_ip <= (others => '0');
                tx_word_index <= 0;
            else
                case resolve_state is
                    when R_IDLE =>
                        retry_timer <= 0;
                        request_count <= 0;
                        if i_resolve_req_valid = '1' then
                            pending_ip <= i_resolve_ip;
                            resolve_state <= R_LOOKUP;
                        end if;

                    when R_LOOKUP =>
                        cache_hit := false;
                        hit_mac := (others => '0');
                        for index in 0 to 3 loop
                            if cache_valid(index) = '1' and cache_ip(index) = pending_ip then
                                cache_hit := true;
                                hit_mac := cache_mac(index);
                            end if;
                        end loop;
                        if cache_hit then
                            resolve_rsp_mac_reg <= hit_mac;
                            resolve_rsp_valid_reg <= '1';
                            resolve_state <= R_IDLE;
                        else
                            resolver_request_pending <= '1';
                            request_count <= 0;
                            resolve_state <= R_WAIT_REQUEST_SENT;
                        end if;

                    when R_WAIT_REQUEST_SENT =>
                        if request_sent_pulse = '1' then
                            if request_count < G_MAX_REQUESTS then
                                request_count <= request_count + 1;
                            end if;
                            retry_timer <= 0;
                            resolve_state <= R_WAIT_REPLY;
                        end if;

                    when R_WAIT_REPLY =>
                        if retry_timer = G_RETRY_INTERVAL_CYCLES - 1 then
                            retry_timer <= 0;
                            if request_count >= G_MAX_REQUESTS then
                                resolve_rsp_valid_reg <= '1';
                                resolve_rsp_failed_reg <= '1';
                                resolve_rsp_mac_reg <= (others => '0');
                                resolve_state <= R_IDLE;
                            else
                                resolver_request_pending <= '1';
                                resolve_state <= R_WAIT_REQUEST_SENT;
                            end if;
                        else
                            retry_timer <= retry_timer + 1;
                        end if;
                end case;

                -- Frame producer.  A pending reply has priority whenever a new
                -- frame is selected; an already granted frame is never preempted.
                case tx_state is
                    when ATX_IDLE =>
                        if reply_pending = '1' then
                            tx_is_reply <= '1';
                            tx_dest_mac <= reply_mac;
                            tx_target_mac <= reply_mac;
                            tx_target_ip <= reply_ip;
                            tx_state <= ATX_FRAME_REQUEST;
                        elsif i_arp_event_valid = '1' and i_arp_event_opcode = x"0001" and
                              i_arp_event_target_ip = i_local_ipv4_addr and
                              i_arp_event_sender_ip /= x"00000000" and
                              i_arp_event_sender_mac /= x"000000000000" then
                            tx_is_reply <= '1';
                            tx_dest_mac <= i_arp_event_sender_mac;
                            tx_target_mac <= i_arp_event_sender_mac;
                            tx_target_ip <= i_arp_event_sender_ip;
                            tx_state <= ATX_FRAME_REQUEST;
                        elsif resolver_request_pending = '1' then
                            tx_is_reply <= '0';
                            tx_dest_mac <= x"FFFFFFFFFFFF";
                            tx_target_mac <= x"000000000000";
                            tx_target_ip <= pending_ip;
                            tx_state <= ATX_FRAME_REQUEST;
                        end if;

                    when ATX_FRAME_REQUEST =>
                        if i_frame_req_ready = '1' then
                            tx_word_index <= 0;
                            tx_state <= ATX_STREAM;
                        end if;

                    when ATX_STREAM =>
                        if i_frame_data_ready = '1' then
                            if tx_word_index = 6 then
                                if tx_is_reply = '1' then
                                    reply_pending <= '0';
                                else
                                    resolver_request_pending <= '0';
                                    request_sent_pulse <= '1';
                                end if;
                                tx_state <= ATX_IDLE;
                            else
                                tx_word_index <= tx_word_index + 1;
                            end if;
                        end if;
                end case;

                if i_network_config_changed = '1' then
                    cache_valid <= (others => '0');
                    resolver_request_pending <= '0';
                    if resolve_state /= R_IDLE then
                        resolve_rsp_valid_reg <= '1';
                        resolve_rsp_failed_reg <= '1';
                        resolve_rsp_mac_reg <= (others => '0');
                        resolve_state <= R_IDLE;
                    end if;
                elsif i_arp_event_valid = '1' then
                    valid_sender := i_arp_event_sender_ip /= x"00000000" and
                                    i_arp_event_sender_mac /= x"000000000000";
                    -- A requester does not know our MAC yet, so its ARP target
                    -- MAC is intentionally ignored.  A reply must identify us
                    -- consistently by both protocol and hardware address.
                    local_request := i_arp_event_opcode = x"0001" and
                                     i_arp_event_target_ip = i_local_ipv4_addr;
                    local_reply := i_arp_event_opcode = x"0002" and
                                   i_arp_event_target_ip = i_local_ipv4_addr and
                                   i_arp_event_target_mac = G_LOCAL_MAC;
                    pending_match := resolve_state /= R_IDLE and
                                     i_arp_event_sender_ip = pending_ip and
                                     valid_sender and
                                     (local_request or local_reply);
                    learn_sender := valid_sender and
                                    (local_request or local_reply);

                    if learn_sender then
                        update_index := -1;
                        first_invalid := -1;
                        for index in 0 to 3 loop
                            if cache_valid(index) = '1' and cache_ip(index) = i_arp_event_sender_ip then
                                update_index := index;
                            elsif cache_valid(index) = '0' and first_invalid = -1 then
                                first_invalid := index;
                            end if;
                        end loop;
                        if update_index = -1 then
                            if first_invalid /= -1 then
                                update_index := first_invalid;
                            else
                                update_index := replacement_index;
                                if replacement_index = 3 then
                                    replacement_index <= 0;
                                else
                                    replacement_index <= replacement_index + 1;
                                end if;
                            end if;
                        end if;
                        cache_valid(update_index) <= '1';
                        cache_ip(update_index) <= i_arp_event_sender_ip;
                        cache_mac(update_index) <= i_arp_event_sender_mac;
                    end if;

                    if i_arp_event_opcode = x"0001" and
                       i_arp_event_target_ip = i_local_ipv4_addr and
                       i_arp_event_sender_ip /= x"00000000" and
                       i_arp_event_sender_mac /= x"000000000000" and
                       reply_pending = '0' and tx_state /= ATX_IDLE then
                        reply_pending <= '1';
                        reply_mac <= i_arp_event_sender_mac;
                        reply_ip <= i_arp_event_sender_ip;
                    end if;

                    if pending_match then
                        resolve_rsp_valid_reg <= '1';
                        resolve_rsp_failed_reg <= '0';
                        resolve_rsp_mac_reg <= i_arp_event_sender_mac;
                        resolver_request_pending <= '0';
                        resolve_state <= R_IDLE;
                    end if;
                end if;
            end if;
        end if;
    end process;
end architecture;
