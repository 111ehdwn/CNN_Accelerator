/*
 * main.c — CNN Accelerator (Conv1+Conv2+Maxpool+FC) 제어 (MicroBlaze / Arty A7-100T)
 *
 *   PS(MicroBlaze) ── AXI4-Lite ── CSR(csr_axi)              : enable/start/img_ready, status/timer
 *                  ── AXI BRAM Ctrl ── c1w/c2w/fcw/input BRAM : weight·image 적재
 *
 *   RTL 확정 사실:
 *     (b) input bank 토글 = accelerator 내부 input_bank_sel (conv1 rdone 마다 toggle).
 *         PS 는 word 주소 MSB 로 bank=img&1 에 write → reset 후 자동 sync.
 *     (c) fc weight 는 SIMD-packed 헤더(fc_weights_simd[11520]) → fc_weight_bram 은
 *         raw {odd16,even16} (720×8=5760 word) 를 받으므로 PS 가 변환해서 write
 *         (fc_write_weights, TB load_fcw 와 동일). conv1/conv2 는 SIMD-packed 직접 write.
 *     (e) start 후 weight-load 대기 불필요 (conv2/fc handshake race-free).
 *
 *   헤더 (Vitis app 의 src/ 또는 include path 에 둘 것):
 *     conv1_weights_simd.h / conv2_weights_simd.h / fc_weights_simd.h  (data/weights_simd/)
 *     test_images.h                                                    (vitis/, gen script 산출)
 */
#include "xparameters.h"   /* XPAR_*_BASEADDR (Vitis SDT/BSP 생성) */
#include "xil_io.h"        /* Xil_In32 / Xil_Out32, u32/u64/u8 */
#include "xil_printf.h"    /* xil_printf (stdout = uartlite) */
#include <stdint.h>

/* ===== Base addresses (xparameters.h 의 AXI peripheral base) ===== */
#define CSR_BASE     XPAR_CSR_AXI_0_BASEADDR        /* 0x44A0_0000 */
#define CONV1W_BASE  XPAR_C1W_BRAM_AXI_BASEADDR     /* 0xC000_0000 */
#define CONV2W_BASE  XPAR_C2W_BRAM_AXI_BASEADDR     /* 0xC200_0000 */
#define FCW_BASE     XPAR_FCW_BRAM_AXI_BASEADDR     /* 0xC400_0000 */
#define INPUT_BASE   XPAR_INPUT_BRAM_AXI_BASEADDR   /* 0xC600_0000 */

/* ===== CSR register offsets ===== */
#define CSR_CTRL      0x0U   /* [0]enable(level) [1]start(pulse) [2]img_ready(pulse) */
#define CSR_STATUS    0x4U   /* [0]done [1]can_load [15:2]img_cnt (result→bram_output) */
#define CSR_TIMER_LO  0x8U
#define CSR_TIMER_HI  0xCU

/* CTRL bits */
#define CTRL_EN    0x1U
#define CTRL_ST    0x2U
#define CTRL_IMG   0x4U
/* STATUS decode */
#define ST_DONE(s)    ( (s)        & 0x1U)
#define ST_CANLOAD(s) (((s) >> 1)  & 0x1U)
#define ST_IMGCNT(s)  (((s) >> 2)  & 0x3FFFU)
/* result 는 STATUS 에서 제거 — bram_output(전용 AXI BRAM Ctrl, 0xC800_0000, 작업순서 2)에서 read */

/* ===== Weight / input geometry ===== */
#define IN_WORDS    196U    /* 784 byte / 4 (input BRAM Port A words per image) */
#define FC_PAIRS    5U
#define FC_SPATIAL  144U
#define FC_CHANS    16U

/* ===== Data (C arrays) ===== */
#include "conv1_weights_simd.h"   /* conv1_weights_simd[36]    (직접 write) */
#include "conv2_weights_simd.h"   /* conv2_weights_simd[576]   (직접 write) */
#include "fc_weights_simd.h"      /* fc_weights_simd[11520]    (변환 후 write) */
#include "test_images.h"          /* test_images[N*196] uint32 (pre-packed), test_labels[N], TEST_N_IMAGES */

#define N_IMAGES   TEST_N_IMAGES
#define POLL_GUARD 50000000U      /* 무한 hang 방지 (이 횟수 넘으면 STATUS 덤프 후 중단) */

static inline u32  csr_stat(void)  { return Xil_In32(CSR_BASE + CSR_STATUS); }
static inline void csr_ctrl(u32 v) { Xil_Out32(CSR_BASE + CSR_CTRL, v); }

/* ---- conv1/conv2 weight : SIMD-packed 32b 그대로 BRAM Port A 에 write ---- */
static void write_simd_weights(u32 base, const uint32_t *w, u32 n)
{
    for (u32 i = 0; i < n; i++)
        Xil_Out32(base + i * 4U, w[i]);
}

/* ---- fc weight : SIMD(W1·2^17+W0, 11520) → raw {odd16,even16} (720×8 word) 변환 write ----
 *   per (pair,s): 16ch unpack → even=W0=simd[7:0], odd=W1=simd[24:17]+simd[16](carry).
 *   256-bit entry = {odd[15..0], even[15..0]}; Port A word (pair*144+s)*8+k = entry[k*32 +:32].
 *   (RTL/fc/fc_engine.v + TB/.../tb_fc_engine.v load_weights 와 1:1.) */
static void fc_write_weights(void)
{
    for (u32 pair = 0; pair < FC_PAIRS; pair++) {
        for (u32 s = 0; s < FC_SPATIAL; s++) {
            uint8_t even[FC_CHANS], odd[FC_CHANS];
            for (u32 c = 0; c < FC_CHANS; c++) {
                u32 simd  = fc_weights_simd[(pair * FC_SPATIAL + s) * FC_CHANS + c];
                u32 carry = (simd >> 16) & 0x1U;             /* W0 sign bit (bit16) */
                even[c] = (uint8_t)(simd & 0xFFU);           /* W0 → even column */
                odd[c]  = (uint8_t)(((simd >> 17) & 0xFFU) + carry); /* W1 → odd column */
            }
            u32 wbase = (pair * FC_SPATIAL + s) * 8U;        /* Port A word base */
            for (u32 k = 0; k < 8U; k++) {
                const uint8_t *src = (k < 4U) ? &even[k * 4U] : &odd[(k - 4U) * 4U];
                u32 word = (u32)src[0] | ((u32)src[1] << 8)
                         | ((u32)src[2] << 16) | ((u32)src[3] << 24);
                Xil_Out32(FCW_BASE + (wbase + k) * 4U, word);
            }
        }
    }
}

/* ---- 이미지 1장을 빈 bank 에 write ----
 *   test_images 는 gen script 가 이미 input BRAM Port A 포맷(little-endian uint32)으로
 *   패킹해 둠 → PS 는 byte-combine 없이 word 를 그대로 전송만 한다 (전송 병목 완화). */
static void write_image(u32 img)
{
    u32 bank = img & 1U;                       /* bank = img index LSB (accel 내부 sync) */
    const uint32_t *p = &test_images[img * IN_WORDS];
    for (u32 i = 0; i < IN_WORDS; i++) {
        /* word 주소: bank0 = 0..195, bank1 = 256..451 (MSB=bit8=bank) */
        Xil_Out32(INPUT_BASE + (bank * 256U + i) * 4U, p[i]);
    }
}

int main(void)
{
    /* BRAM/CSR(0xC000_0000~, 0x44A0_0000) 는 D-cache 범위(MIG DDR) 밖 → uncached MMIO.
     * const weight/image 배열은 DDR(.rodata)에서 read. SDT flow 라 init_platform 없음. */
    xil_printf("\r\n=== CNN Accelerator Test (N=%u) ===\r\n", (unsigned)N_IMAGES);

    /* ---- 1. Weight 적재 (PS → weight BRAM, 1회) ---- */
    xil_printf("[1] weights: conv1=%u conv2=%u fc=%u(simd)->%u(bram)\r\n",
               (unsigned)CONV1_WEIGHTS_SIMD_LEN, (unsigned)CONV2_WEIGHTS_SIMD_LEN,
               (unsigned)FC_WEIGHTS_SIMD_LEN, (unsigned)(FC_PAIRS * FC_SPATIAL * 8U));
    write_simd_weights(CONV1W_BASE, conv1_weights_simd, CONV1_WEIGHTS_SIMD_LEN);
    write_simd_weights(CONV2W_BASE, conv2_weights_simd, CONV2_WEIGHTS_SIMD_LEN);
    fc_write_weights();

    /* ---- 2. enable → start (enable level 먼저, 그 다음 start 1-cycle pulse) ---- */
    xil_printf("[2] enable + start\r\n");
    csr_ctrl(CTRL_EN);
    csr_ctrl(CTRL_EN | CTRL_ST);

    /* ---- 3. 이미지 루프 (serial): can_load 대기 → input write → img_ready
     *        → img_cnt 증가 대기 → 그 read 의 result ---- */
    xil_printf("[3] %u images...\r\n", (unsigned)N_IMAGES);
    u32 prev_cnt = 0;
    for (u32 img = 0; img < N_IMAGES; img++) {
        u32 s, guard;

        guard = 0;
        do { s = csr_stat(); } while (!ST_CANLOAD(s) && ++guard < POLL_GUARD);
        if (guard >= POLL_GUARD) {
            xil_printf("  [TIMEOUT] can_load @img %u STATUS=0x%08x\r\n", (unsigned)img, (unsigned)s);
            break;
        }

        write_image(img);
        csr_ctrl(CTRL_EN | CTRL_IMG);          /* img_ready pulse */

        guard = 0;
        do { s = csr_stat(); } while ((ST_IMGCNT(s) == prev_cnt) && ++guard < POLL_GUARD);
        if (guard >= POLL_GUARD) {
            xil_printf("  [TIMEOUT] img_cnt @img %u STATUS=0x%08x\r\n", (unsigned)img, (unsigned)s);
            break;
        }
        prev_cnt = ST_IMGCNT(s);

        /* result(class)는 더 이상 STATUS 에 없음 — bram_output 에 누적되고, 루프 종료 후
         * 0xC800_0000 에서 일괄 read 하여 test_labels 와 비교한다 (작업순서 2: output AXI
         * BRAM Ctrl 추가 후 구현). 지금은 진행 상황만 출력. */
        if (img < 8U)
            xil_printf("  img %3u done (img_cnt=%u)\r\n", (unsigned)img, (unsigned)prev_cnt);
    }
    (void)test_labels;   /* 작업순서 2 (bram_output read) 에서 사용 — unused 경고 억제 */

    /* ---- 4. 결과 + latency (48-bit timer; N<10000 이면 timer 미정지 → snapshot) ---- */
    u32 t_lo = Xil_In32(CSR_BASE + CSR_TIMER_LO);
    u32 t_hi = Xil_In32(CSR_BASE + CSR_TIMER_HI) & 0xFFFFU;
    u32 us   = (t_hi == 0U) ? (t_lo / 100U) : 0xFFFFFFFFU;

    xil_printf("\r\n=== Result ===\r\n");
    xil_printf("completed   : %u images (result 검증은 bram_output read 구현 후 — 작업순서 2)\r\n", (unsigned)prev_cnt);
    xil_printf("latency     : %u cyc (hi=%u) ~%u us @100MHz%s\r\n",
               (unsigned)t_lo, (unsigned)t_hi, (unsigned)us,
               (N_IMAGES == 10000U) ? "" : " [snapshot]");

    return 0;
}
