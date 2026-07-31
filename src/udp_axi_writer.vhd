library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.udp_engine_pkg.all;

-- Deliberately uses one-beat AXI4 writes.  At 100 MHz this still has ample
-- bandwidth for 100 Mb/s Ethernet, while keeping abort/error completion fully
-- deterministic and making the master compatible with AXI BRAM controllers.
entity udp_axi_writer is
    port (
        axi_aclk    : in std_logic;
        axi_aresetn : in std_logic;

        i_write_req_valid : in  std_logic;
        o_write_req_ready : out std_logic;
        i_write_base_addr : in  std_logic_vector(31 downto 0);
        i_write_metadata  : in  std_logic_vector(127 downto 0);
        i_write_payload_length : in std_logic_vector(15 downto 0);

        i_payload_valid : in  std_logic;
        o_payload_ready : out std_logic;
        i_payload_data  : in  std_logic_vector(7 downto 0);
        i_payload_last  : in  std_logic;
        i_write_abort   : in  std_logic;

        o_write_done    : out std_logic;
        o_write_error   : out std_logic;
        o_write_aborted : out std_logic;

        M_AXI_AWADDR  : out std_logic_vector(31 downto 0);
        M_AXI_AWLEN   : out std_logic_vector(7 downto 0);
        M_AXI_AWSIZE  : out std_logic_vector(2 downto 0);
        M_AXI_AWBURST : out std_logic_vector(1 downto 0);
        M_AXI_AWPROT  : out std_logic_vector(2 downto 0);
        M_AXI_AWVALID : out std_logic;
        M_AXI_AWREADY : in  std_logic;
        M_AXI_WDATA   : out std_logic_vector(31 downto 0);
        M_AXI_WSTRB   : out std_logic_vector(3 downto 0);
        M_AXI_WLAST   : out std_logic;
        M_AXI_WVALID  : out std_logic;
        M_AXI_WREADY  : in  std_logic;
        M_AXI_BRESP   : in  std_logic_vector(1 downto 0);
        M_AXI_BVALID  : in  std_logic;
        M_AXI_BREADY  : out std_logic
    );
end entity;

architecture rtl of udp_axi_writer is
    type t_state is (
        W_IDLE, W_META_AW, W_META_W, W_META_B,
        W_COLLECT, W_PAYLOAD_AW, W_PAYLOAD_W, W_PAYLOAD_B,
        W_DONE, W_ERROR, W_ABORTED
    );
    signal state : t_state;
    signal base_addr_reg : std_logic_vector(31 downto 0);
    signal metadata_reg : std_logic_vector(127 downto 0);
    signal payload_length_reg : natural range 0 to C_MAX_UDP_PAYLOAD_BYTES;
    signal metadata_index : natural range 0 to 3;
    signal payload_received : natural range 0 to C_MAX_UDP_PAYLOAD_BYTES;
    signal pack_word : std_logic_vector(31 downto 0);
    signal pack_count : natural range 0 to 3;
    signal write_word : std_logic_vector(31 downto 0);
    signal write_strobe : std_logic_vector(3 downto 0);
    signal word_address : std_logic_vector(31 downto 0);
    signal final_payload_word : std_logic;
    signal abort_requested : std_logic;
    signal protocol_error : std_logic;

    function strobe_for_count(byte_count : natural) return std_logic_vector is
    begin
        case byte_count is
            when 1 => return "0001";
            when 2 => return "0011";
            when 3 => return "0111";
            when others => return "1111";
        end case;
    end function;
begin
    o_write_req_ready <= '1' when state = W_IDLE else '0';
    o_payload_ready <= '1' when state = W_COLLECT and abort_requested = '0' else '0';
    o_write_done <= '1' when state = W_DONE else '0';
    o_write_error <= '1' when state = W_ERROR else '0';
    o_write_aborted <= '1' when state = W_ABORTED else '0';

    M_AXI_AWLEN <= (others => '0');
    M_AXI_AWSIZE <= "010";
    M_AXI_AWBURST <= "01";
    M_AXI_AWPROT <= "000";
    M_AXI_WLAST <= '1';

    M_AXI_AWVALID <= '1' when state = W_META_AW or state = W_PAYLOAD_AW else '0';
    M_AXI_WVALID <= '1' when state = W_META_W or state = W_PAYLOAD_W else '0';
    M_AXI_BREADY <= '1' when state = W_META_B or state = W_PAYLOAD_B else '0';

    M_AXI_AWADDR <= std_logic_vector(unsigned(base_addr_reg) + to_unsigned(metadata_index * 4, 32))
        when state = W_META_AW else word_address;
    M_AXI_WDATA <= metadata_reg((metadata_index * 32) + 31 downto metadata_index * 32)
        when state = W_META_W else write_word;
    M_AXI_WSTRB <= "1111" when state = W_META_W else write_strobe;

    process(axi_aclk)
        variable next_word : std_logic_vector(31 downto 0);
        variable next_count : natural range 1 to 4;
        variable next_received : natural range 1 to C_MAX_UDP_PAYLOAD_BYTES;
        variable expected_last : boolean;
    begin
        if rising_edge(axi_aclk) then
            if axi_aresetn = '0' then
                state <= W_IDLE;
                base_addr_reg <= (others => '0');
                metadata_reg <= (others => '0');
                payload_length_reg <= 0;
                metadata_index <= 0;
                payload_received <= 0;
                pack_word <= (others => '0');
                pack_count <= 0;
                write_word <= (others => '0');
                write_strobe <= (others => '0');
                word_address <= (others => '0');
                final_payload_word <= '0';
                abort_requested <= '0';
                protocol_error <= '0';
            else
                if i_write_abort = '1' and state /= W_IDLE and
                   state /= W_DONE and state /= W_ERROR and state /= W_ABORTED then
                    abort_requested <= '1';
                end if;

                case state is
                    when W_IDLE =>
                        abort_requested <= '0';
                        protocol_error <= '0';
                        if i_write_req_valid = '1' then
                            base_addr_reg <= i_write_base_addr;
                            metadata_reg <= i_write_metadata;
                            metadata_index <= 0;
                            payload_received <= 0;
                            pack_word <= (others => '0');
                            pack_count <= 0;
                            if to_integer(unsigned(i_write_payload_length)) <= C_MAX_UDP_PAYLOAD_BYTES then
                                payload_length_reg <= to_integer(unsigned(i_write_payload_length));
                                state <= W_META_AW;
                            else
                                state <= W_ERROR;
                            end if;
                        end if;

                    when W_META_AW =>
                        if M_AXI_AWREADY = '1' then
                            state <= W_META_W;
                        end if;

                    when W_META_W =>
                        if M_AXI_WREADY = '1' then
                            state <= W_META_B;
                        end if;

                    when W_META_B =>
                        if M_AXI_BVALID = '1' then
                            if M_AXI_BRESP /= "00" then
                                state <= W_ERROR;
                            elsif abort_requested = '1' or i_write_abort = '1' then
                                state <= W_ABORTED;
                            elsif metadata_index = 3 then
                                if payload_length_reg = 0 then
                                    state <= W_DONE;
                                else
                                    state <= W_COLLECT;
                                end if;
                            else
                                metadata_index <= metadata_index + 1;
                                state <= W_META_AW;
                            end if;
                        end if;

                    when W_COLLECT =>
                        if abort_requested = '1' or i_write_abort = '1' then
                            state <= W_ABORTED;
                        elsif i_payload_valid = '1' then
                            next_word := pack_word;
                            case pack_count is
                                when 0 => next_word(7 downto 0) := i_payload_data;
                                when 1 => next_word(15 downto 8) := i_payload_data;
                                when 2 => next_word(23 downto 16) := i_payload_data;
                                when others => next_word(31 downto 24) := i_payload_data;
                            end case;

                            next_count := pack_count + 1;
                            next_received := payload_received + 1;
                            expected_last := next_received = payload_length_reg;
                            pack_word <= next_word;
                            payload_received <= next_received;

                            if (i_payload_last = '1') /= expected_last then
                                protocol_error <= '1';
                            end if;

                            if next_count = 4 or i_payload_last = '1' or expected_last then
                                write_word <= next_word;
                                write_strobe <= strobe_for_count(next_count);
                                word_address <= std_logic_vector(
                                    unsigned(base_addr_reg) + C_DMA_METADATA_BYTES +
                                    to_unsigned(payload_received - pack_count, 32)
                                );
                                if expected_last or i_payload_last = '1' then
                                    final_payload_word <= '1';
                                else
                                    final_payload_word <= '0';
                                end if;
                                pack_word <= (others => '0');
                                pack_count <= 0;
                                state <= W_PAYLOAD_AW;
                            else
                                pack_count <= next_count;
                            end if;
                        end if;

                    when W_PAYLOAD_AW =>
                        if M_AXI_AWREADY = '1' then
                            state <= W_PAYLOAD_W;
                        end if;

                    when W_PAYLOAD_W =>
                        if M_AXI_WREADY = '1' then
                            state <= W_PAYLOAD_B;
                        end if;

                    when W_PAYLOAD_B =>
                        if M_AXI_BVALID = '1' then
                            if M_AXI_BRESP /= "00" then
                                state <= W_ERROR;
                            elsif abort_requested = '1' or i_write_abort = '1' then
                                state <= W_ABORTED;
                            elsif final_payload_word = '1' then
                                if protocol_error = '1' then
                                    state <= W_ERROR;
                                else
                                    state <= W_DONE;
                                end if;
                            else
                                state <= W_COLLECT;
                            end if;
                        end if;

                    when W_DONE | W_ERROR | W_ABORTED =>
                        state <= W_IDLE;
                end case;
            end if;
        end if;
    end process;
end architecture;
