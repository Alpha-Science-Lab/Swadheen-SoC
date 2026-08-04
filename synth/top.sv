/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: top.sv
 */



module top(
    // 100 MHz input clock
    input logic clk_100mhz,

    // LEDs
    output logic [15:0] leds,

    // Buttons (order: 4 - drluc- 0)
    input  logic [4:0] buttons_async,

    // UART
    input  logic uart_rx_async,
    output logic uart_tx
);

    // --------------------------------------------------------------------------------------------
    // |                                     Clock Generation                                     |
    // --------------------------------------------------------------------------------------------
    import clk_params::*;

    logic clk, clk_fb;
    logic clk_mem;

    MMCME2_BASE #(
        .CLKFBOUT_MULT_F(MMCM_MUL),               // Input clock multiplication: 2.000 - 64.000 (steps of 0.125 ?)
        .CLKIN1_PERIOD(INPUT_CLK_PERIOD_NS),      // Input clock period in ns
        .CLKOUT0_DIVIDE_F(MMCM_DIV_0),            // Output clock division: 1.000 - 128.000 (steps of 0.125)
        .DIVCLK_DIVIDE(MMCM_DIV),                 // Input clock division: 1-56
        .REF_JITTER1(INPUT_CLK_JITTER_TO_PERIOD), // Ratio of jitter to period
        .STARTUP_WAIT("TRUE")                     // Wait for lock before enabling device outputs and registers
    ) mmcm (
        .CLKIN1(clk_100mhz), // Input clock
        .CLKOUT0(clk),       // Output clock: (100 MHz / 1 * 10) / 20 = 50 MHz
        .CLKOUT0B(clk_mem),  // Inverted output clock

        .CLKFBOUT(clk_fb),  /* Feedback out*/ .CLKFBIN(clk_fb), // Feedback in

        .CLKOUT1(),.CLKOUT1B(),.CLKOUT2(),.CLKOUT2B(),.CLKOUT3(),.CLKOUT3B(),.CLKOUT4(),.CLKOUT5(),.CLKOUT6(),.CLKFBOUTB(),

        .LOCKED(),.PWRDWN(0),.RST(0)
    );


    // --------------------------------------------------------------------------------------------
    // |                                    MCU Instantiation                                     |
    // --------------------------------------------------------------------------------------------

    Swadheen_SoC #(
        .CLK_FREQUENCY_MHZ(SYS_CLK_FREQUENCY_MHZ),
        .UART_BAUD_RATE(115200)
    ) SoC (
        .clk(clk),
        .clk_mem(clk_mem),
        .leds(leds),
        .buttons_async(buttons_async),
        .uart_rx_async(uart_rx_async),
        .uart_tx(uart_tx)
    );
endmodule
