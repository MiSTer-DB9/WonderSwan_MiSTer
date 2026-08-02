library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pRegisterBus.all;
use work.pBus_savestates.all;
use work.pReg_savestates.all;

-- WonderSwan EXT-port UART.
--
-- The external signals use inverted UART polarity: the line is low while
-- idle, a start bit is high, data bits are inverted, and the stop bit is low.
-- The core clock enable is the native 3.072 MHz WonderSwan clock, giving
-- exact divisors of 320 clocks/bit at 9600 baud, 80 clocks/bit at 38400,
-- and 16 clocks/bit in the SoC's 192000-baud UART test mode.
entity ws_serial is
   port
   (
      clk               : in  std_logic;
      ce                : in  std_logic;
      reset             : in  std_logic;

      serial_rx         : in  std_logic;
      serial_tx         : out std_logic;
      active            : out std_logic;

      IRQ_SerialSend    : out std_logic;
      IRQ_SerialReceive : out std_logic;

      RegBus_Din        : in  std_logic_vector(BUS_buswidth-1 downto 0);
      RegBus_Adr        : in  std_logic_vector(BUS_busadr-1 downto 0);
      RegBus_wren       : in  std_logic;
      RegBus_rden       : in  std_logic;
      RegBus_word       : in  std_logic;
      RegBus_Dout       : out std_logic_vector(BUS_buswidth-1 downto 0);

      SSBUS_Din         : in  std_logic_vector(SSBUS_buswidth-1 downto 0);
      SSBUS_Adr         : in  std_logic_vector(SSBUS_busadr-1 downto 0);
      SSBUS_wren        : in  std_logic;
      SSBUS_rst         : in  std_logic;
      SSBUS_Dout        : out std_logic_vector(SSBUS_buswidth-1 downto 0)
   );
end entity;

architecture arch of ws_serial is

   constant TX_IDLE        : std_logic_vector(2 downto 0) := "000";
   constant TX_WAIT_ENABLE : std_logic_vector(2 downto 0) := "001";
   constant TX_START       : std_logic_vector(2 downto 0) := "010";
   constant TX_DATA        : std_logic_vector(2 downto 0) := "011";
   constant TX_STOP        : std_logic_vector(2 downto 0) := "100";

   constant RX_IDLE        : std_logic_vector(1 downto 0) := "00";
   constant RX_START       : std_logic_vector(1 downto 0) := "01";
   constant RX_BITS        : std_logic_vector(1 downto 0) := "10";
   constant RX_STOP        : std_logic_vector(1 downto 0) := "11";

   signal control_enable    : std_logic := '0';
   signal control_highspeed : std_logic := '0';
   signal uart_test         : std_logic := '0';

   signal baud_reload      : unsigned(8 downto 0);
   signal baud_half_reload : unsigned(8 downto 0);

   signal tx_state        : std_logic_vector(2 downto 0) := TX_IDLE;
   signal tx_shift        : std_logic_vector(7 downto 0) := (others => '0');
   signal tx_bit_index    : unsigned(2 downto 0) := (others => '0');
   signal tx_baud_counter : unsigned(8 downto 0) := (others => '0');
   signal tx_busy         : std_logic := '0';
   signal tx_line         : std_logic := '0';

   signal rx_state        : std_logic_vector(1 downto 0) := RX_IDLE;
   signal rx_shift        : std_logic_vector(7 downto 0) := (others => '0');
   signal rx_data         : std_logic_vector(7 downto 0) := (others => '0');
   signal rx_bit_index    : unsigned(2 downto 0) := (others => '0');
   signal rx_baud_counter : unsigned(8 downto 0) := (others => '0');
   signal rx_full         : std_logic := '0';
   signal rx_overrun      : std_logic := '0';

   signal rx_meta         : std_logic := '0';
   signal rx_sync         : std_logic := '0';

   signal SS_UART      : std_logic_vector(REG_SAVESTATE_UART.upper downto REG_SAVESTATE_UART.lower);
   signal SS_UART_BACK : std_logic_vector(REG_SAVESTATE_UART.upper downto REG_SAVESTATE_UART.lower);

begin

   baud_reload <= to_unsigned(15, baud_reload'length) when uart_test = '1' else
                  to_unsigned(79, baud_reload'length) when control_highspeed = '1' else
                  to_unsigned(319, baud_reload'length);

   baud_half_reload <= to_unsigned(7, baud_half_reload'length) when uart_test = '1' else
                       to_unsigned(39, baud_half_reload'length) when control_highspeed = '1' else
                       to_unsigned(159, baud_half_reload'length);

   serial_tx <= tx_line;
   active    <= control_enable;

   IRQ_SerialSend    <= control_enable and not tx_busy;
   IRQ_SerialReceive <= control_enable and rx_full;

   process (all)
   begin
      RegBus_Dout <= (others => '0');

      if RegBus_Adr = x"A3" then
         RegBus_Dout(3) <= uart_test;
      elsif RegBus_Adr = x"B1" then
         RegBus_Dout <= rx_data;
      elsif RegBus_Adr = x"B3" then
         RegBus_Dout(7) <= control_enable;
         RegBus_Dout(6) <= control_highspeed;
         RegBus_Dout(2) <= not tx_busy;
         RegBus_Dout(1) <= rx_overrun;
         RegBus_Dout(0) <= rx_full;
      end if;
   end process;

   iSS_UART : entity work.eReg_SS
   generic map (REG_SAVESTATE_UART)
   port map
   (
      clk, SSBUS_Din, SSBUS_Adr, SSBUS_wren, SSBUS_rst,
      SSBUS_Dout, SS_UART_BACK, SS_UART
   );

   SS_UART_BACK(0)            <= control_enable;
   SS_UART_BACK(1)            <= control_highspeed;
   SS_UART_BACK(2)            <= rx_full;
   SS_UART_BACK(3)            <= rx_overrun;
   SS_UART_BACK(4)            <= tx_busy;
   SS_UART_BACK(5)            <= tx_line;
   SS_UART_BACK(8 downto 6)   <= tx_state;
   SS_UART_BACK(11 downto 9)  <= std_logic_vector(tx_bit_index);
   SS_UART_BACK(20 downto 12) <= std_logic_vector(tx_baud_counter);
   SS_UART_BACK(28 downto 21) <= tx_shift;
   SS_UART_BACK(30 downto 29) <= rx_state;
   SS_UART_BACK(33 downto 31) <= std_logic_vector(rx_bit_index);
   SS_UART_BACK(42 downto 34) <= std_logic_vector(rx_baud_counter);
   SS_UART_BACK(50 downto 43) <= rx_shift;
   SS_UART_BACK(58 downto 51) <= rx_data;
   SS_UART_BACK(59)           <= rx_meta;
   SS_UART_BACK(60)           <= rx_sync;
   SS_UART_BACK(61)           <= uart_test;
   SS_UART_BACK(63 downto 62) <= (others => '0');

   process (clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            control_enable    <= SS_UART(0);
            control_highspeed <= SS_UART(1);
            rx_full           <= SS_UART(2);
            rx_overrun        <= SS_UART(3);
            tx_busy           <= SS_UART(4);
            tx_line           <= SS_UART(5);
            tx_state          <= SS_UART(8 downto 6);
            tx_bit_index      <= unsigned(SS_UART(11 downto 9));
            tx_baud_counter   <= unsigned(SS_UART(20 downto 12));
            tx_shift          <= SS_UART(28 downto 21);
            rx_state          <= SS_UART(30 downto 29);
            rx_bit_index      <= unsigned(SS_UART(33 downto 31));
            rx_baud_counter   <= unsigned(SS_UART(42 downto 34));
            rx_shift          <= SS_UART(50 downto 43);
            rx_data           <= SS_UART(58 downto 51);
            rx_meta           <= SS_UART(59);
            rx_sync           <= SS_UART(60);
            uart_test         <= SS_UART(61);
         else
            -- Synchronize the asynchronous EXT-port input into clk.
            rx_meta <= serial_rx;
            rx_sync <= rx_meta;

            -- $B3: enable, speed, and write-one-to-clear overrun.
            if RegBus_wren = '1' and RegBus_Adr = x"B3" then
               control_enable    <= RegBus_Din(7);
               control_highspeed <= RegBus_Din(6);
               if RegBus_Din(5) = '1' then
                  rx_overrun <= '0';
               end if;
            end if;

            -- $A3 bit 3 enables the SoC UART test clock. Hardware ignores
            -- this register when it is reached as the high byte of a word
            -- write to $A2, so accept byte writes only.
            if RegBus_wren = '1' and RegBus_word = '0' and RegBus_Adr = x"A3" then
               uart_test <= RegBus_Din(3);
            end if;

            -- Reading $B1 consumes the one-byte receive buffer.
            if RegBus_rden = '1' and RegBus_Adr = x"B1" then
               rx_full <= '0';
            end if;

            -- Writes while the one-byte transmit buffer is full are ignored.
            if RegBus_wren = '1' and RegBus_Adr = x"B1" and tx_busy = '0' then
               tx_shift <= RegBus_Din;
               tx_busy  <= '1';
               tx_state <= TX_WAIT_ENABLE;
            end if;

            if ce = '1' then
               -- Transmitter. When disabled, retain a queued byte but return
               -- the external line to its low (idle) state.
               if control_enable = '0' then
                  tx_line <= '0';
                  if tx_busy = '1' then
                     tx_state <= TX_WAIT_ENABLE;
                  else
                     tx_state <= TX_IDLE;
                  end if;
               else
                  case tx_state is
                     when TX_IDLE =>
                        tx_line <= '0';

                     when TX_WAIT_ENABLE =>
                        tx_line         <= '1'; -- inverted start bit
                        tx_state        <= TX_START;
                        tx_baud_counter <= baud_reload;

                     when TX_START =>
                        if tx_baud_counter = 0 then
                           tx_line      <= not tx_shift(0);
                           tx_bit_index <= (others => '0');
                           tx_state     <= TX_DATA;
                           tx_baud_counter <= baud_reload;
                        else
                           tx_baud_counter <= tx_baud_counter - 1;
                        end if;

                     when TX_DATA =>
                        if tx_baud_counter = 0 then
                           if tx_bit_index = 7 then
                              tx_line  <= '0'; -- inverted stop bit
                              tx_state <= TX_STOP;
                           else
                              tx_bit_index <= tx_bit_index + 1;
                              tx_line      <= not tx_shift(to_integer(tx_bit_index) + 1);
                           end if;
                           tx_baud_counter <= baud_reload;
                        else
                           tx_baud_counter <= tx_baud_counter - 1;
                        end if;

                     when TX_STOP =>
                        if tx_baud_counter = 0 then
                           tx_line  <= '0';
                           tx_busy  <= '0';
                           tx_state <= TX_IDLE;
                        else
                           tx_baud_counter <= tx_baud_counter - 1;
                        end if;

                     when others =>
                        tx_line  <= '0';
                        tx_busy  <= '0';
                        tx_state <= TX_IDLE;
                  end case;
               end if;

               -- Receiver. Start and data are sampled in the center of each
               -- bit cell. A bad (high) inverted stop bit drops the frame.
               if control_enable = '0' then
                  rx_state        <= RX_IDLE;
                  rx_baud_counter <= (others => '0');
               else
                  case rx_state is
                     when RX_IDLE =>
                        if rx_sync = '1' then -- inverted start bit
                           rx_state <= RX_START;
                           rx_baud_counter <= baud_half_reload;
                        end if;

                     when RX_START =>
                        if rx_baud_counter = 0 then
                           if rx_sync = '1' then
                              rx_bit_index <= (others => '0');
                              rx_state     <= RX_BITS;
                              rx_baud_counter <= baud_reload;
                           else
                              rx_state <= RX_IDLE;
                           end if;
                        else
                           rx_baud_counter <= rx_baud_counter - 1;
                        end if;

                     when RX_BITS =>
                        if rx_baud_counter = 0 then
                           rx_shift(to_integer(rx_bit_index)) <= not rx_sync;
                           if rx_bit_index = 7 then
                              rx_state <= RX_STOP;
                           else
                              rx_bit_index <= rx_bit_index + 1;
                           end if;
                           rx_baud_counter <= baud_reload;
                        else
                           rx_baud_counter <= rx_baud_counter - 1;
                        end if;

                     when RX_STOP =>
                        if rx_baud_counter = 0 then
                           if rx_sync = '0' then -- valid inverted stop bit
                              if rx_full = '1' then
                                 rx_overrun <= '1';
                              else
                                 rx_data <= rx_shift;
                                 rx_full <= '1';
                              end if;
                           end if;
                           rx_state <= RX_IDLE;
                        else
                           rx_baud_counter <= rx_baud_counter - 1;
                        end if;

                     when others =>
                        rx_state <= RX_IDLE;
                  end case;
               end if;
            end if;
         end if;
      end if;
   end process;

end architecture;
