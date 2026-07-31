library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.udp_engine_pkg.all;

entity udp_axi_reader is
    port (
        axi_aclk    : in std_logic;
        axi_aresetn : in std_logic;

        i_read_req_valid : in  std_logic;
        o_read_req_ready : out std_logic;
        i_read_addr      : in  std_logic_vector(31 downto 0);
        i_read_length    : in  std_logic_vector(15 downto 0);

        o_read_data_valid : out std_logic;
        i_read_data_ready : in  std_logic;
        o_read_data       : out std_logic_vector(31 downto 0);
        o_read_valid_bytes : out std_logic_vector(1 downto 0);
        o_read_last       : out std_logic;
        o_read_done       : out std_logic;
        o_read_error      : out std_logic;
        o_debug_state     : out std_logic_vector(2 downto 0);

        M_AXI_ARADDR  : out std_logic_vector(31 downto 0);
        M_AXI_ARLEN   : out std_logic_vector(7 downto 0);
        M_AXI_ARSIZE  : out std_logic_vector(2 downto 0);
        M_AXI_ARBURST : out std_logic_vector(1 downto 0);
        M_AXI_ARPROT  : out std_logic_vector(2 downto 0);
        M_AXI_ARVALID : out std_logic;
        M_AXI_ARREADY : in  std_logic;
        M_AXI_RDATA   : in  std_logic_vector(31 downto 0);
        M_AXI_RRESP   : in  std_logic_vector(1 downto 0);
        M_AXI_RLAST   : in  std_logic;
        M_AXI_RVALID  : in  std_logic;
        M_AXI_RREADY  : out std_logic
    );
end entity;

architecture rtl of udp_axi_reader is
    constant C_AXI_OKAY : std_logic_vector(1 downto 0) := "00";

    type t_state is (R_IDLE, R_AR, R_DATA, R_WAIT_OUTPUT,
                     R_DRAIN, R_DONE, R_ERROR);
    signal state : t_state;

    signal address_reg : std_logic_vector(31 downto 0);
    signal remaining_bytes : natural range 0 to C_MAX_IPV4_BYTES;
    signal burst_beats_reg : natural range 1 to 256;
    signal burst_beat_index : natural range 0 to 255;

    -- Two-entry elastic output buffer.  The output slot is the normal
    -- pipeline register; the skid slot absorbs one additional AXI beat if
    -- the consumer stalls after RREADY has already been asserted.
    signal output_data_reg : std_logic_vector(31 downto 0);
    signal output_valid_bytes_reg : std_logic_vector(1 downto 0);
    signal output_last_reg : std_logic;
    signal output_valid_reg : std_logic;
    signal skid_data_reg : std_logic_vector(31 downto 0);
    signal skid_valid_bytes_reg : std_logic_vector(1 downto 0);
    signal skid_last_reg : std_logic;
    signal skid_valid_reg : std_logic;

    signal elastic_input_ready : std_logic;
    signal elastic_input_valid : std_logic;
    signal elastic_input_valid_bytes : std_logic_vector(1 downto 0);
    signal elastic_input_last : std_logic;
    signal expected_rlast : std_logic;
    signal axi_beat_good : std_logic;
    signal axi_beat_handshake : std_logic;
    signal flush_elastic_buffer : std_logic;
    signal output_last_handshake : std_logic;

    function calculate_burst_beats(
        address    : std_logic_vector(31 downto 0);
        byte_count : natural
    ) return natural is
        variable request_beats : natural;
        variable boundary_beats : natural;
        variable result : natural;
    begin
        request_beats := (byte_count + 3) / 4;
        boundary_beats := (4096 - to_integer(unsigned(address(11 downto 0)))) / 4;

        result := request_beats;
        if result > 256 then
            result := 256;
        end if;
        if result > boundary_beats then
            result := boundary_beats;
        end if;
        return result;
    end function;
begin
    -- R_IDLE=0, R_AR=1, R_DATA=2, R_WAIT_OUTPUT=3,
    -- R_DRAIN=4, R_DONE=5, R_ERROR=6.
    o_debug_state <= std_logic_vector(to_unsigned(t_state'pos(state), o_debug_state'length));

    o_read_req_ready <= '1' when state = R_IDLE else '0';
    o_read_data_valid <= output_valid_reg;
    o_read_data <= output_data_reg;
    o_read_valid_bytes <= output_valid_bytes_reg;
    o_read_last <= output_last_reg;
    o_read_done <= '1' when state = R_DONE else '0';
    o_read_error <= '1' when state = R_ERROR else '0';

    M_AXI_ARADDR <= address_reg;
    M_AXI_ARLEN <= std_logic_vector(to_unsigned(burst_beats_reg - 1, 8));
    M_AXI_ARSIZE <= "010";
    M_AXI_ARBURST <= "01";
    M_AXI_ARPROT <= "000";
    M_AXI_ARVALID <= '1' when state = R_AR else '0';

    -- RREADY depends only on reader-local registered state.  In particular,
    -- it has no combinational dependency on i_read_data_ready.
    elastic_input_ready <= not skid_valid_reg;
    M_AXI_RREADY <= elastic_input_ready when state = R_DATA else
                    '1' when state = R_DRAIN else '0';

    expected_rlast <= '1' when burst_beat_index = burst_beats_reg - 1 else '0';
    axi_beat_good <= '1' when M_AXI_RRESP = C_AXI_OKAY and
                                  M_AXI_RLAST = expected_rlast else '0';
    axi_beat_handshake <= '1' when M_AXI_RVALID = '1' and
                                  M_AXI_RREADY = '1' else '0';

    elastic_input_valid <= '1' when state = R_DATA and
                                    M_AXI_RVALID = '1' and
                                    axi_beat_good = '1' else '0';
    elastic_input_valid_bytes <= valid_bytes_encoding(remaining_bytes)
        when remaining_bytes < 4 else "00";
    elastic_input_last <= '1' when remaining_bytes > 0 and
                                  remaining_bytes <= 4 else '0';

    flush_elastic_buffer <= '1' when state = R_DATA and
                                    axi_beat_handshake = '1' and
                                    axi_beat_good = '0' else '0';
    output_last_handshake <= '1' when output_valid_reg = '1' and
                                     i_read_data_ready = '1' and
                                     output_last_reg = '1' else '0';

    elastic_buffer_process : process(axi_aclk)
        variable push_word : boolean;
        variable pop_word : boolean;
    begin
        if rising_edge(axi_aclk) then
            if axi_aresetn = '0' or flush_elastic_buffer = '1' then
                output_data_reg <= (others => '0');
                output_valid_bytes_reg <= "00";
                output_last_reg <= '0';
                output_valid_reg <= '0';
                skid_data_reg <= (others => '0');
                skid_valid_bytes_reg <= "00";
                skid_last_reg <= '0';
                skid_valid_reg <= '0';
            else
                push_word := elastic_input_valid = '1' and
                             elastic_input_ready = '1';
                pop_word := output_valid_reg = '1' and
                            i_read_data_ready = '1';

                if pop_word then
                    if skid_valid_reg = '1' then
                        output_data_reg <= skid_data_reg;
                        output_valid_bytes_reg <= skid_valid_bytes_reg;
                        output_last_reg <= skid_last_reg;
                        output_valid_reg <= '1';
                        skid_valid_reg <= '0';
                    elsif push_word then
                        output_data_reg <= M_AXI_RDATA;
                        output_valid_bytes_reg <= elastic_input_valid_bytes;
                        output_last_reg <= elastic_input_last;
                        output_valid_reg <= '1';
                    else
                        output_valid_reg <= '0';
                        output_last_reg <= '0';
                    end if;
                elsif push_word then
                    if output_valid_reg = '0' then
                        output_data_reg <= M_AXI_RDATA;
                        output_valid_bytes_reg <= elastic_input_valid_bytes;
                        output_last_reg <= elastic_input_last;
                        output_valid_reg <= '1';
                    else
                        skid_data_reg <= M_AXI_RDATA;
                        skid_valid_bytes_reg <= elastic_input_valid_bytes;
                        skid_last_reg <= elastic_input_last;
                        skid_valid_reg <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    read_control_process : process(axi_aclk)
        variable requested_length : natural;
        variable rounded_length : natural;
        variable remaining_after_beat : natural range 0 to C_MAX_IPV4_BYTES;
        variable next_address : unsigned(31 downto 0);
        variable read_end : unsigned(32 downto 0);
    begin
        if rising_edge(axi_aclk) then
            if axi_aresetn = '0' then
                state <= R_IDLE;
                address_reg <= (others => '0');
                remaining_bytes <= 0;
                burst_beats_reg <= 1;
                burst_beat_index <= 0;
            else
                case state is
                    when R_IDLE =>
                        if i_read_req_valid = '1' then
                            requested_length := to_integer(unsigned(i_read_length));
                            address_reg <= i_read_addr;
                            remaining_bytes <= requested_length;
                            burst_beat_index <= 0;

                            if requested_length > C_MAX_IPV4_BYTES then
                                state <= R_ERROR;
                            elsif requested_length = 0 then
                                remaining_bytes <= 0;
                                state <= R_DONE;
                            elsif i_read_addr(1 downto 0) /= "00" then
                                state <= R_ERROR;
                            else
                                rounded_length := ((requested_length + 3) / 4) * 4;
                                read_end := resize(unsigned(i_read_addr), 33) +
                                            rounded_length - 1;
                                if read_end(32) = '1' then
                                    state <= R_ERROR;
                                else
                                    burst_beats_reg <= calculate_burst_beats(
                                        i_read_addr, requested_length);
                                    state <= R_AR;
                                end if;
                            end if;
                        end if;

                    when R_AR =>
                        if M_AXI_ARREADY = '1' then
                            burst_beat_index <= 0;
                            state <= R_DATA;
                        end if;

                    when R_DATA =>
                        if axi_beat_handshake = '1' then
                            if axi_beat_good = '0' then
                                remaining_bytes <= 0;
                                if M_AXI_RLAST = '1' then
                                    state <= R_ERROR;
                                else
                                    state <= R_DRAIN;
                                end if;
                            else
                                if remaining_bytes > 4 then
                                    remaining_after_beat := remaining_bytes - 4;
                                else
                                    remaining_after_beat := 0;
                                end if;
                                remaining_bytes <= remaining_after_beat;

                                if expected_rlast = '1' then
                                    if remaining_after_beat = 0 then
                                        state <= R_WAIT_OUTPUT;
                                    else
                                        next_address := unsigned(address_reg) +
                                            to_unsigned(burst_beats_reg * 4, 32);
                                        address_reg <= std_logic_vector(next_address);
                                        burst_beats_reg <= calculate_burst_beats(
                                            std_logic_vector(next_address),
                                            remaining_after_beat);
                                        burst_beat_index <= 0;
                                        state <= R_AR;
                                    end if;
                                else
                                    burst_beat_index <= burst_beat_index + 1;
                                end if;
                            end if;
                        end if;

                    when R_WAIT_OUTPUT =>
                        if output_last_handshake = '1' then
                            state <= R_DONE;
                        end if;

                    when R_DRAIN =>
                        if M_AXI_RVALID = '1' and M_AXI_RLAST = '1' then
                            state <= R_ERROR;
                        end if;

                    when R_DONE | R_ERROR =>
                        state <= R_IDLE;
                end case;
            end if;
        end if;
    end process;
end architecture;
