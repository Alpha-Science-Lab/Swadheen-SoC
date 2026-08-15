/* 
  MCU top
  FPGA Gowin GW1NR-9
  Board Tang Nano 9K
  Alpha Science Lab
  July 2026
*/


module tang9k_SoC #(
    parameter real CLK_FREQUENCY_MHZ,
    parameter int  UART_BAUD_RATE
) (
    // Main system clk
    input logic clk,

    // Memory clock
    input logic clk_mem,

    // LEDs
    output logic [15:0] leds,

    // Buttons
    input  logic [4:0] buttons_async,

    // UART
    input  logic uart_rx_async,
    output logic uart_tx,

    // GPIOs
    inout  logic [15:0] gpioa,
    inout  logic [15:0] gpiob,
    inout  logic [15:0] gpioc

);
    import constants::*;

    // --------------------------------------------------------------------------------------------
    // |                                     Synchronization                                      |
    // --------------------------------------------------------------------------------------------

    logic [4:0] buttons;
    
    for (genvar i = 0; i < 5; i++) begin : sync_buttons
        synchronizer button_sync(
            .clk(clk),
            .async_in(buttons_async[i]),
            .sync_out(buttons[i])
        );
    end

    logic uart_rx;
    synchronizer uart_rx_sync(
        .clk(clk),
        .async_in(uart_rx_async),
        .sync_out(uart_rx)
    );

    // --------------------------------------------------------------------------------------------
    // |                                           rst                                            |
    // --------------------------------------------------------------------------------------------

    // Use initial assignment to ensure initial reset after loading the configuration (FPGA only)
    logic rst = 1;

    // Use center button as reset
    always_ff @(posedge clk) begin
        rst <= buttons[1];
    end

    // --------------------------------------------------------------------------------------------
    // |                                           CPU                                            |
    // --------------------------------------------------------------------------------------------

    // Wishbone
    wishbone_interface fetch_bus();
    wishbone_interface mem_bus();

    // Interrupts    
    logic test_interrupt;
    logic uart_interrupt;
    logic timer_interrupt;

    logic external_interrupt;
    assign external_interrupt = |{
        uart_interrupt,
        test_interrupt
    };

    // Instantiate CPU
    Hadi_V cpu(
        .clk(clk),
        .rst(rst),
        .memory_fetch_port(fetch_bus.master),
        .memory_mem_port(mem_bus.master),
        .external_interrupt_in(external_interrupt),
        .timer_interrupt_in(timer_interrupt)
    );

    // --------------------------------------------------------------------------------------------
    // |                                       Peripherals                                        |
    // --------------------------------------------------------------------------------------------

    // Memory bus interconnect
    wishbone_interface mem_bus_slaves[14]();
    wishbone_interconnect #(
        .NUM_SLAVES(14),
        .SLAVE_ADDRESS({
            MEMORY_START,
            LEDS_START,
            BUTTONS_START,
            SWITCHES_START,
            SEGMENTS_START,
            UART_START,
            TIMER_START,
            PWM_START,
            I2C_START,
            I2S_START,
            SPI_START,
            GPIO_START,
            VGA_START,
            TEST_START
        }),
        .SLAVE_SIZE({
            MEMORY_SIZE,
            LEDS_SIZE,
            BUTTONS_SIZE,
            SWITCHES_SIZE,
            SEGMENTS_SIZE,
            UART_SIZE,
            TIMER_SIZE,
            PWM_SIZE,
            I2C_SIZE,
            I2S_SIZE,
            SPI_SIZE,
            GPIO_SIZE,
            VGA_SIZE,
            TEST_SIZE
        })
    ) peripheral_bus_interconnect (
        .clk(clk),
        .rst(rst),
        .master(mem_bus),
        .slaves(mem_bus_slaves)
    );

    tang9k_ram #(
        .ADDRESS(MEMORY_START),
        .SIZE(MEMORY_SIZE)
    ) ram (
        .clk(clk_mem),
        .rst(rst),
        .port_a(fetch_bus.slave),
        .port_b(mem_bus_slaves[0])
    );

    wishbone_leds #(
        .ADDRESS(LEDS_START),
        .SIZE(LEDS_SIZE)
    ) wb_leds (
        .clk(clk),
        .rst(rst),
        .leds(leds),
        .wishbone(mem_bus_slaves[1])
    );

    wishbone_buttons #(
        .ADDRESS(BUTTONS_START),
        .SIZE(BUTTONS_SIZE)
    ) wb_buttons (
        .clk(clk),
        .rst(rst),
        .buttons(buttons),
        .wishbone(mem_bus_slaves[2])
    );

    logic uart_rx_gpio;

    wishbone_uart #(
        .ADDRESS(UART_START),
        .SIZE(UART_SIZE),
        .BAUD_RATE(UART_BAUD_RATE),
        .CLK_FREQUENCY_MHZ(CLK_FREQUENCY_MHZ)
    ) wb_uart (
        .clk(clk),
        .rst(rst),
        .rx_serial_in(uart_rx | uart_rx_gpio),
        .tx_serial_out(uart_tx),
        .interrupt(uart_interrupt),
        .wishbone(mem_bus_slaves[5])
    );

    wishbone_timer #(
        .ADDRESS(TIMER_START),
        .SIZE(TIMER_SIZE),
        .CLK_FREQUENCY_MHZ(CLK_FREQUENCY_MHZ)
    ) wb_timer (
        .clk(clk),
        .rst(rst),
        .interrupt(timer_interrupt),
        .wishbone(mem_bus_slaves[6])
    );

    logic [15:0] pwm_out;

    spondon_wb_pwm #(
        .START_ADDRESS(PWM_START),
        .SIZE(PWM_SIZE),
        .DEFAULT_PRESCALER(16'd7),
        .DEFAULT_PERIOD(16'd999)
    ) wb_pwm (
        .clk(clk),
        .rst(rst),
        .wb(mem_bus_slaves[7]),
        .pwm_out(pwm_out)
    );

    logic i2c_intr;
    logic i2c_sda_i;
    logic i2c_sda_o;
    logic i2c_sda_oe;
    logic i2c_scl_i;
    logic i2c_scl_o;
    logic i2c_scl_oe;
    
    dotara_wb_i2c #(
        .START_ADDRESS(I2C_START),
        .SIZE(I2C_SIZE),
        .FIFO_DEPTH(16),
        .DEFAULT_PRESCALER(16'd45)
    ) wb_i2c (
        .clk(clk),
        .rst(rst),
        .wb(mem_bus_slaves[8]),
        .intr(i2c_intr),
        .scl_pad_i(i2c_scl_i),
        .scl_pad_o(i2c_scl_o),
        .scl_padoen_o(i2c_scl_oe),
        .sda_pad_i(i2c_sda_i),
        .sda_pad_o(i2c_sda_o),
        .sda_padoen_o(i2c_sda_oe)
    );


    logic spi_intr;
    logic spi_clk;
    logic spi_mosi;
    logic [7:0] spi_miso;
    logic spi_miso_mux_o;
    logic [7:0] spi_cs;

    assign spi_miso_mux_o = (spi_cs == 8'h7F) ? spi_miso[7] :
                            (spi_cs == 8'hBF) ? spi_miso[6] :
                            (spi_cs == 8'hDF) ? spi_miso[5] :
                            (spi_cs == 8'hEF) ? spi_miso[4] :
                            (spi_cs == 8'hF7) ? spi_miso[3] :
                            (spi_cs == 8'hFB) ? spi_miso[2] :
                            (spi_cs == 8'hFD) ? spi_miso[1] :
                            (spi_cs == 8'hFE) ? spi_miso[0] :
                            1'b0;
    
    karnaphuli_wb_spi #(
        .START_ADDRESS(SPI_START),
        .SIZE(SPI_SIZE),
        .NUM_SLAVES(8),
        .FIFO_DEPTH(16),
        .DEFAULT_PRESCALER(16'd1)

    ) wb_spi (
        .clk(clk),
        .rst(rst),
        .wb(mem_bus_slaves[10]),
        .intr(spi_intr),
        .spi_sclk(spi_clk),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso_mux_o),
        .spi_cs_n(spi_cs)
    );

    brahmaputra_wb_gpio #(
        .START_ADDRESS(GPIO_START),
        .SIZE(GPIO_SIZE)
    ) wb_gpio (
        .clk(clk),
        .rst(rst),
        .wb(mem_bus_slaves[11]),
        .gpioa(gpioa),
        .gpiob(gpiob),
        .gpioc(gpioc),
        .uart_tx(uart_tx),
        .uart_rx(uart_rx_gpio),
        .i2c_sda_o(i2c_sda_o),
        .i2c_sda_oe(i2c_sda_oe),
        .i2c_sda_i(i2c_sda_i),
        .i2c_scl_o(i2c_scl_o),
        .i2c_scl_oe(i2c_scl_oe),
        .i2c_scl_i(i2c_scl_i),
        .spi0_mosi_o(spi_mosi),
        .spi0_sck_o(spi_clk),
        .spi0_cs_o(spi_cs[7]),
        .spi0_miso_i(spi_miso[7]),
        .spi1_mosi_o(spi_mosi),
        .spi1_sck_o(spi_clk),
        .spi1_cs_o(spi_cs[6]),
        .spi1_miso_i(spi_miso[6]),
        .pwm_out(pwm_out)
    );

endmodule
