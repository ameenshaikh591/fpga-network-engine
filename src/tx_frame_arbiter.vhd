library ieee;
use ieee.std_logic_1164.all;

entity tx_frame_arbiter is
    port (
        clk    : in std_logic;
        resetn : in std_logic;

        i_arp_req_valid : in std_logic;
        o_arp_req_ready : out std_logic;
        i_arp_dest_mac : in std_logic_vector(47 downto 0);
        i_arp_ethertype : in std_logic_vector(15 downto 0);
        i_arp_length : in std_logic_vector(15 downto 0);
        i_arp_data_valid : in std_logic;
        o_arp_data_ready : out std_logic;
        i_arp_data : in std_logic_vector(31 downto 0);
        i_arp_valid_bytes : in std_logic_vector(1 downto 0);
        i_arp_last : in std_logic;
        i_arp_abort : in std_logic;

        i_udp_req_valid : in std_logic;
        o_udp_req_ready : out std_logic;
        i_udp_dest_mac : in std_logic_vector(47 downto 0);
        i_udp_ethertype : in std_logic_vector(15 downto 0);
        i_udp_length : in std_logic_vector(15 downto 0);
        i_udp_data_valid : in std_logic;
        o_udp_data_ready : out std_logic;
        i_udp_data : in std_logic_vector(31 downto 0);
        i_udp_valid_bytes : in std_logic_vector(1 downto 0);
        i_udp_last : in std_logic;
        i_udp_abort : in std_logic;

        o_frame_req_valid : out std_logic;
        i_frame_req_ready : in std_logic;
        o_frame_dest_mac : out std_logic_vector(47 downto 0);
        o_frame_ethertype : out std_logic_vector(15 downto 0);
        o_frame_length : out std_logic_vector(15 downto 0);
        o_frame_data_valid : out std_logic;
        i_frame_data_ready : in std_logic;
        o_frame_data : out std_logic_vector(31 downto 0);
        o_frame_valid_bytes : out std_logic_vector(1 downto 0);
        o_frame_last : out std_logic;
        o_frame_abort : out std_logic
    );
end entity;

architecture rtl of tx_frame_arbiter is
    type t_state is (A_IDLE, A_GRANT_ARP, A_GRANT_UDP);
    signal state : t_state;
begin
    process(all)
    begin
        o_arp_req_ready <= '0';
        o_udp_req_ready <= '0';
        o_arp_data_ready <= '0';
        o_udp_data_ready <= '0';
        o_frame_req_valid <= '0';
        o_frame_dest_mac <= (others => '0');
        o_frame_ethertype <= (others => '0');
        o_frame_length <= (others => '0');
        o_frame_data_valid <= '0';
        o_frame_data <= (others => '0');
        o_frame_valid_bytes <= (others => '0');
        o_frame_last <= '0';
        o_frame_abort <= '0';

        case state is
            when A_IDLE =>
                if i_arp_req_valid = '1' then
                    o_frame_req_valid <= '1';
                    o_frame_dest_mac <= i_arp_dest_mac;
                    o_frame_ethertype <= i_arp_ethertype;
                    o_frame_length <= i_arp_length;
                    o_arp_req_ready <= i_frame_req_ready;
                elsif i_udp_req_valid = '1' then
                    o_frame_req_valid <= '1';
                    o_frame_dest_mac <= i_udp_dest_mac;
                    o_frame_ethertype <= i_udp_ethertype;
                    o_frame_length <= i_udp_length;
                    o_udp_req_ready <= i_frame_req_ready;
                end if;

            when A_GRANT_ARP =>
                o_frame_data_valid <= i_arp_data_valid;
                o_frame_data <= i_arp_data;
                o_frame_valid_bytes <= i_arp_valid_bytes;
                o_frame_last <= i_arp_last;
                o_frame_abort <= i_arp_abort;
                o_arp_data_ready <= i_frame_data_ready;

            when A_GRANT_UDP =>
                o_frame_data_valid <= i_udp_data_valid;
                o_frame_data <= i_udp_data;
                o_frame_valid_bytes <= i_udp_valid_bytes;
                o_frame_last <= i_udp_last;
                o_frame_abort <= i_udp_abort;
                o_udp_data_ready <= i_frame_data_ready;
        end case;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                state <= A_IDLE;
            else
                case state is
                    when A_IDLE =>
                        if i_frame_req_ready = '1' then
                            if i_arp_req_valid = '1' then
                                state <= A_GRANT_ARP;
                            elsif i_udp_req_valid = '1' then
                                state <= A_GRANT_UDP;
                            end if;
                        end if;
                    when A_GRANT_ARP =>
                        if i_arp_abort = '1' or (i_arp_data_valid = '1' and i_frame_data_ready = '1' and i_arp_last = '1') then
                            state <= A_IDLE;
                        end if;
                    when A_GRANT_UDP =>
                        if i_udp_abort = '1' or (i_udp_data_valid = '1' and i_frame_data_ready = '1' and i_udp_last = '1') then
                            state <= A_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture;
