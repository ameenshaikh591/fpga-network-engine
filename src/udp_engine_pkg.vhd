library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package udp_engine_pkg is
    constant C_AXI_ADDR_WIDTH : positive := 32;
    constant C_AXI_DATA_WIDTH : positive := 32;

    constant C_ETH_HEADER_BYTES : natural := 14;
    constant C_ETH_MIN_PAYLOAD_BYTES : natural := 46;
    constant C_IPV4_HEADER_BYTES : natural := 20;
    constant C_UDP_HEADER_BYTES : natural := 8;
    constant C_ARP_PAYLOAD_BYTES : natural := 28;
    constant C_MAX_IPV4_BYTES : natural := 1500;
    constant C_MAX_UDP_PAYLOAD_BYTES : natural := 1472;

    constant C_ETHERTYPE_IPV4 : std_logic_vector(15 downto 0) := x"0800";
    constant C_ETHERTYPE_ARP  : std_logic_vector(15 downto 0) := x"0806";
    constant C_IP_PROTOCOL_UDP : std_logic_vector(7 downto 0) := x"11";

    constant C_DMA_ENTRY_BYTES : natural := 1500;
    constant C_DMA_METADATA_BYTES : natural := 16;
    constant C_RX0_BASE_OFFSET : natural := 0;
    constant C_RX1_BASE_OFFSET : natural := 4500;
    constant C_TX_BASE_OFFSET  : natural := 9000;
    constant C_DMA_REGION_BYTES : natural := 15000;

    constant C_REG_DMA_BASE_ADDR    : natural := 16#00#;
    constant C_REG_RX0_CONFIG       : natural := 16#04#;
    constant C_REG_RX0_HEAD         : natural := 16#08#;
    constant C_REG_RX0_TAIL         : natural := 16#0C#;
    constant C_REG_RX1_CONFIG       : natural := 16#10#;
    constant C_REG_RX1_HEAD         : natural := 16#14#;
    constant C_REG_RX1_TAIL         : natural := 16#18#;
    constant C_REG_TX_HEAD          : natural := 16#1C#;
    constant C_REG_TX_TAIL          : natural := 16#20#;
    constant C_REG_LOCAL_IPV4       : natural := 16#24#;
    constant C_REG_SUBNET_MASK      : natural := 16#28#;
    constant C_REG_DEFAULT_GATEWAY  : natural := 16#2C#;

    -- A pointer is wrap & index[1:0]
    -- Bits above bit 2 are always zero in software-visible registers
    subtype t_queue_ptr is std_logic_vector(2 downto 0);

    type t_byte_array is array (natural range <>) of std_logic_vector(7 downto 0);
    type t_word_array is array (natural range <>) of std_logic_vector(31 downto 0);

    function rx_ptr_valid(ptr : t_queue_ptr) return boolean;
    function rx_ptr_advance(ptr : t_queue_ptr) return t_queue_ptr;
    function tx_ptr_advance(ptr : t_queue_ptr) return t_queue_ptr;
    function queue_full(head : t_queue_ptr; tail : t_queue_ptr) return boolean;

    function entry_offset(index : std_logic_vector(1 downto 0)) return unsigned;
    function rx_entry_address(
        dma_base : std_logic_vector(31 downto 0);
        socket_index : std_logic;
        entry_index : std_logic_vector(1 downto 0)
    ) return std_logic_vector;
    function tx_entry_address(
        dma_base : std_logic_vector(31 downto 0);
        entry_index : std_logic_vector(1 downto 0)
    ) return std_logic_vector;

    -- Stream words are byte-lane ordered: the first byte on the wire is in
    -- data(7 downto 0), then data(15 downto 8), and so on.
    function pack4(
        b0 : std_logic_vector(7 downto 0);
        b1 : std_logic_vector(7 downto 0);
        b2 : std_logic_vector(7 downto 0);
        b3 : std_logic_vector(7 downto 0)
    ) return std_logic_vector;
    function valid_bytes_encoding(byte_count : natural) return std_logic_vector;
    function valid_bytes_count(encoding : std_logic_vector(1 downto 0)) return natural;

    function crc32_update(
        crc_in : std_logic_vector(31 downto 0);
        data_byte : std_logic_vector(7 downto 0)
    ) return std_logic_vector;
end package;

package body udp_engine_pkg is
    function rx_ptr_valid(ptr : t_queue_ptr) return boolean is
    begin
        return ptr(1 downto 0) /= "11";
    end function;

    function rx_ptr_advance(ptr : t_queue_ptr) return t_queue_ptr is
        variable result : t_queue_ptr := ptr;
    begin
        if ptr(1 downto 0) = "10" then
            result(2) := not ptr(2);
            result(1 downto 0) := "00";
        else
            result(1 downto 0) := std_logic_vector(unsigned(ptr(1 downto 0)) + 1);
        end if;
        return result;
    end function;

    function tx_ptr_advance(ptr : t_queue_ptr) return t_queue_ptr is
    begin
        return std_logic_vector(unsigned(ptr) + 1);
    end function;

    function queue_full(head : t_queue_ptr; tail : t_queue_ptr) return boolean is
    begin
        return head(1 downto 0) = tail(1 downto 0) and head(2) /= tail(2);
    end function;

    function entry_offset(index : std_logic_vector(1 downto 0)) return unsigned is
    begin
        case index is
            when "00" => return to_unsigned(0, 32);
            when "01" => return to_unsigned(1500, 32);
            when "10" => return to_unsigned(3000, 32);
            when others => return to_unsigned(4500, 32);
        end case;
    end function;

    function rx_entry_address(
        dma_base : std_logic_vector(31 downto 0);
        socket_index : std_logic;
        entry_index : std_logic_vector(1 downto 0)
    ) return std_logic_vector is
        variable base_offset : unsigned(31 downto 0);
    begin
        if socket_index = '0' then
            base_offset := to_unsigned(C_RX0_BASE_OFFSET, 32);
        else
            base_offset := to_unsigned(C_RX1_BASE_OFFSET, 32);
        end if;
        return std_logic_vector(unsigned(dma_base) + base_offset + entry_offset(entry_index));
    end function;

    function tx_entry_address(
        dma_base : std_logic_vector(31 downto 0);
        entry_index : std_logic_vector(1 downto 0)
    ) return std_logic_vector is
    begin
        return std_logic_vector(
            unsigned(dma_base) + to_unsigned(C_TX_BASE_OFFSET, 32) + entry_offset(entry_index)
        );
    end function;

    function pack4(
        b0 : std_logic_vector(7 downto 0);
        b1 : std_logic_vector(7 downto 0);
        b2 : std_logic_vector(7 downto 0);
        b3 : std_logic_vector(7 downto 0)
    ) return std_logic_vector is
    begin
        return b3 & b2 & b1 & b0;
    end function;

    function valid_bytes_encoding(byte_count : natural) return std_logic_vector is
    begin
        case byte_count is
            when 1 => return "01";
            when 2 => return "10";
            when 3 => return "11";
            when others => return "00"; -- four valid bytes
        end case;
    end function;

    function valid_bytes_count(encoding : std_logic_vector(1 downto 0)) return natural is
    begin
        case encoding is
            when "01" => return 1;
            when "10" => return 2;
            when "11" => return 3;
            when others => return 4;
        end case;
    end function;

    function crc32_update(
        crc_in : std_logic_vector(31 downto 0);
        data_byte : std_logic_vector(7 downto 0)
    ) return std_logic_vector is
        variable crc : unsigned(31 downto 0);
    begin
        crc := unsigned(crc_in) xor resize(unsigned(data_byte), 32);
        for bit_index in 0 to 7 loop
            if crc(0) = '1' then
                crc := shift_right(crc, 1) xor x"EDB88320";
            else
                crc := shift_right(crc, 1);
            end if;
        end loop;
        return std_logic_vector(crc);
    end function;
end package body;
