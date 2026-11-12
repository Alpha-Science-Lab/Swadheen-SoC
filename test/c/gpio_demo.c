/* File: gpio_demo.c
 *
 * GPIO ports B and C demonstration: push-pull outputs, pad readback and
 * inputs.
 *
 *   GPIOB[7:4]  push-pull outputs   (Tang Nano 9K pins 63, 57, 68, 69)
 *   GPIOC[7:4]  inputs              (Tang Nano 9K pins 74, 75, 76, 77)
 *
 * The output readback test needs no wiring. For the input test jumper
 * B4 -> C4 (63 -> 74), B5 -> C5 (57 -> 75), B6 -> C6 (68 -> 76) and
 * B7 -> C7 (69 -> 77).
 *
 * The result is printed on UART0 (USB serial, 115200 baud) and shown on the
 * LEDs (active-low): LED0 on = pass, LED5 on = fail.
 */

#include <stdint.h>
#include "peripherals.h"

#define SYS_CLK_HZ      9000000UL
#define TICKS_PER_US    (SYS_CLK_HZ / 1000000UL)

#define PIN_SHIFT       4u
#define PIN_MASK        0xFu

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

static void delay_us(uint32_t us)
{
    uint64_t start = timer_get();

    while ((timer_get() - start) < (us * TICKS_PER_US))
        ;
}

static void report(const char *name, int ok)
{
    uart_puts(name);
    uart_puts(ok ? ": PASS\r\n" : ": FAIL\r\n");

    if (!ok)
        failures++;
}


/* --------------------------------------------------------------------------
 * Demo
 * -------------------------------------------------------------------------- */

static const uint8_t patterns[] = { 0x1, 0x2, 0x4, 0x8, 0xF, 0x0, 0xA, 0x5 };

int main(void)
{
    unsigned i;
    unsigned out_ok  = 0;
    unsigned loop_ok = 0;

    failures = 0;

    uart_puts("\r\nGPIO DEMO\r\n");
    uart_puts("GPIOB[7:4] = outputs, GPIOC[7:4] = inputs\r\n");

    /* FUNC1 covers pins 7:4 of a port, 0 = plain GPIO */
    *GPIOB_FUNC1_ADDRESS = 0;
    *GPIOC_FUNC1_ADDRESS = 0;

    /* MODE has two bits per pin: 00 = input, 01 = push-pull output */
    *GPIOB_MODE_ADDRESS = (*GPIOB_MODE_ADDRESS & ~0xFF00u) | 0x5500u;
    *GPIOC_MODE_ADDRESS = (*GPIOC_MODE_ADDRESS & ~0xFF00u);

    *GPIOB_OUTPUT_ADDRESS = 0;

    for (i = 0; i < sizeof(patterns); i++) {
        uint32_t out = patterns[i];
        uint32_t rd_b, rd_c;

        *GPIOB_OUTPUT_ADDRESS = out << PIN_SHIFT;
        delay_us(100);

        rd_b = (*GPIOB_DATA_ADDRESS >> PIN_SHIFT) & PIN_MASK;
        rd_c = (*GPIOC_DATA_ADDRESS >> PIN_SHIFT) & PIN_MASK;

        uart_puts("  B out=0x");
        uart_put_hex(out, 1);
        uart_puts(" B read=0x");
        uart_put_hex(rd_b, 1);
        uart_puts(" C read=0x");
        uart_put_hex(rd_c, 1);
        uart_puts("\r\n");

        if (rd_b == out)
            out_ok++;
        if (rd_c == out)
            loop_ok++;
    }

    report("GPIOB output readback", out_ok == sizeof(patterns));
    report("GPIOB -> GPIOC input", loop_ok == sizeof(patterns));

    if (failures) {
        uart_puts("RESULT: FAIL, the input test needs jumpers B[7:4] -> C[7:4]\r\n");
        *LEDS_ADDRESS = (uint16_t)~0x20u;
    } else {
        uart_puts("RESULT: PASS\r\n");
        *LEDS_ADDRESS = (uint16_t)~0x01u;
    }

    uart_puts("DEMO DONE\r\n");

    while (1)
        ;
}
