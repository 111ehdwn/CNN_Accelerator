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
 *
 *   ★ 듀얼클럭(overclock): 가속기 datapath(conv1/2·maxpool·fc) = clk_out3 (주파수는 clk_wiz/BD
 *     에서 설정 — firmware 는 모름·무관), PS/AXI/CSR/CDMA = clk_out1 100MHz. firmware 무변경.
 *   ★ latency timer(CSR 0x08/0x0C)는 clk_out1 100MHz 도메인 = wall-clock. us = cyc/100 (정확).
 *   ※ 아래 profile(t_write/t_canload)은 'PS 가 어디서 시간을 쓰나'의 단순 분해(PS-busy)일 뿐,
 *     HW 병목 판정 아님(overlap/pipeline 미반영).
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
#define INPUT_BASE   0xC6000000U                    /* input BRAM — 하드코딩 (A: input이 ram_interconnect로 이동→MB xparameters 미정의) */
#define OUTPUT_BASE  0xC8000000U                    /* result_bram_axi (bram_output) — 하드코딩 */

/* ===== AXI CDMA (input 이미지 전송: DDR test_images → input BRAM) ===== */
#define CDMA_BASE    0x44A10000U                    /* axi_cdma_0/S_AXI_LITE */
#define CDMA_CR      0x00U                          /* control; bit2=Reset(self-clear) */
#define CDMA_SR      0x04U                          /* status;  bit1=Idle */
#define CDMA_SA      0x18U                          /* source addr (DDR) */
#define CDMA_DA      0x20U                          /* dest addr (input BRAM) */
#define CDMA_BTT     0x28U                          /* bytes-to-transfer (write가 transfer 트리거) */

/* ===== CSR register offsets ===== */
#define CSR_CTRL      0x0U   /* [0]enable(level) [1]start(pulse) [2]img_ready(pulse) */
#define CSR_STATUS    0x4U   /* [0]done [1]can_load [15:2]img_cnt (result→bram_output) */
#define CSR_TIMER_LO  0x8U
#define CSR_TIMER_HI  0xCU

/* ★ 진단 플래그: 1 이면 이미지 CDMA 전송량을 784B→16B 로 줄임 (CDMA 자체는 계속 돌려
 *   spacing/handshake 유지 → skip 방식의 hang 회피). 전송시간(t_write)이 ~549→~350 으로
 *   줄어드는 만큼만 latency 가 빠지면 = 그 부분이 feed 비용. (skip 만큼 깨끗하진 않음.)
 *   firmware-only: 비트스트림 그대로, ELF 만 재빌드. 측정 후 0 으로 되돌릴 것.
 *   ※ 더 깨끗한 비교: '오버클럭 없는(100MHz) DMA 버전' latency 와 오버클럭(0.188s) 비교. */
#define FEED_TEST  0

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

/* ---- AXI CDMA Simple-mode transfer (DDR src → input BRAM dst, blocking) ---- */
static inline void cdma_xfer(u32 src, u32 dst, u32 bytes)
{
    while (!(Xil_In32(CDMA_BASE + CDMA_SR) & 0x2U)) ;   /* wait Idle */
    Xil_Out32(CDMA_BASE + CDMA_SA, src);
    Xil_Out32(CDMA_BASE + CDMA_DA, dst);
    Xil_Out32(CDMA_BASE + CDMA_BTT, bytes);             /* write BTT → transfer 시작 */
    while (!(Xil_In32(CDMA_BASE + CDMA_SR) & 0x2U)) ;   /* wait done(Idle) */
}

/* ---- 이미지 1장 ping-pong bank write — CDMA burst (196 Xil_Out32 대체) ----
 *   src = DDR 의 test_images[img] (const→.rodata→DDR), dst = input BRAM bank.
 *   word 주소: bank0 = word 0..195, bank1 = word 256..451 (MSB=bit8=bank). */
static void write_image(u32 img)
{
    u32 bank = img & 1U;
    cdma_xfer((u32)(UINTPTR)&test_images[img * IN_WORDS],   /* DDR source */
              INPUT_BASE + bank * 256U * 4U,                /* input BRAM bank dst */
              FEED_TEST ? 16U : (IN_WORDS * 4U));           /* 784B; FEED_TEST 면 16B (전송비용 최소, CDMA spacing 유지) */
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

    /* ---- 2. enable → start + CDMA reset ---- */
    xil_printf("[2] enable + start\r\n");
    csr_ctrl(CTRL_EN);
    csr_ctrl(CTRL_EN | CTRL_ST);

    /* CDMA soft-reset → idle 보장 (Simple mode; reset bit self-clear) */
    Xil_Out32(CDMA_BASE + CDMA_CR, 0x4U);
    while (Xil_In32(CDMA_BASE + CDMA_CR) & 0x4U) ;

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
        write_image(img);                      /* FEED_TEST=1 이면 내부에서 16B 만 전송(CDMA·spacing 유지, hang 회피) */
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
    /* timer = CSR(clk_out1 100MHz) wall-clock 카운터. us = cyc/100 (정확).
     * 가속기 클럭(clk_out3)이 빠를수록 같은 work 가 더 적은 timer cyc 에 끝남. */
    u32 t_lo = Xil_In32(CSR_BASE + CSR_TIMER_LO);
    u32 t_hi = Xil_In32(CSR_BASE + CSR_TIMER_HI) & 0xFFFFU;
    u32 us   = (t_hi == 0U) ? (t_lo / 100U) : 0xFFFFFFFFU;

    xil_printf("\r\n=== Result ===\r\n");
#if FEED_TEST
    xil_printf("[FEED_TEST] CDMA = 16B only (data garbage, class match 무의미). latency 만 참고.\r\n");
#endif
    xil_printf("class match : %u / %u\r\n", (unsigned)matched, (unsigned)prev_cnt);
    xil_printf("latency     : %u cyc ~%u us wall-clock  [100MHz timer]%s\r\n",
               (unsigned)t_lo, (unsigned)us,
               (N_IMAGES == 10000U) ? "" : " [snapshot]");
    if (t_hi != 0U)
        xil_printf("              (timer 48-bit hi=%u - overflow / not stopped)\r\n", (unsigned)t_hi);
    /* ★ 'PS 가 어디서 시간을 쓰나'의 단순 분해(PS-busy)일 뿐 — HW 병목 판정 아님. */
    u32 denom = (t_lo >= 100U) ? (t_lo / 100U) : 1U;       /* % 계산 (u64 회피) */
    u32 pw = t_write   / denom;                            /* PS 가 blocking CDMA 안에 있던 비중 */
    u32 pc = t_canload / denom;                            /* PS 가 can_load(빈 bank) 기다린 비중 */
    xil_printf("PS time     : in-CDMA(blocking) %u%% (%u cyc)   waiting-can_load %u%% (%u cyc)\r\n",
               (unsigned)pw, (unsigned)t_write, (unsigned)pc, (unsigned)t_canload);

    return 0;
}
