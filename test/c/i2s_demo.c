/* File: i2s_demo.c
 *
 * I2S transmitter demonstration on GPIOC[2:0] (16-bit stereo, MSB first).
 *
 *   GPIOC[0] = BCLK (bit clock)     Tang Nano 9K pin 70
 *   GPIOC[1] = LRCLK (word select)  Tang Nano 9K pin 71
 *   GPIOC[2] = SD (serial data)     Tang Nano 9K pin 72
 *
 * Wiring: connect the three pins to an I2S DAC or amplifier (for example
 * PCM5102 or MAX98357A). The sample rate is clk / 320, about 28.1 kHz at 9 MHz.
 *
 * 1. Loads a known 8-frame test pattern into the transmit FIFO, enables the
 *    transmitter and checks that the FIFO drains. The pattern is
 *    left = 0xA500 + n, right = 0x5A00 + n for n = 0 - 7 (the simulation
 *    testbench decodes the serial stream and compares it with this pattern).
 * 2. Plays a 439 Hz sine tone at a quarter of full scale, forever.
 *
 * The result is printed on UART0 (USB serial, 115200 baud) and shown on the
 * LEDs (active-low): LED0 on = pass, LED5 on = fail.
 */

#include <stdint.h>
#include "peripherals.h"

#define SYS_CLK_HZ      9000000UL
#define TICKS_PER_MS    (SYS_CLK_HZ / 1000UL)
#define TIMEOUT_TICKS   (20UL * TICKS_PER_MS)

#define FUNC_I2S        0x4u

#define I2S_CTRL_EN     (1u << 0)
#define I2S_ST_EMPTY    (1u << 7)
#define I2S_ST_FULL     (1u << 8)
#define I2S_ST_COUNT(s) (((s) >> 9) & 0x1Fu)

#define PAT_FRAMES      8u
#define PAT_LEFT(n)     (0xA500u + (n))
#define PAT_RIGHT(n)    (0x5A00u + (n))

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

static void delay_ms(uint32_t ms)
{
    uint64_t start = timer_get();

    while ((timer_get() - start) < (ms * TICKS_PER_MS))
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
 * I2S
 * -------------------------------------------------------------------------- */

/* The right sample write pushes the {left, right} pair into the FIFO */
static void i2s_put(uint16_t left, uint16_t right)
{
    *I2S_LEFT_CHN_ADDRESS  = left;
    *I2S_RIGHT_CHN_ADDRESS = right;
}

static const int16_t sine[64] = {
        0,    803,   1598,   2378,   3135,   3862,   4551,   5197,
     5793,   6333,   6811,   7225,   7568,   7839,   8035,   8153,
     8192,   8153,   8035,   7839,   7568,   7225,   6811,   6333,
     5793,   5197,   4551,   3862,   3135,   2378,   1598,    803,
        0,   -803,  -1598,  -2378,  -3135,  -3862,  -4551,  -5197,
    -5793,  -6333,  -6811,  -7225,  -7568,  -7839,  -8035,  -8153,
    -8192,  -8153,  -8035,  -7839,  -7568,  -7225,  -6811,  -6333,
    -5793,  -5197,  -4551,  -3862,  -3135,  -2378,  -1598,   -803
};


/* --------------------------------------------------------------------------
 * Demo
 * -------------------------------------------------------------------------- */

int main(void)
{
    unsigned n;
    uint32_t status;
    uint64_t start;
    int      drained;

    failures = 0;

    uart_puts("\r\nI2S DEMO\r\n");
    uart_puts("I2S: BCLK = GPIOC[0] (pin 70), LRCLK = GPIOC[1] (pin 71), SD = GPIOC[2] (pin 72)\r\n");

    /* GPIOC[2:0] -> I2S; FUNC0 covers GPIOC[3:0], leave pin 3 alone */
    *GPIOC_FUNC0_ADDRESS = (*GPIOC_FUNC0_ADDRESS & ~0x0FFFu)
                         | (FUNC_I2S << 0)
                         | (FUNC_I2S << 4)
                         | (FUNC_I2S << 8);

    /* Load the test pattern while the transmitter is still disabled */
    *I2S_CTRL_ADDRESS = 0;
    for (n = 0; n < PAT_FRAMES; n++)
        i2s_put((uint16_t)PAT_LEFT(n), (uint16_t)PAT_RIGHT(n));

    status = *I2S_STATUS_ADDRESS;
    uart_puts("FIFO count before start: 0x");
    uart_put_hex(I2S_ST_COUNT(status), 2);
    uart_puts("\r\n");
    report("I2S FIFO holds the test pattern",
           I2S_ST_COUNT(status) == PAT_FRAMES && !(status & I2S_ST_EMPTY));

    *I2S_CTRL_ADDRESS = I2S_CTRL_EN;
    report("I2S transmitter enabled", (*I2S_CTRL_ADDRESS & I2S_CTRL_EN) != 0);

    start = timer_get();
    drained = 0;
    while (!drained && (timer_get() - start) < TIMEOUT_TICKS)
        drained = (*I2S_STATUS_ADDRESS & I2S_ST_EMPTY) != 0;
    report("I2S FIFO drained", drained);

    /* Let the frame that was loaded last finish on the wire */
    delay_ms(1);

    if (failures) {
        uart_puts("RESULT: FAIL\r\n");
        *LEDS_ADDRESS = (uint16_t)~0x20u;
    } else {
        uart_puts("RESULT: PASS\r\n");
        *LEDS_ADDRESS = (uint16_t)~0x01u;
    }

    uart_puts("DEMO DONE\r\n");

    /* Tone: keep the FIFO fed with one sine period every 64 frames */
    for (n = 0; ; n = (n + 1) & 63u) {
        while (*I2S_STATUS_ADDRESS & I2S_ST_FULL)
            ;
        i2s_put((uint16_t)sine[n], (uint16_t)sine[n]);
    }
}
