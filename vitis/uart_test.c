/*
 * ddr_uart_test.c - Arty A7-100T CNN accelerator bring-up test (v2)
 *
 * v2 prints CONTINUOUSLY so the serial terminal can't miss a one-shot
 * boot message. It also emits an immediate "UART alive" heartbeat before
 * touching DDR, so we can tell apart two failure modes:
 *
 *   - You DON'T even see "UART alive" -> UART TX is not reaching the FTDI
 *     pins (BD/xdc connection problem in Vivado), or baud/stdout wrong.
 *   - You DO see "UART alive" but no PASS -> UART path is fine; look at DDR.
 *
 * DDR base (Vivado Address Editor): 0x80000000, 256 MB.
 */

#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_types.h"

#define DDR_BASE        0x80000000U
#define DDR_TEST_BASE   (DDR_BASE + 0x08000000U)   /* 128 MB in, clear of code */
#define TEST_WORDS      4096U
#define HEARTBEAT_DELAY 20000000U                  /* crude busy-wait ~sub-second */

typedef u32 (*pat_fn)(u32 i);

static u32 pat_incr(u32 i) { return i; }
static u32 pat_addr(u32 i) { return DDR_TEST_BASE + i * 4U; }
static u32 pat_aa  (u32 i) { (void)i; return 0xAAAAAAAAU; }
static u32 pat_55  (u32 i) { (void)i; return 0x55555555U; }
static u32 pat_walk(u32 i) { return 1U << (i & 31U); }

static int run_test(volatile u32 *base, u32 n, pat_fn gen, const char *name)
{
    u32 i;
    for (i = 0; i < n; i++) base[i] = gen(i);

    Xil_DCacheFlushRange((UINTPTR)base, n * sizeof(u32));
    Xil_DCacheInvalidateRange((UINTPTR)base, n * sizeof(u32));

    for (i = 0; i < n; i++) {
        u32 exp = gen(i), got = base[i];
        if (got != exp) {
            xil_printf("  [FAIL] %s @ word %u: wrote 0x%08X read 0x%08X\r\n",
                       name, i, exp, got);
            return 1;
        }
    }
    xil_printf("  [PASS] %s\r\n", name);
    return 0;
}

int main(void)
{
    volatile u32 *ddr = (volatile u32 *)DDR_TEST_BASE;
    int fails = 0;
    u32 beat = 0, k;

    /* Immediate, repeated heartbeat - decoupled from DDR entirely. */
    for (k = 0; k < 5; k++) xil_printf("UART alive %u\r\n", k);

    xil_printf("\r\n==== Arty A7 CNN bring-up : DDR + UART test ====\r\n");
    xil_printf("DDR test region : 0x%08X (%u words)\r\n",
               DDR_TEST_BASE, TEST_WORDS);

    fails += run_test(ddr, TEST_WORDS, pat_incr, "incrementing");
    fails += run_test(ddr, TEST_WORDS, pat_addr, "address-as-data");
    fails += run_test(ddr, TEST_WORDS, pat_aa,   "0xAAAAAAAA");
    fails += run_test(ddr, TEST_WORDS, pat_55,   "0x55555555");
    fails += run_test(ddr, TEST_WORDS, pat_walk, "walking-1");

    /* Report forever so the terminal always catches it. */
    while (1) {
        if (fails == 0)
            xil_printf("[%u] ALL PASS : DDR / UART / MIG OK\r\n", beat++);
        else
            xil_printf("[%u] %d TEST(S) FAILED\r\n", beat++, fails);

        for (volatile u32 d = 0; d < HEARTBEAT_DELAY; d++) { }
    }
    return 0;
}