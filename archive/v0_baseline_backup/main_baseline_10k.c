/*
 * main.c — CNN Accelerator (Conv1+Conv2+Maxpool+FC) 제어 (MicroBlaze / Arty A7-100T)
 *
 *   ★★ phase-2 bitstream 기준 ★★
 *     - CSR STATUS : [0]done [1]can_load [15:2]img_cnt   (result 는 STATUS 에서 제거됨)
 *     - 결과       : output BRAM(bram_output, result_bram_axi @ 0xC800_0000)에 PL 이 누적
 *                    → 처리 종료 후 PS 가 일괄 read (word=4결과, byte k 의 low 4-bit = img 4w+k)
 *     - weight     : conv1/conv2/fc 전부 SIMD-packed 헤더 그대로 **direct write** (★ 변환 금지)
 *                    fcw 512b (16ch × 32b SIMD-A/word) — 32→512 upsizer 가 16개씩 packing
 *     - input      : test_images = pre-packed uint32 (gen 산출) → word 그대로 전송
 */
#include "xparameters.h"   /* XPAR_*_BASEADDR */
#include "xil_io.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include <stdint.h>

/* ===== Base addresses ===== */
#define CSR_BASE     0x44A00000U                    /* csr (BD inst=csr_axi_1) — 하드코딩(XPAR_CSR_AXI_0/_1 rename 회피) */
#define CONV1W_BASE  XPAR_C1W_BRAM_AXI_BASEADDR     /* 0xC000_0000 */
#define CONV2W_BASE  XPAR_C2W_BRAM_AXI_BASEADDR     /* 0xC200_0000 */
#define FCW_BASE     XPAR_FCW_BRAM_AXI_BASEADDR     /* 0xC400_0000 (512b) */
#define INPUT_BASE   XPAR_INPUT_BRAM_AXI_BASEADDR   /* 0xC600_0000 */
#define OUTPUT_BASE  0xC8000000U                    /* result_bram_axi (bram_output) — 하드코딩(XPAR 미정의 회피) */

/* ===== CSR register offsets ===== */
#define CSR_CTRL      0x0U   /* [0]enable(level) [1]start(pulse) [2]img_ready(pulse) */
#define CSR_STATUS    0x4U   /* [0]done [1]can_load [15:2]img_cnt (result→bram_output) */
#define CSR_TIMER_LO  0x8U
#define CSR_TIMER_HI  0xCU

/* CTRL bits */
#define CTRL_EN    0x1U
#define CTRL_ST    0x2U
#define CTRL_IMG   0x4U
/* STATUS decode (phase-2) */
#define ST_DONE(s)    ( (s)        & 0x1U)
#define ST_CANLOAD(s) (((s) >> 1)  & 0x1U)
#define ST_IMGCNT(s)  (((s) >> 2)  & 0x3FFFU)

/* ===== geometry ===== */
#define IN_WORDS    196U    /* 784 byte / 4 (input BRAM Port A words per image) */

/* ===== Data (C arrays) ===== */
#include "conv1_weights_simd.h"   /* conv1_weights_simd[36]   */
#include "conv2_weights_simd.h"   /* conv2_weights_simd[576]  */
#include "fc_weights_simd.h"      /* fc_weights_simd[11520]   (512b fcw 에 16개씩 direct) */
#include "test_images.h"          /* test_images[N*196] uint32 (pre-packed), test_labels[N], TEST_N_IMAGES */

#define N_IMAGES   TEST_N_IMAGES
#define POLL_GUARD 50000000U

static inline u32  csr_stat(void)  { return Xil_In32(CSR_BASE + CSR_STATUS); }
static inline void csr_ctrl(u32 v) { Xil_Out32(CSR_BASE + CSR_CTRL, v); }

/* ---- weight : SIMD-packed 헤더를 그대로 BRAM Port A 에 direct write (★ 변환 없음) ----
 *   conv1/conv2/fc 동일. fcw 는 512b 라 32→512 upsizer 가 16 × 32b → 512b word 로 묶음. */
static void write_weights(u32 base, const uint32_t *w, u32 n)
{
    for (u32 i = 0; i < n; i++)
        Xil_Out32(base + i * 4U, w[i]);
}

/* ---- 이미지 1장 ping-pong bank write (test_images = pre-packed uint32) ---- */
static void write_image(u32 img)
{
    u32 bank = img & 1U;                       /* bank = img index LSB (accel 내부 sync) */
    const uint32_t *p = &test_images[img * IN_WORDS];
    for (u32 i = 0; i < IN_WORDS; i++)
        /* word 주소: bank0 = 0..195, bank1 = 256..451 (MSB=bit8=bank) */
        Xil_Out32(INPUT_BASE + (bank * 256U + i) * 4U, p[i]);
}

int main(void)
{
    Xil_ICacheEnable();
    Xil_DCacheEnable();

    xil_printf("\r\n=== CNN Accelerator Test (phase-2, N=%u) ===\r\n", (unsigned)N_IMAGES);

    /* ---- 1. Weight 적재 (전부 SIMD-packed 그대로 direct, 변환 금지) ---- */
    xil_printf("[1] weights (direct): conv1=%u conv2=%u fc=%u\r\n",
               (unsigned)CONV1_WEIGHTS_SIMD_LEN, (unsigned)CONV2_WEIGHTS_SIMD_LEN,
               (unsigned)FC_WEIGHTS_SIMD_LEN);
    write_weights(CONV1W_BASE, conv1_weights_simd, CONV1_WEIGHTS_SIMD_LEN);
    write_weights(CONV2W_BASE, conv2_weights_simd, CONV2_WEIGHTS_SIMD_LEN);
    write_weights(FCW_BASE,    fc_weights_simd,    FC_WEIGHTS_SIMD_LEN);

    /* ---- 2. enable → start ---- */
    xil_printf("[2] enable + start\r\n");
    csr_ctrl(CTRL_EN);
    csr_ctrl(CTRL_EN | CTRL_ST);

    /* ---- 3. 이미지 루프: can_load(bit1) → input write → img_ready → img_cnt(bit2) 증가 대기.
     *        result 는 STATUS 에 없음 — bram_output 에 누적 (루프 후 [4] 일괄 read) ---- */
    xil_printf("[3] %u images (can_load-paced, inter-image pipelined)...\r\n", (unsigned)N_IMAGES);
    u32 prev_cnt = 0;
    u32 t_write = 0, t_canload = 0;            /* [profile] PS write vs can_load(=conv1 소비) 대기 */
    for (u32 img = 0; img < N_IMAGES; img++) {
        u32 s, guard, ta, tb;

        /* ★ can_load 만 본다 — conv1 이 이전 bank 를 소비(input_consumed)해 빈 bank 가 생기면 바로 적재.
         *   FC 완료(img_cnt)는 기다리지 않음 → downstream 은 stage 간 ping-pong 으로 overlap (inter-image pipeline).
         *   결과는 output BRAM 에 자동 누적되므로 per-image 회수 불필요. */
        ta = Xil_In32(CSR_BASE + CSR_TIMER_LO);
        guard = 0;
        do { s = csr_stat(); } while (!ST_CANLOAD(s) && ++guard < POLL_GUARD);
        tb = Xil_In32(CSR_BASE + CSR_TIMER_LO);
        t_canload += tb - ta;
        if (guard >= POLL_GUARD) {
            xil_printf("  [TIMEOUT] can_load @img %u STATUS=0x%08x\r\n", (unsigned)img, (unsigned)s);
            break;
        }

        /* 빈 bank(img&1) 에 이미지 write + img_ready pulse */
        ta = Xil_In32(CSR_BASE + CSR_TIMER_LO);
        write_image(img);                      /* 196 word 전송 */
        csr_ctrl(CTRL_EN | CTRL_IMG);          /* img_ready pulse → inflight++ */
        tb = Xil_In32(CSR_BASE + CSR_TIMER_LO);
        t_write += tb - ta;

        if ((img & 0x3FFU) == 0U)              /* 1024 장마다 liveness */
            xil_printf("  ... %u/%u\r\n", (unsigned)(img + 1U), (unsigned)N_IMAGES);
    }

    /* 마지막 적재분(파이프라인 in-flight)이 전부 완료될 때까지 drain — img_cnt == N 대기 */
    {
        u32 s, guard = 0;
        do { s = csr_stat(); } while (ST_IMGCNT(s) < N_IMAGES && ++guard < POLL_GUARD);
        prev_cnt = ST_IMGCNT(s);
        if (guard >= POLL_GUARD)
            xil_printf("  [TIMEOUT] drain img_cnt=%u/%u STATUS=0x%08x\r\n",
                       (unsigned)prev_cnt, (unsigned)N_IMAGES, (unsigned)s);
    }

    /* ---- 4. 결과 수집 : output BRAM(0xC800_0000) 일괄 read → test_labels 비교 ----
     *   word w = image 4w..4w+3 의 result (byte k 의 low 4-bit = digit). uncached MMIO. */
    u32 matched = 0;
    for (u32 w = 0; w < (prev_cnt + 3U) / 4U; w++) {
        u32 word = Xil_In32(OUTPUT_BASE + w * 4U);
        for (u32 k = 0; k < 4U; k++) {
            u32 img = w * 4U + k;
            if (img < prev_cnt) {
                u32 r = (word >> (k * 8U)) & 0xFU;
                if (r == test_labels[img]) matched++;
                if (img < 8U || r != test_labels[img])     /* 앞 8장 + 오답만 출력 */
                    xil_printf("  img %3u: result=%u exp=%u %s\r\n",
                               (unsigned)img, (unsigned)r, (unsigned)test_labels[img],
                               (r == test_labels[img]) ? "OK" : "X");
            }
        }
    }

    /* ---- 5. 결과 + latency (48-bit timer; N<10000 이면 미정지 → snapshot) ---- */
    u32 t_lo = Xil_In32(CSR_BASE + CSR_TIMER_LO);
    u32 t_hi = Xil_In32(CSR_BASE + CSR_TIMER_HI) & 0xFFFFU;
    u32 us   = (t_hi == 0U) ? (t_lo / 100U) : 0xFFFFFFFFU;

    xil_printf("\r\n=== Result ===\r\n");
    xil_printf("class match : %u / %u\r\n", (unsigned)matched, (unsigned)prev_cnt);
    xil_printf("latency     : %u cyc (hi=%u) ~%u us @100MHz%s\r\n",
               (unsigned)t_lo, (unsigned)t_hi, (unsigned)us,
               (N_IMAGES == 10000U) ? "" : " [snapshot]");
    /* [profile] PS image-write vs can_load(=conv1 소비율) 대기 분해 (잔여 병목 판단용) */
    u32 denom = (t_lo >= 100U) ? (t_lo / 100U) : 1U;        /* %p 계산 (u64 회피) */
    xil_printf("profile     : t_write=%u cyc (%u%%)  t_canload=%u cyc (%u%%)\r\n",
               (unsigned)t_write,   (unsigned)(t_write   / denom),
               (unsigned)t_canload, (unsigned)(t_canload / denom));
    xil_printf("              -> t_write 크면 PS전송 병목(=DMA 효과) / t_canload 크면 conv1 소비율 한계(300MHz)\r\n");

    return 0;
}
