/* File: uart1_demo.c
 *
 * UART1 loopback demonstration.
 *
 * UART1 is routed to GPIOA by the pin function mux:
 *   GPIOA[0] = UART1 TX   (Tang Nano 9K pin 25)
 *   GPIOA[1] = UART1 RX   (Tang Nano 9K pin 26)
 *
 * Wiring: jumper pin 25 to pin 26 (TX -> RX).
 * For an HC-05 Bluetooth module connect pin 25 to the module RXD and
 * pin 26 to the module TXD instead.
 *
 * The result is printed on UART0 (USB serial, 115200 baud) and shown on the
 * LEDs (active-low): LED0 on = pass, LED5 on = fail.
 */

#include <stdint.h>
#include "peripherals.h"

#define SYS_CLK_HZ      9000000UL
#define TICKS_PER_MS    (SYS_CLK_HZ / 1000UL)

#define FUNC_UART       0x1u
#define RX_TIMEOUT_MS   20u

static int failures;


/* --------------------------------------------------------------------------
 * Helpers
 * -------------------------------------------------------------------------- */

static void uart_putc(char c)
{
    while (!(*UART_TX_STATUS_ADDRESS & (1u << UART_TX_STATUS_IDX_EMPTY)))
        ;
    *UART_BUFFER_ADDRESS = (uint8_t)c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static void uart_put_hex(uint32_t v, int digits)
{
    while (digits--)
        uart_putc("0123456789ABCDEF"[(v >> (digits * 4)) & 0xFu]);
}

static uint64_t timer_get(void)
{
    uint32_t hi1, lo, hi2;

    do {
        hi1 = *TIMER_MTIMEH_ADDRESS;
        lo  = *TIMER_MTIME_ADDRESS;
        hi2 = *TIMER_MTIMEH_ADDRESS;
    } while (hi1 != hi2);

    return ((uint64_t)hi2 << 32) | lo;
}

static void report(const char *name, int ok)
{
    uart_puts(name);
    uart_puts(ok ? ": PASS\r\n" : ": FAIL\r\n");

    if (!ok)
        failures++;
}


/* --------------------------------------------------------------------------
 * UART1
 * -------------------------------------------------------------------------- */

static void uart1_put(uint8_t b)
{
    while (!(*UART1_TX_STATUS_ADDRESS & (1u << UART_TX_STATUS_IDX_EMPTY)))
        ;
    *UART1_BUFFER_ADDRESS = b;
}

/* Returns 1 and stores the byte, or 0 if nothing arrived in time */
static int uart1_get(uint8_t *b)
{
    uint64_t start = timer_get();

    while (!(*UART1_RX_STATUS_ADDRESS & (1u << UART_RX_STATUS_IDX_FULL))) {
        if ((timer_get() - start) > (RX_TIMEOUT_MS * TICKS_PER_MS))
            return 0;
    }

    *b = *UART1_BUFFER_ADDRESS;
    return 1;
}


/* --------------------------------------------------------------------------
 * Demo
 * -------------------------------------------------------------------------- */

static const uint8_t pattern[] = {
    0x55, 0xAA, 0x00, 0xFF, 0x0F, 0xF0, 'U', 'A', 'R', 'T', '1'
};

int main(void)
{
    uint8_t  rx;
    unsigned i;
    unsigned good = 0;

    failures = 0;

    uart_puts("\r\nUART1 DEMO\r\n");
    uart_puts("UART1: TX = GPIOA[0] (pin 25), RX = GPIOA[1] (pin 26)\r\n");

    /* GPIOA[1:0] -> UART1; FUNC0 covers GPIOA[3:0], leave pins 3:2 alone */
    *GPIOA_FUNC0_ADDRESS = (*GPIOA_FUNC0_ADDRESS & ~0x00FFu)
                         | (FUNC_UART << 0)
                         | (FUNC_UART << 4);

    /* Drop anything that is still waiting in the receiver */
    while (*UART1_RX_STATUS_ADDRESS & (1u << UART_RX_STATUS_IDX_FULL))
        (void)*UART1_BUFFER_ADDRESS;

    for (i = 0; i < sizeof(pattern); i++) {
        int got;

        uart1_put(pattern[i]);
        got = uart1_get(&rx);

        if (got && rx == pattern[i]) {
            good++;
            continue;
        }

        uart_puts("  byte 0x");
        uart_put_hex(i, 2);
        uart_puts(": sent 0x");
        uart_put_hex(pattern[i], 2);

        if (got) {
            uart_puts(", received 0x");
            uart_put_hex(rx, 2);
        } else {
            uart_puts(", nothing received");
        }
        uart_puts("\r\n");
    }

    uart_puts("UART1 bytes echoed: 0x");
    uart_put_hex(good, 2);
    uart_puts(" of 0x");
    uart_put_hex(sizeof(pattern), 2);
    uart_puts("\r\n");

    report("UART1 loopback", good == sizeof(pattern));

    if (failures) {
        uart_puts("RESULT: FAIL, check the pin 25 -> pin 26 jumper\r\n");
        *LEDS_ADDRESS = (uint16_t)~0x20u;
    } else {
        uart_puts("RESULT: PASS\r\n");
        *LEDS_ADDRESS = (uint16_t)~0x01u;
    }

    uart_puts("DEMO DONE\r\n");

    while (1)
        ;
}
