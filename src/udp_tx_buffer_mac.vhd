library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

use work.udp_engine_pkg.all;

-- Two complete frame banks decouple AXI/protocol work from the RMII clock.
-- A bank is invisible to the MAC until its final word is accepted.  Aborting a
-- fill therefore requires no FIFO rewind and can never expose a partial frame.
entity udp_tx_buffer_mac is
    generic (
        G_LOCAL_MAC : std_logic_vector(47 downto 0) := x"001122334455"
    );
    port (
        axi_aclk    : in std_logic;
        axi_aresetn : in std_logic;
        i_ref_clk   : in std_logic;
        i_rmii_resetn : in std_logic;

        i_frame_req_valid : in  std_logic;
        o_frame_req_ready : out std_logic;
        i_frame_dest_mac  : in std_logic_vector(47 downto 0);
        i_frame_ethertype : in std_logic_vector(15 downto 0);
        i_frame_length    : in std_logic_vector(15 downto 0);
        i_frame_data_valid : in std_logic;
        o_frame_data_ready : out std_logic;
        i_frame_data : in std_logic_vector(31 downto 0);
        i_frame_valid_bytes : in std_logic_vector(1 downto 0);
        i_frame_last : in std_logic;
        i_frame_abort : in std_logic;

        o_tx_en : out std_logic;
        o_txd   : out std_logic_vector(1 downto 0);
        o_debug_mac_state : out std_logic_vector(3 downto 0)
    );
end entity;

architecture rtl of udp_tx_buffer_mac is
    constant C_BANK_WORDS : natural := 512;
    constant C_IFG_CYCLES : natural := 48;
    type t_mac_state is (M_IFG, M_WAIT_FRAME, M_PREAMBLE, M_DEST, M_SOURCE,
                         M_TYPE, M_DATA, M_PADDING, M_FCS);

    signal bank_write_address : std_logic_vector(8 downto 0);
    signal bank_read_address : std_logic_vector(8 downto 0);
    signal bank_write_data : std_logic_vector(34 downto 0);
    signal bank0_write_enable, bank1_write_enable : std_logic;
    signal bank0_read_data, bank1_read_data : std_logic_vector(34 downto 0);
    signal bank0_dest, bank1_dest : std_logic_vector(47 downto 0);
    signal bank0_type, bank1_type : std_logic_vector(15 downto 0);
    signal bank0_length, bank1_length : std_logic_vector(15 downto 0);
    signal bank_busy : std_logic_vector(1 downto 0);
    signal fill_active, fill_bank, allocation_bank : std_logic;
    signal fill_address : natural range 0 to C_BANK_WORDS - 1;
    signal fill_byte_count : natural range 0 to C_MAX_IPV4_BYTES;
    signal fill_expected_length : natural range 0 to C_MAX_IPV4_BYTES;
    signal ready_toggle : std_logic_vector(1 downto 0);
    signal done_toggle : std_logic_vector(1 downto 0);
    signal done_sync1, done_sync2, done_seen : std_logic_vector(1 downto 0);

    signal ready_sync1, ready_sync2, ready_seen : std_logic_vector(1 downto 0);
    signal mac_state : t_mac_state;
    signal expected_bank, active_bank : std_logic;
    signal active_dest : std_logic_vector(47 downto 0);
    signal active_type : std_logic_vector(15 downto 0);
    signal read_address : natural range 0 to C_BANK_WORDS - 1;
    signal read_data : std_logic_vector(34 downto 0);
    signal current_word : std_logic_vector(34 downto 0);
    signal tx_byte : std_logic_vector(7 downto 0);
    signal phase : natural range 0 to 3;
    signal byte_index : natural range 0 to 7;
    signal word_byte_index : natural range 0 to 3;
    signal payload_byte_count : natural range 0 to C_MAX_IPV4_BYTES;
    signal ifg_count : natural range 0 to C_IFG_CYCLES - 1;
    signal crc_reg, fcs_reg : std_logic_vector(31 downto 0);

    function mac_byte(mac : std_logic_vector(47 downto 0); index : natural)
        return std_logic_vector is
    begin
        return mac(47 - index * 8 downto 40 - index * 8);
    end function;

    function word_byte(word_value : std_logic_vector(34 downto 0); index : natural)
        return std_logic_vector is
    begin
        return word_value((index * 8) + 7 downto index * 8);
    end function;

    function fcs_byte(fcs : std_logic_vector(31 downto 0); index : natural)
        return std_logic_vector is
    begin
        return fcs((index * 8) + 7 downto index * 8);
    end function;

    function bit_index(value : std_logic) return natural is
    begin
        if value = '1' then return 1; else return 0; end if;
    end function;
begin
    -- M_IFG=0, M_WAIT_FRAME=1, M_PREAMBLE=2, M_DEST=3, M_SOURCE=4,
    -- M_TYPE=5, M_DATA=6, M_PADDING=7, M_FCS=8.
    o_debug_mac_state <= std_logic_vector(
        to_unsigned(t_mac_state'pos(mac_state), o_debug_mac_state'length));

    bank_write_address <= std_logic_vector(to_unsigned(fill_address, 9));
    bank_read_address <= std_logic_vector(to_unsigned(read_address, 9));
    bank_write_data <= i_frame_last & i_frame_valid_bytes & i_frame_data;
    bank0_write_enable <= '1' when fill_active = '1' and fill_bank = '0' and
                                  i_frame_data_valid = '1' and i_frame_abort = '0' else '0';
    bank1_write_enable <= '1' when fill_active = '1' and fill_bank = '1' and
                                  i_frame_data_valid = '1' and i_frame_abort = '0' else '0';
    read_data <= bank0_read_data when active_bank = '0' else bank1_read_data;

    o_frame_req_ready <= '1' when fill_active = '0' and
        ((allocation_bank = '0' and bank_busy(0) = '0') or
         (allocation_bank = '1' and bank_busy(1) = '0')) else '0';
    o_frame_data_ready <= fill_active;

    o_tx_en <= '1' when mac_state = M_PREAMBLE or mac_state = M_DEST or
                            mac_state = M_SOURCE or mac_state = M_TYPE or
                            mac_state = M_DATA or mac_state = M_PADDING or
                            mac_state = M_FCS else '0';
    with phase select o_txd <=
        tx_byte(1 downto 0) when 0,
        tx_byte(3 downto 2) when 1,
        tx_byte(5 downto 4) when 2,
        tx_byte(7 downto 6) when others;

    -- AXI-domain bank allocator and writer.
    process(axi_aclk)
        variable accepted_bytes : natural range 1 to 4;
        variable new_total : natural;
    begin
        if rising_edge(axi_aclk) then
            done_sync1 <= done_toggle;
            done_sync2 <= done_sync1;

            if axi_aresetn = '0' then
                bank_busy <= (others => '0');
                fill_active <= '0';
                fill_bank <= '0';
                allocation_bank <= '0';
                fill_address <= 0;
                fill_byte_count <= 0;
                fill_expected_length <= 0;
                ready_toggle <= (others => '0');
                done_sync1 <= (others => '0');
                done_sync2 <= (others => '0');
                done_seen <= (others => '0');
                bank0_dest <= (others => '0');
                bank1_dest <= (others => '0');
                bank0_type <= (others => '0');
                bank1_type <= (others => '0');
                bank0_length <= (others => '0');
                bank1_length <= (others => '0');
            else
                for index in 0 to 1 loop
                    if done_sync2(index) /= done_seen(index) then
                        done_seen(index) <= done_sync2(index);
                        bank_busy(index) <= '0';
                    end if;
                end loop;

                if fill_active = '0' then
                    if i_frame_req_valid = '1' and o_frame_req_ready = '1' then
                        if to_integer(unsigned(i_frame_length)) <= C_MAX_IPV4_BYTES then
                            fill_active <= '1';
                            fill_bank <= allocation_bank;
                            bank_busy(bit_index(allocation_bank)) <= '1';
                            fill_address <= 0;
                            fill_byte_count <= 0;
                            fill_expected_length <= to_integer(unsigned(i_frame_length));
                            if allocation_bank = '0' then
                                bank0_dest <= i_frame_dest_mac;
                                bank0_type <= i_frame_ethertype;
                                bank0_length <= i_frame_length;
                            else
                                bank1_dest <= i_frame_dest_mac;
                                bank1_type <= i_frame_ethertype;
                                bank1_length <= i_frame_length;
                            end if;
                        end if;
                    end if;
                elsif i_frame_abort = '1' then
                    fill_active <= '0';
                    bank_busy(bit_index(fill_bank)) <= '0';
                    fill_address <= 0;
                    fill_byte_count <= 0;
                elsif i_frame_data_valid = '1' then
                    if i_frame_last = '1' then
                        accepted_bytes := valid_bytes_count(i_frame_valid_bytes);
                    else
                        accepted_bytes := 4;
                    end if;
                    new_total := fill_byte_count + accepted_bytes;
                    if i_frame_last = '1' then
                        fill_active <= '0';
                        fill_address <= 0;
                        fill_byte_count <= 0;
                        if new_total = fill_expected_length then
                            ready_toggle(bit_index(fill_bank)) <=
                                not ready_toggle(bit_index(fill_bank));
                            allocation_bank <= not allocation_bank;
                        else
                            bank_busy(bit_index(fill_bank)) <= '0';
                        end if;
                    elsif fill_address = C_BANK_WORDS - 1 or new_total >= fill_expected_length then
                        -- Producer contract violation: discard without publishing.
                        fill_active <= '0';
                        bank_busy(bit_index(fill_bank)) <= '0';
                    else
                        fill_address <= fill_address + 1;
                        fill_byte_count <= new_total;
                    end if;
                end if;
            end if;
        end if;
    end process;

    bank0_ram : xpm_memory_sdpram
        generic map (
            MEMORY_SIZE => C_BANK_WORDS * 35,
            MEMORY_PRIMITIVE => "block",
            CLOCKING_MODE => "independent_clock",
            ECC_MODE => "no_ecc",
            MEMORY_INIT_FILE => "none",
            USE_MEM_INIT => 0,
            WRITE_DATA_WIDTH_A => 35,
            BYTE_WRITE_WIDTH_A => 35,
            ADDR_WIDTH_A => 9,
            RST_MODE_A => "SYNC",
            READ_DATA_WIDTH_B => 35,
            ADDR_WIDTH_B => 9,
            READ_RESET_VALUE_B => "0",
            READ_LATENCY_B => 1,
            WRITE_MODE_B => "no_change",
            RST_MODE_B => "SYNC"
        )
        port map (
            sleep => '0', clka => axi_aclk, ena => bank0_write_enable,
            wea(0) => bank0_write_enable, addra => bank_write_address,
            dina => bank_write_data, injectsbiterra => '0', injectdbiterra => '0',
            clkb => i_ref_clk, rstb => not i_rmii_resetn, enb => '1', regceb => '1',
            addrb => bank_read_address, doutb => bank0_read_data,
            sbiterrb => open, dbiterrb => open
        );

    bank1_ram : xpm_memory_sdpram
        generic map (
            MEMORY_SIZE => C_BANK_WORDS * 35,
            MEMORY_PRIMITIVE => "block",
            CLOCKING_MODE => "independent_clock",
            ECC_MODE => "no_ecc",
            MEMORY_INIT_FILE => "none",
            USE_MEM_INIT => 0,
            WRITE_DATA_WIDTH_A => 35,
            BYTE_WRITE_WIDTH_A => 35,
            ADDR_WIDTH_A => 9,
            RST_MODE_A => "SYNC",
            READ_DATA_WIDTH_B => 35,
            ADDR_WIDTH_B => 9,
            READ_RESET_VALUE_B => "0",
            READ_LATENCY_B => 1,
            WRITE_MODE_B => "no_change",
            RST_MODE_B => "SYNC"
        )
        port map (
            sleep => '0', clka => axi_aclk, ena => bank1_write_enable,
            wea(0) => bank1_write_enable, addra => bank_write_address,
            dina => bank_write_data, injectsbiterra => '0', injectdbiterra => '0',
            clkb => i_ref_clk, rstb => not i_rmii_resetn, enb => '1', regceb => '1',
            addrb => bank_read_address, doutb => bank1_read_data,
            sbiterrb => open, dbiterrb => open
        );

    process(i_ref_clk)
        variable updated_crc : std_logic_vector(31 downto 0);
        variable updated_payload_count : natural;
        variable current_valid_bytes : natural;
    begin
        if rising_edge(i_ref_clk) then
            ready_sync1 <= ready_toggle;
            ready_sync2 <= ready_sync1;

            if i_rmii_resetn = '0' then
                ready_sync1 <= (others => '0');
                ready_sync2 <= (others => '0');
                ready_seen <= (others => '0');
                done_toggle <= (others => '0');
                mac_state <= M_IFG;
                expected_bank <= '0';
                active_bank <= '0';
                active_dest <= (others => '0');
                active_type <= (others => '0');
                read_address <= 0;
                current_word <= (others => '0');
                tx_byte <= (others => '0');
                phase <= 0;
                byte_index <= 0;
                word_byte_index <= 0;
                payload_byte_count <= 0;
                ifg_count <= 0;
                crc_reg <= x"FFFFFFFF";
                fcs_reg <= (others => '0');
            else
                case mac_state is
                    when M_IFG =>
                        phase <= 0;
                        if ifg_count = C_IFG_CYCLES - 1 then
                            ifg_count <= 0;
                            mac_state <= M_WAIT_FRAME;
                        else
                            ifg_count <= ifg_count + 1;
                        end if;

                    when M_WAIT_FRAME =>
                        phase <= 0;
                        if (expected_bank = '0' and ready_sync2(0) /= ready_seen(0)) or
                           (expected_bank = '1' and ready_sync2(1) /= ready_seen(1)) then
                            active_bank <= expected_bank;
                            if expected_bank = '0' then
                                ready_seen(0) <= ready_sync2(0);
                                active_dest <= bank0_dest;
                                active_type <= bank0_type;
                            else
                                ready_seen(1) <= ready_sync2(1);
                                active_dest <= bank1_dest;
                                active_type <= bank1_type;
                            end if;
                            read_address <= 0;
                            tx_byte <= x"55";
                            byte_index <= 0;
                            payload_byte_count <= 0;
                            crc_reg <= x"FFFFFFFF";
                            mac_state <= M_PREAMBLE;
                        end if;

                    when M_PREAMBLE =>
                        if phase = 3 then
                            phase <= 0;
                            if byte_index = 6 then
                                byte_index <= 7;
                                tx_byte <= x"D5";
                            elsif byte_index = 7 then
                                byte_index <= 0;
                                tx_byte <= mac_byte(active_dest, 0);
                                mac_state <= M_DEST;
                            else
                                byte_index <= byte_index + 1;
                                tx_byte <= x"55";
                            end if;
                        else
                            phase <= phase + 1;
                        end if;

                    when M_DEST =>
                        if phase = 3 then
                            phase <= 0;
                            crc_reg <= crc32_update(crc_reg, tx_byte);
                            if byte_index = 5 then
                                byte_index <= 0;
                                tx_byte <= mac_byte(G_LOCAL_MAC, 0);
                                mac_state <= M_SOURCE;
                            else
                                byte_index <= byte_index + 1;
                                tx_byte <= mac_byte(active_dest, byte_index + 1);
                            end if;
                        else phase <= phase + 1; end if;

                    when M_SOURCE =>
                        if phase = 3 then
                            phase <= 0;
                            crc_reg <= crc32_update(crc_reg, tx_byte);
                            if byte_index = 5 then
                                byte_index <= 0;
                                tx_byte <= active_type(15 downto 8);
                                mac_state <= M_TYPE;
                            else
                                byte_index <= byte_index + 1;
                                tx_byte <= mac_byte(G_LOCAL_MAC, byte_index + 1);
                            end if;
                        else phase <= phase + 1; end if;

                    when M_TYPE =>
                        if phase = 3 then
                            phase <= 0;
                            crc_reg <= crc32_update(crc_reg, tx_byte);
                            if byte_index = 0 then
                                byte_index <= 1;
                                tx_byte <= active_type(7 downto 0);
                            else
                                current_word <= read_data;
                                read_address <= 1;
                                word_byte_index <= 0;
                                tx_byte <= word_byte(read_data, 0);
                                mac_state <= M_DATA;
                            end if;
                        else phase <= phase + 1; end if;

                    when M_DATA =>
                        if phase = 3 then
                            phase <= 0;
                            updated_crc := crc32_update(crc_reg, tx_byte);
                            updated_payload_count := payload_byte_count + 1;
                            crc_reg <= updated_crc;
                            payload_byte_count <= updated_payload_count;
                            current_valid_bytes := valid_bytes_count(current_word(33 downto 32));

                            if word_byte_index = current_valid_bytes - 1 then
                                if current_word(34) = '1' then
                                    if updated_payload_count >= C_ETH_MIN_PAYLOAD_BYTES then
                                        fcs_reg <= not updated_crc;
                                        tx_byte <= fcs_byte(not updated_crc, 0);
                                        byte_index <= 0;
                                        mac_state <= M_FCS;
                                    else
                                        tx_byte <= x"00";
                                        mac_state <= M_PADDING;
                                    end if;
                                else
                                    current_word <= read_data;
                                    if read_address < C_BANK_WORDS - 1 then
                                        read_address <= read_address + 1;
                                    end if;
                                    word_byte_index <= 0;
                                    tx_byte <= word_byte(read_data, 0);
                                end if;
                            else
                                word_byte_index <= word_byte_index + 1;
                                tx_byte <= word_byte(current_word, word_byte_index + 1);
                            end if;
                        else phase <= phase + 1; end if;

                    when M_PADDING =>
                        if phase = 3 then
                            phase <= 0;
                            updated_crc := crc32_update(crc_reg, x"00");
                            updated_payload_count := payload_byte_count + 1;
                            crc_reg <= updated_crc;
                            payload_byte_count <= updated_payload_count;
                            if updated_payload_count >= C_ETH_MIN_PAYLOAD_BYTES then
                                fcs_reg <= not updated_crc;
                                tx_byte <= fcs_byte(not updated_crc, 0);
                                byte_index <= 0;
                                mac_state <= M_FCS;
                            else
                                tx_byte <= x"00";
                            end if;
                        else phase <= phase + 1; end if;

                    when M_FCS =>
                        if phase = 3 then
                            phase <= 0;
                            if byte_index = 3 then
                                done_toggle(bit_index(active_bank)) <=
                                    not done_toggle(bit_index(active_bank));
                                expected_bank <= not expected_bank;
                                ifg_count <= 0;
                                mac_state <= M_IFG;
                            else
                                byte_index <= byte_index + 1;
                                tx_byte <= fcs_byte(fcs_reg, byte_index + 1);
                            end if;
                        else phase <= phase + 1; end if;
                end case;
            end if;
        end if;
    end process;
end architecture;
