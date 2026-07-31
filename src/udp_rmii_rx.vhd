library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.udp_engine_pkg.all;

-- RMII receive MAC.  Every byte from destination MAC through the final byte
-- preceding FCS is forwarded.  FCS itself is withheld by the four-byte delay
-- line.  FIFO status encoding is compatible with the original project:
--   00 & byte : frame data
--   10 & 0    : good end-of-frame marker
--   11 & 0    : errored/aborted end-of-frame marker
entity udp_rmii_rx is
    port (
        i_ref_clk : in std_logic;
        i_resetn  : in std_logic;
        i_rxd     : in std_logic_vector(1 downto 0);
        i_rxer    : in std_logic;
        i_crs_dv  : in std_logic;

        i_fifo_almost_full : in std_logic;
        i_fifo_full        : in std_logic;
        o_fifo_write       : out std_logic;
        o_fifo_data        : out std_logic_vector(9 downto 0)
    );
end entity;

architecture rtl of udp_rmii_rx is
    type t_state is (S_SEARCH_SFD, S_FRAME, S_DROP_FRAME, S_ABORT_WAIT);
    type t_delay is array (0 to 3) of std_logic_vector(7 downto 0);

    signal state : t_state;
    signal shift_reg : std_logic_vector(7 downto 0);
    signal dibit_count : unsigned(1 downto 0);
    signal delay_line : t_delay;
    signal delay_count : natural range 0 to 4;
    signal crc_reg : std_logic_vector(31 downto 0);
    signal frame_error : std_logic;
    signal abort_pending : std_logic;
    signal fifo_write_reg : std_logic;
    signal fifo_data_reg : std_logic_vector(9 downto 0);
begin
    o_fifo_write <= fifo_write_reg;
    o_fifo_data <= fifo_data_reg;

    process(i_ref_clk)
        variable assembled_byte : std_logic_vector(7 downto 0);
        variable received_fcs : std_logic_vector(31 downto 0);
    begin
        if rising_edge(i_ref_clk) then
            fifo_write_reg <= '0';

            if i_resetn = '0' then
                state <= S_SEARCH_SFD;
                shift_reg <= (others => '0');
                dibit_count <= (others => '0');
                delay_line <= (others => (others => '0'));
                delay_count <= 0;
                crc_reg <= x"FFFFFFFF";
                frame_error <= '0';
                abort_pending <= '0';
                fifo_data_reg <= (others => '0');
            else
                case state is
                    when S_SEARCH_SFD =>
                        dibit_count <= (others => '0');
                        delay_count <= 0;
                        frame_error <= '0';

                        if abort_pending = '1' then
                            state <= S_ABORT_WAIT;
                        elsif i_crs_dv = '1' then
                            assembled_byte := i_rxd & shift_reg(7 downto 2);
                            shift_reg <= assembled_byte;
                            if assembled_byte = x"D5" then
                                state <= S_FRAME;
                                shift_reg <= (others => '0');
                                dibit_count <= (others => '0');
                                delay_line <= (others => (others => '0'));
                                delay_count <= 0;
                                crc_reg <= x"FFFFFFFF";
                                frame_error <= i_rxer;
                            end if;
                        end if;

                    when S_FRAME =>
                        if i_rxer = '1' then
                            frame_error <= '1';
                        end if;

                        if i_crs_dv = '1' then
                            assembled_byte := i_rxd & shift_reg(7 downto 2);
                            shift_reg <= assembled_byte;

                            if dibit_count = 3 then
                                dibit_count <= (others => '0');

                                delay_line(0) <= delay_line(1);
                                delay_line(1) <= delay_line(2);
                                delay_line(2) <= delay_line(3);
                                delay_line(3) <= assembled_byte;

                                if delay_count < 4 then
                                    delay_count <= delay_count + 1;
                                else
                                    if i_fifo_almost_full = '1' then
                                        frame_error <= '1';
                                        if i_fifo_full = '0' then
                                            fifo_write_reg <= '1';
                                            fifo_data_reg <= "11" & x"00";
                                            abort_pending <= '0';
                                        else
                                            abort_pending <= '1';
                                        end if;
                                        state <= S_DROP_FRAME;
                                    else
                                        fifo_write_reg <= '1';
                                        fifo_data_reg <= "00" & delay_line(0);
                                        crc_reg <= crc32_update(crc_reg, delay_line(0));
                                    end if;
                                end if;
                            else
                                dibit_count <= dibit_count + 1;
                            end if;
                        else
                            received_fcs := delay_line(3) & delay_line(2) &
                                            delay_line(1) & delay_line(0);
                            if i_fifo_full = '0' then
                                fifo_write_reg <= '1';
                                if delay_count = 4 and dibit_count = 0 and
                                   frame_error = '0' and received_fcs = not crc_reg then
                                    fifo_data_reg <= "10" & x"00";
                                else
                                    fifo_data_reg <= "11" & x"00";
                                end if;
                                abort_pending <= '0';
                                state <= S_SEARCH_SFD;
                            else
                                abort_pending <= '1';
                                state <= S_ABORT_WAIT;
                            end if;
                        end if;

                    when S_DROP_FRAME =>
                        if abort_pending = '1' then
                            if i_fifo_full = '0' then
                                fifo_write_reg <= '1';
                                fifo_data_reg <= "11" & x"00";
                                abort_pending <= '0';
                                if i_crs_dv = '0' then
                                    state <= S_SEARCH_SFD;
                                end if;
                            elsif i_crs_dv = '0' then
                                state <= S_ABORT_WAIT;
                            end if;
                        elsif i_crs_dv = '0' then
                            state <= S_SEARCH_SFD;
                        end if;

                    when S_ABORT_WAIT =>
                        -- Do not admit another frame until the marker separating
                        -- the truncated prefix has actually entered the FIFO.
                        if i_fifo_full = '0' then
                            fifo_write_reg <= '1';
                            fifo_data_reg <= "11" & x"00";
                            abort_pending <= '0';
                            if i_crs_dv = '0' then
                                state <= S_SEARCH_SFD;
                            else
                                state <= S_DROP_FRAME;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture;
