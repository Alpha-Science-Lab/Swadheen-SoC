/* 
  MCU top
  FPGA Gowin GW1NR-9
  Board Tang Nano 9K
  Alpha Science Lab
  July 2026
*/


module tang9k_SoC #(
    parameter real CLK_FREQUENCY_MHZ,
    parameter int  UART_BAUD_RATE,
    parameter int  UART1_BAUD_RATE
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
    inout  logic [15:0] gpioc,

    // Ext. SPI Flash
    output logic extsf_clk,
    output logic extsf_mosi,
    input  logic extsf_miso,
    output logic extsf_cs_n
);
    import constants::*;

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
   
    logic rst = 1;

    // The Tang top puts S2 (inverted) or "PLL not locked" on buttons[1], active high.
    // buttons[0] is S1, which reads 1 while released and would hold the CPU in reset.
    always_ff @(posedge clk) begin
        rst <= buttons[1];
    end

    assign extsf_sclk  = spi_sclk;
    assign extsf_mosi  = spi_mosi;
    assign spi_miso[0] = extsf_miso;
    assign extsf_cs_n  = spi_cs_n[0];
    
    // Wishbone
    wishbone_interface fetch_bus();
    wishbone_interface mem_bus();

    // peipheral wires
    logic uart_rx_gpio, uart_tx_gpio;
    logic uart_rx_gpio_raw;

    // The pin is asynchronous to clk
    synchronizer uart1_rx_sync(
        .clk(clk),
        .async_in(uart_rx_gpio_raw),
        .sync_out(uart_rx_gpio)
    );

    logic [15:0] pwm_out;

    logic i2c_intr;
    logic i2c_sda_i;
    logic i2c_sda_o;
    logic i2c_sda_oe;
    logic i2c_scl_i;
    logic i2c_scl_o;
    logic i2c_scl_oe;

    logic spi_intr;
    logic spi_sclk;
    logic spi_mosi;
    logic [3:0] spi_miso;
    logic spi_miso_mux_o;
    logic [3:0] spi_cs_n;

    logic i2s_intr;
    logic i2s_bclk;
    logic i2s_lrclk;
    logic i2s_sdout;

    /* spi_miso is driven by multiple
        sources from GPIO  */
    assign spi_miso_mux_o = 
        (spi_cs_n == 4'h7) ? spi_miso[3] :
        (spi_cs_n == 4'hB) ? spi_miso[2] :
        (spi_cs_n == 4'hD) ? spi_miso[1] :
        (spi_cs_n == 4'hE) ? spi_miso[0] :
        1'b0;

    // Interrupts    
    logic uart0_interrupt, uart1_interrupt;
    logic timer_interrupt;

    logic external_interrupt;
    assign external_interrupt = |{
        uart0_interrupt,
        uart1_interrupt,
        i2c_intr,
        i2s_intr,
        spi_intr
    };

    // Instantiate CPU
    Hadi_V #(
        .RESET_VECTOR(constants::RESET_ADDRESS),
        .HART_ID(32'h0)
    ) cpu (
        .clk(clk),
        .rst(rst),
        .memory_fetch_port(fetch_bus.master),
        .memory_mem_port(mem_bus.master),
        .external_interrupt_in(external_interrupt),
        .timer_interrupt_in(timer_interrupt)
    );

    // Memory bus interconnect
    wishbone_interface slaves[12]();
    wishbone_interconnect #(
        .NUM_SLAVES(12),
        .SLAVE_ADDRESS({
            MEMORY_START, LEDS_START, BUTTONS_START, UART_START, 
            UART1_START, TIMER_START,PWM_START, I2C_START, 
            I2S_START, SPI_START, GPIO_START, TEST_START
        }),
        .SLAVE_SIZE({
            MEMORY_SIZE, LEDS_SIZE, BUTTONS_SIZE, UART_SIZE, 
            UART_SIZE, TIMER_SIZE, PWM_SIZE, I2C_SIZE, 
            I2S_SIZE, SPI_SIZE, GPIO_SIZE, TEST_SIZE
        })
    ) peripheral_bus_interconnect (
        .clk(clk),
        .rst(rst),
        .master(mem_bus),
        .slaves(slaves)
    );

    tang9k_ram #(
        .ADDRESS(MEMORY_START),
        .SIZE(MEMORY_SIZE)
    ) ram (
        .clk(clk_mem),
        .rst(rst),
        .port_a(fetch_bus.slave),
        .port_b(slaves[0])
    );

    wishbone_leds #(
        .ADDRESS(LEDS_START),
        .SIZE(LEDS_SIZE)
    ) wb_leds (
        .clk(clk),
        .rst(rst),
        .leds(leds),
        .wishbone(slaves[1])
    );

    wishbone_buttons #(
        .ADDRESS(BUTTONS_START),
        .SIZE(BUTTONS_SIZE)
    ) wb_buttons (
        .clk(clk),
        .rst(rst),
        .buttons(buttons),
        .wishbone(slaves[2])
    );

    wishbone_uart #(
        .ADDRESS(UART_START),
        .SIZE(UART_SIZE),
        .BAUD_RATE(UART_BAUD_RATE),
        .CLK_FREQUENCY_MHZ(CLK_FREQUENCY_MHZ)
    ) wb_uart0 (
        .clk(clk),
        .rst(rst),
        .rx_serial_in(uart_rx),
        .tx_serial_out(uart_tx),
        .interrupt(uart0_interrupt),
        .wishbone(slaves[3])
    );

    wishbone_uart #(
        .ADDRESS(UART1_START),
        .SIZE(UART_SIZE),
        .BAUD_RATE(UART1_BAUD_RATE),
        .CLK_FREQUENCY_MHZ(CLK_FREQUENCY_MHZ)
    ) wb_uart1 (
        .clk(clk),
        .rst(rst),
        .rx_serial_in(uart_rx_gpio),
        .tx_serial_out(uart_tx_gpio),
        .interrupt(uart1_interrupt),
        .wishbone(slaves[4])
    );

    wishbone_timer #(
        .ADDRESS(TIMER_START),
        .SIZE(TIMER_SIZE),
        .CLK_FREQUENCY_MHZ(CLK_FREQUENCY_MHZ)
    ) wb_timer (
        .clk(clk),
        .rst(rst),
        .interrupt(timer_interrupt),
        .wishbone(slaves[5])
    );

    spondon_wb_pwm #(
        .START_ADDRESS(PWM_START),
        .SIZE(PWM_SIZE),
        .DEFAULT_PRESCALER(16'd7),
        .DEFAULT_PERIOD(16'd999)
    ) wb_pwm (
        .clk(clk),
        .rst(rst),
        .wb(slaves[6]),
        .pwm_out(pwm_out)
    );
    
    dotara_wb_i2c #(
        .START_ADDRESS(I2C_START),
        .SIZE(I2C_SIZE),
        .FIFO_DEPTH(16),
        .DEFAULT_PRESCALER(16'd45)
    ) wb_i2c (
        .clk(clk),
        .rst(rst),
        .wb(slaves[7]),
        .intr(i2c_intr),
        .scl_pad_i(i2c_scl_i),
        .scl_pad_o(i2c_scl_o),
        .scl_pad_oe(i2c_scl_oe),
        .sda_pad_i(i2c_sda_i),
        .sda_pad_o(i2c_sda_o),
        .sda_pad_oe(i2c_sda_oe)
    );

    bashi_wb_i2s #(
        .START_ADDRESS(I2S_START),
        .SIZE(I2S_SIZE)
    ) wb_i2s (
        .clk(clk),
        .rst(rst),
        .wb(slaves[8]),
        .intr(i2s_intr),
        .i2s_bclk(i2s_bclk),
        .i2s_lrclk(i2s_lrclk),
        .i2s_sdout(i2s_sdout)
    );
    
    karnaphuli_wb_spi #(
        .START_ADDRESS(SPI_START),
        .SIZE(SPI_SIZE),
        .NUM_SLAVES(4),
        .FIFO_DEPTH(256),
        .DEFAULT_PRESCALER(16'd1)
    ) wb_spi (
        .clk(clk),
        .rst(rst),
        .wb(slaves[9]),
        .intr(spi_intr),
        .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso_mux_o),
        .spi_cs_n(spi_cs_n)
    );

    brahmaputra_wb_gpio #(
        .START_ADDRESS(GPIO_START),
        .SIZE(GPIO_SIZE)
    ) wb_gpio (
        .clk(clk),
        .rst(rst),
        .wb(slaves[10]),
        .gpioa(gpioa),
        .gpiob(gpiob),
        .gpioc(gpioc),
        .uart_tx(uart_tx_gpio),
        .uart_rx(uart_rx_gpio_raw),
        // dotara's pad_oe is active-low (1 = release the line), the GPIO mux wants an active-high enable
        .i2c_sda_o(i2c_sda_o),
        .i2c_sda_oe(~i2c_sda_oe),
        .i2c_sda_i(i2c_sda_i),
        .i2c_scl_o(i2c_scl_o),
        .i2c_scl_oe(~i2c_scl_oe),
        .i2c_scl_i(i2c_scl_i),
        .spi0_mosi(spi_mosi),
        .spi0_sck(spi_sclk),
        .spi0_cs_n(spi_cs_n[3]),
        .spi0_miso(spi_miso[3]),
        .spi1_mosi(spi_mosi),
        .spi1_sck(spi_sclk),
        .spi1_cs_n(spi_cs_n[2]),
        .spi1_miso(spi_miso[2]),
        .i2s_sck(i2s_bclk),
        .i2s_ws(i2s_lrclk),
        .i2s_sd_o(i2s_sdout),
        .pwm_out(pwm_out)
    );

endmodule
