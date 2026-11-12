/* File: spi_demo.c
 *
 * SPI master demonstration (SPI1 on GPIOB[3:0]) with a MOSI -> MISO loopback.
 *
 *   GPIOB[0] = MOSI  (Tang Nano 9K pin 51)
 *   GPIOB[1] = SCK   (Tang Nano 9K pin 53)
 *   GPIOB[2] = CS    (Tang Nano 9K pin 49, chip select 2 of the SPI master)
 *   GPIOB[3] = MISO  (Tang Nano 9K pin 48)
 *
 * Wiring: jumper pin 51 (MOSI) to pin 48 (MISO). For a real SPI device
 * connect MOSI, SCK, CS and MISO to the device instead and replace the
 * loopback check with the device protocol.
 *
 * Runs SPI mode 0 and mode 3: checks the SCK idle level, the CS pad, single
 * byte transfers and a burst through the hardware FIFOs.
 *
 * The result is printed on UART0 (USB serial, 115200 baud) and shown on the
 * LEDs (active-low): LED0 on = pass, LED5 on = fail.
 */

#include <stdint.h>
#include "peripherals.h"

#define SYS_CLK_HZ      9000000UL
#define TICKS_PER_MS    (SYS_CLK_HZ / 1000UL)
#define TICKS_PER_US    (SYS_CLK_HZ / 1000000UL)
#define TIMEOUT_TICKS   (10UL * TICKS_PER_MS)

#define FUNC_SPI        0x3u

#define SPI_CTRL_EN     (1u << 0)
#define SPI_CTRL_CPOL   (1u << 1)
#define SPI_CTRL_CPHA   (1u << 2)

#define SPI_ST_BUSY     (1u << 0)
#define SPI_ST_TX_FULL  (1u << 1)
#define SPI_ST_RX_EMPTY (1u << 4)

#define SPI_PRESCALER   4u      /* SCK = clk / (2 * (prescaler + 1)) */
#define SPI_CS_SLAVE2   0xBu    /* chip selects are active-low, slave 2 = GPIOB[2] */
#define SPI_CS_NONE     0xFu

#define PAD_SCK         (1u << 1)
#define PAD_CS          (1u << 2)

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

static int timed_out(uint64_t start)
{
    return (timer_get() - start) > TIMEOUT_TICKS;
}

static void report(const char *name, int ok)
{
    uart_puts(name);
    uart_puts(ok ? ": PASS\r\n" : ": FAIL\r\n");

    if (!ok)
        failures++;
}


/* --------------------------------------------------------------------------
 * SPI
 * -------------------------------------------------------------------------- */

/* Shift one byte out and read the byte shifted in. Returns 0 on timeout. */
static int spi_xfer(uint8_t tx, uint8_t *rx)
{
    uint64_t start = timer_get();

    while (*SPI_STATUS_ADDRESS & SPI_ST_TX_FULL) {
        if (timed_out(start))
            return 0;
    }

    *SPI_DATA_ADDRESS = tx;

    start = timer_get();
    while (*SPI_STATUS_ADDRESS & SPI_ST_RX_EMPTY) {
        if (timed_out(start))
            return 0;
    }

    *rx = (uint8_t)*SPI_DATA_ADDRESS;
    return 1;
}

/* Queue n bytes (n <= 16, the TX FIFO depth), then collect the n replies */
static int spi_burst(const uint8_t *tx, uint8_t *rx, unsigned n)
{
    unsigned i;
    uint64_t start;

    for (i = 0; i < n; i++)
        *SPI_DATA_ADDRESS = tx[i];

    start = timer_get();
    for (i = 0; i < n; i++) {
        while (*SPI_STATUS_ADDRESS & SPI_ST_RX_EMPTY) {
            if (timed_out(start))
                return 0;
        }
        rx[i] = (uint8_t)*SPI_DATA_ADDRESS;
    }

    return 1;
}


/* --------------------------------------------------------------------------
 * Demo
 * -------------------------------------------------------------------------- */

static const uint8_t test_bytes[] = { 0xA5, 0x3C, 0xFF, 0x00, 0x5A, 0x81, 0x7E, 0x18 };

static void run_mode(unsigned mode)
{
    uint32_t ctrl = SPI_CTRL_EN;
    unsigned idle_high = (mode == 3);
    unsigned i;
    unsigned good;
    uint8_t  rx[sizeof(test_bytes)];
    int      ok;

    if (idle_high)
        ctrl |= SPI_CTRL_CPOL | SPI_CTRL_CPHA;

    uart_puts(idle_high ? "SPI mode 3\r\n" : "SPI mode 0\r\n");

    *SPI_CS_ADDRESS   = SPI_CS_NONE;
    *SPI_CTRL_ADDRESS = ctrl;
    delay_us(10);

    report(idle_high ? "  SCK idles high" : "  SCK idles low",
           ((*GPIOB_DATA_ADDRESS & PAD_SCK) != 0) == idle_high);

    *SPI_CS_ADDRESS = SPI_CS_SLAVE2;
    delay_us(10);
    report("  CS pad low while selected", (*GPIOB_DATA_ADDRESS & PAD_CS) == 0);

    /* One byte at a time */
    good = 0;
    for (i = 0; i < sizeof(test_bytes); i++) {
        uint8_t r = 0;

        ok = spi_xfer(test_bytes[i], &r);
        if (ok && r == test_bytes[i]) {
            good++;
        } else {
            uart_puts("    sent 0x");
            uart_put_hex(test_bytes[i], 2);
            uart_puts(ok ? ", received 0x" : ", timeout, last 0x");
            uart_put_hex(r, 2);
            uart_puts("\r\n");
        }
    }
    report("  byte loopback", good == sizeof(test_bytes));

    /* Burst through the FIFOs */
    ok = spi_burst(test_bytes, rx, sizeof(test_bytes));
    good = 0;
    for (i = 0; ok && i < sizeof(test_bytes); i++) {
        if (rx[i] == test_bytes[i])
            good++;
    }
    report("  FIFO burst loopback", ok && good == sizeof(test_bytes));

    /* Wait for the engine to go idle before releasing the chip select */
    {
        uint64_t start = timer_get();
        while ((*SPI_STATUS_ADDRESS & SPI_ST_BUSY) && !timed_out(start))
            ;
    }
    *SPI_CS_ADDRESS = SPI_CS_NONE;
}

int main(void)
{
    failures = 0;

    uart_puts("\r\nSPI DEMO\r\n");
    uart_puts("SPI1: MOSI pin 51, SCK pin 53, CS pin 49, MISO pin 48\r\n");

    /* GPIOB[3:0] -> SPI1 (MOSI, SCK, CS, MISO) */
    *GPIOB_FUNC0_ADDRESS = (FUNC_SPI << 0) | (FUNC_SPI << 4)
                         | (FUNC_SPI << 8) | (FUNC_SPI << 12);

    *SPI_PRESCALER_ADDRESS = SPI_PRESCALER;

    run_mode(0);
    run_mode(3);

    if (failures) {
        uart_puts("RESULT: FAIL, check the pin 51 -> pin 48 jumper\r\n");
        *LEDS_ADDRESS = (uint16_t)~0x20u;
    } else {
        uart_puts("RESULT: PASS\r\n");
        *LEDS_ADDRESS = (uint16_t)~0x01u;
    }

    uart_puts("DEMO DONE\r\n");

    while (1)
        ;
}
