#include "platform.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include <stdint.h>

// 베이스 주소 (xparameters.h 기반)
#define CSR_BASE    0x44A00000U
#define BRAM1_BASE  0xC0000000U
#define BRAM2_BASE  0xC2000000U

// 데이터 크기
#define BRAM1_LEN   10404U   // 102 × 102
#define BRAM2_LEN   10000U   // 100 × 100

// CSR 레지스터 오프셋
#define CSR_DONE_OFFSET   0x0   // slv_reg0[0] = done
#define CSR_START_OFFSET  0x4   // slv_reg1[0] = start (1-cycle pulse)

// 입력 이미지와 정답 (별도 헤더로 준비)
#include "input_image.h"   // const uint8_t input_image[10404];
#include "ref_output.h"    // const uint8_t ref_output[10000];

int main(void)
{
    init_platform();
    Xil_DCacheDisable();

    xil_printf("\r\n=== Sobel Edge Detector Test ===\r\n");

    // 1. BRAM1에 입력 이미지 쓰기
    xil_printf("[1] Writing %u pixels to BRAM1...\r\n", BRAM1_LEN);
    for (u32 i = 0U; i < BRAM1_LEN; i++) {
        Xil_Out32(BRAM1_BASE + i * 4U, (u32)input_image[i]);
    }

    // 2. start 신호 (slv_reg1[0] = 1, 자동 클리어)
    xil_printf("[2] Sending START...\r\n");
    Xil_Out32(CSR_BASE + CSR_START_OFFSET, 0x1U);

    // 3. done 폴링
    xil_printf("[3] Waiting for DONE...\r\n");
    while ((Xil_In32(CSR_BASE + CSR_DONE_OFFSET) & 0x1U) == 0U) {
        // busy wait
    }
    xil_printf("[3] DONE received!\r\n");

    // 4. BRAM2에서 결과 읽고 검증
    xil_printf("[4] Reading and comparing %u pixels...\r\n", BRAM2_LEN);
    u32 pass = 0U, fail = 0U;
    int first_fail = -1;
    u8 first_exp = 0, first_got = 0;

    for (u32 i = 0U; i < BRAM2_LEN; i++) {
        u8 got = (u8)(Xil_In32(BRAM2_BASE + i * 4U) & 0xFFU);
        u8 exp = ref_output[i];
        if (got == exp) {
            pass++;
        } else {
            if (first_fail < 0) {
                first_fail = (int)i;
                first_exp = exp;
                first_got = got;
            }
            fail++;
        }
    }

    // 5. 결과 출력
    xil_printf("\r\n=== Result ===\r\n");
    xil_printf("PASS: %u / %u\r\n", (unsigned)pass, (unsigned)BRAM2_LEN);
    xil_printf("FAIL: %u\r\n", (unsigned)fail);
    if (fail == 0U) {
        xil_printf(">>> Verification PASSED!\r\n");
    } else {
        xil_printf(">>> Verification FAILED\r\n");
        xil_printf("    First fail at idx %d: exp=%u, got=%u\r\n",
                   first_fail, (unsigned)first_exp, (unsigned)first_got);
    }

    cleanup_platform();
    return 0;
}