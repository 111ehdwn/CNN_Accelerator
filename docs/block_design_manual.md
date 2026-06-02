# CNN Accelerator — Vivado Block Design 단계별 매뉴얼 (Arty A7-100T)

환경: Vivado/Vitis 2024.1, Arty A7-100T (xc7a100t-csg324-1)

> ★ 이 매뉴얼의 핵심: "어디까지 만들고 무엇을 검증하느냐"를 못 박음.
> 한 번에 다 만들고 돌리면 문제 원인을 못 찾는다. 반드시 단계별 검증.

> ## 전체 빌드 순서 한눈에
> ```
> [STAGE 1] 클럭 + DDR + UART 만  ──→  ★검증 A: ddr_uart_test (DDR+UART+캐시)
>                                         이게 통과해야 기반이 멀쩡한 것
> [STAGE 2] + MicroBlaze 캐시 확정 ──→  (STAGE 1 재확인)
> [STAGE 3] + CSR + cnn_accelerator ──→ ★검증 B: CSR write + 이미지 1장
> [STAGE 4] + BRAM 컨트롤러 5개      ──→ ★검증 C: 전체 정확도 + latency
>            (weight 3 + input 1 + output 1)
> ```
> ★검증 A는 STAGE 1 끝(accelerator 붙이기 전)에 돌린다. 가장 중요.

---

# ════════ STAGE 1 : 클럭 + DDR + UART ════════
> 목표: accelerator 없이 **클럭 트리 + DDR + UART + 캐시**만으로 도는 최소 시스템.
> 여기서 ★검증 A를 돌린다. IP 까는 게 제일 빡센 구간이니 천천히.

## 1-1. 프로젝트 + Block Design
- 새 프로젝트 → part `xc7a100t-csg324-1`
- Flow Navigator → Create Block Design (`cnn_accelerator_system`)

## 1-2. MIG (DDR3) + 클럭 토폴로지  ★가장 실수 잦은 곳★
1. Window → Board → **DDR3 SDRAM** 드래그
2. 자동 생성된 외부 포트 `sys_clk_i`, `clk_ref_i` **삭제**
3. MIG 더블클릭 → 재구성:
   - System Clock = **No Buffer**
   - Reference Clock = **No Buffer**
   - "Select Additional Clocks" **체크 해제**
   - Pin Selection 페이지 → **Validate** → Finish
4. 포트 생성 (BD 빈 곳 우클릭 → Create Port):
   - `CLK100MHZ` (In, Clock, 100MHz)
   - `ck_rst` (In, Active Low)
   - ★ 포트 이름은 xdc net 이름과 **정확히 일치** (대소문자 포함)
5. IP Catalog → **Utility Buffer** → C Buf Type = **BUFG**
6. IP Catalog → **Clocking Wizard**:
   - Input Clock Source = **No buffer**
   - `clk_out1`=100MHz(시스템), `clk_out2`=200MHz(MIG ref)
   - Reset Type = **Active Low**
7. 결선:
   - `CLK100MHZ` → BUFG `BUFG_I`
   - BUFG `BUFG_O` → MIG `sys_clk_i` **그리고** clk_wiz `clk_in1` (분기!)
   - clk_wiz `clk_out2` → MIG `clk_ref_i`
   - `ck_rst` → MIG `sys_rst` **그리고** clk_wiz `resetn`
   - (MIG `aresetn`은 1-5에서 연결)
   - ★ 외부 클럭은 BUFG **한 번** 거쳐 분기. 어기면
     `CLOCK_DEDICATED_ROUTE` 에러.

## 1-3. MicroBlaze (+ 캐시 — ★검증 A 성패 좌우)
1. **Classic MicroBlaze** 추가 (V 아님)
2. Run Block Automation:
   - Local Memory **16KB**, Debug Only, Peripheral AXI **Enabled**
   - **Clock Connection = `/clk_wiz_0/clk_out1`** (CLK100MHZ 직결 금지)
3. V 변환 제안 → **Keep Classic MicroBlaze**
4. MicroBlaze 더블클릭 → Cache:
   - **Enable Instruction Cache** / **Enable Data Cache** 체크
   - I-cache **16KB** / D-cache **32KB**, Line Length **8**, Victims **8**
   - ★ **Base `0x8000_0000` / High `0x8FFF_FFFF`** (양쪽 캐시 모두).
     이 범위가 DDR을 덮어야 코드가 캐시를 탐. (안 그러면 CPU 100배 느림)

## 1-4. UART
- **Board 탭 → USB UART** 드래그 (포트/핀 자동) 권장
- ★ Uartlite baud는 **합성 시 고정**. **이 프로젝트는 115200** (검증 완료).
  IP 재구성 시 115200 유지.

## 1-5. Interconnect 2개 (반드시 **AXI Interconnect**, SmartConnect 아님)
- **ram_interconnect** (Slave 2 / Master 1):
  - MicroBlaze `M_AXI_IC`→S00, `M_AXI_DC`→S01, M00→MIG `S_AXI`
- **perif_interconnect** (Slave 1 / Master 1 — STAGE 3,4에서 확장):
  - MicroBlaze `M_AXI_DP`→S00, M00→UART `S_AXI`

## 1-6. Connection Automation (클럭/리셋만)
1. 데이터(S_AXI)는 1-5처럼 **수동 결선** 완료된 상태여야 함
2. Run Connection Automation → All → **클럭/리셋만 떠야 정상**
   - ★ 데이터 인터페이스가 자동화에 뜨면 = 수동 결선 누락. Cancel 후 보완.
3. **수동**: MIG `aresetn` → ram_interconnect `M00_ARESETN`

## 1-7. 주소 할당 (1차)
- Address Editor → **Assign All**
- 확인: DDR `0x8000_0000`(256M, Instruction+Data 양쪽), UART `0x4060_0000`(64K),
  LMB `0x0`(16K)
- F6 Validate → critical warning 0개

## 1-8. HW 생성 → ★★★ 검증 A 실행 ★★★
> **여기가 핵심 체크포인트.** accelerator/CSR/BRAM 붙이기 **전에**
> 클럭+DDR+UART+캐시가 멀쩡한지 확인. 이거 통과 못 하면 위에 아무것도 쌓지 마라.

1. Create HDL Wrapper ("Let Vivado manage") → Generate Bitstream
2. Export Hardware → **Include Bitstream** → `stage1.xsa`
3. Vitis: `stage1.xsa`로 platform 생성 → **ddr_uart_test 앱** (코드 §맨아래)
4. Serial Terminal **baud 115200**
5. **기대**: UART 출력 + DDR 5패턴 전부 PASS
6. 실패 시 진단:
   - UART 출력 자체가 없음 → 클럭 토폴로지(1-2) / UART 연결(1-4) / baud
   - UART는 되는데 DDR FAIL → MIG calibration / ram_interconnect 리셋(1-6.3)
   - 출력이 깨지거나 hang → **캐시 enable 누락**(1-3.4) 또는 USB 재연결 과도현상
     (Parallels에서 USB 재할당 시 발생 — USB 안정화 후 재시도)

> ✅ 검증 A 통과 = 기반 완성. 이제 STAGE 3로. (STAGE 2는 위 1-3에 흡수됨)

---

# ════════ STAGE 3 : + CSR + cnn_accelerator ════════
> 목표: 제어 경로(CSR) + accelerator 본체 연결. 데이터 경로(BRAM)는 STAGE 4.
> 여기서 ★검증 B.

## 3-1. IP 추가
1. **cnn_accelerator** (PL 본체) 추가
2. **csr_axi** 추가
   - ★ **robust handshake(aw_en 패턴)로 수정된 버전**인지 확인.
     Xilinx 데모 Lite 템플릿 그대로면 W-before-AW에서 CSR write hang.

## 3-2. CSR ↔ accelerator 제어 결선
- CSR → accelerator: `enable`, `start`, `img_ready`
- accelerator → CSR: `result[3:0]`, `img_done`, `input_consumed`
- (출력 BRAM write 신호도 여기서 나옴 — STAGE 4에서 BRAM에 연결)

## 3-3. CSR를 perif_interconnect에 연결
- perif_interconnect 마스터 포트 추가 → CSR `S_AXI` **수동 연결**
- Run Connection Automation → 클럭/리셋만 (clk_out1 / 100M reset)

## 3-4. 주소 (CSR 추가)
- Assign All → CSR `0x44A0_0000`(64K) 확인 → F6 Validate

## 3-5. ★★★ 검증 B 실행 ★★★
1. Generate Bitstream → Export `stage3.xsa`
2. Vitis: platform **"Update Hardware Specification"**으로 xsa 교체
   (★ platform 삭제/재생성 금지 — update만)
3. 앱: enable/start → CSR read-back으로 enable 확인 → start로 timer 증가 확인
4. **기대**:
   - `[2] enable` 통과 (멈추지 않음) = CSR write hang 없음
   - timer가 증가 = start 펄스 정상
   - 멈추면 → csr_axi가 robust handshake 버전인지(3-1) 재확인

---

# ════════ STAGE 4 : + BRAM 컨트롤러 5개 ════════
> weight 3 (c1w/c2w/fcw) + input 1 + **output 1**. 데이터 경로 완성.
> 여기서 ★검증 C (최종: 정확도 + latency).

## 4-1. AXI BRAM Controller 5개 추가
| 컨트롤러 | 용도 | 방향 |
|---|---|---|
| c1w_bram_axi | conv1 weight | PS write |
| c2w_bram_axi | conv2 weight | PS write |
| fcw_bram_axi | fc weight | PS write |
| input_bram_axi | 입력 이미지 | PS write (ping-pong 2-bank) |
| **output_bram_axi** | **결과 저장** | **PS read** (accelerator write) |

- weight/input: BRAM_PORTA ↔ accelerator Port A (PS write), Port B는 내부 read
- ★ **output BRAM**: accelerator(또는 CSR)가 `addr=img_cnt`에 result write,
  PS는 끝나고 일괄 read. result_latch 단일 레지스터의 덮어쓰기 문제를 해결
  (풀스피드로 돌려도 결과 안 놓침 → 측정+정확도 동시 가능).

## 4-2. 결선
- 5개 컨트롤러를 **perif_interconnect** 마스터 포트에 **수동 연결**
- output BRAM의 write 포트(Port A 또는 B)를 accelerator/CSR의
  result/img_cnt/img_done에 연결 (어느 포트가 write인지 BMG 설정 확인)
- Run Connection Automation → 클럭/리셋만

## 4-3. 주소 (전체 — 최종 맵)
| 영역 | Base | Range |
|---|---|---|
| UART | `0x4060_0000` | 64K |
| CSR | `0x44A0_0000` | 64K |
| c1w | `0xC000_0000` | 4K |
| c2w | `0xC200_0000` | 4K |
| fcw | `0xC400_0000` | 64K (11520 word 수용) |
| input | `0xC600_0000` | 8K (2-bank: word 0 / word 256) |
| **output** | (Assign All이 정함, 예 `0xC800_0000`) | 결과 수용 크기 |
| DDR | `0x8000_0000` | 256M |
| LMB | `0x0` | 16K |

- ★ 모든 BRAM/CSR는 캐시 범위(0x8...) 밖 = uncached. 직접 접근 OK.
- ★ fcw Slice **14-bit** + BMG depth ≥ 11520 (13-bit면 weight aliasing).
- F6 Validate → critical warning 0개

## 4-4. ★★★ 검증 C 실행 (최종) ★★★
1. Generate Bitstream → Export `stage4.xsa` → platform update
2. 앱(캐시 enable + -O2 빌드):
   - weight 적재 → enable/start → 풀스피드 이미지 스트림 (ping-pong)
   - 결과는 output BRAM에 자동 누적
   - done 후 output BRAM 일괄 read → golden 비교 + timer read
3. **기대**: 전체 이미지 100% MATCH + latency 측정값
4. 통과 시 → 이게 베이스라인. **커밋 + xsa/bit 백업 + git tag**

---

## 부록: ddr_uart_test 코드 (검증 A 전용, STAGE 1에서 사용)
```c
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_types.h"

#define DDR_BASE   0x80000000U
#define TEST_WORDS 4096U

static int ddr_pattern(u32 pat, const char *name)
{
    u32 i, rd, err = 0;
    for (i = 0; i < TEST_WORDS; i++)
        Xil_Out32(DDR_BASE + i*4U, pat ^ (i*0x9E3779B1U));
    Xil_DCacheFlush();
    for (i = 0; i < TEST_WORDS; i++) {
        rd = Xil_In32(DDR_BASE + i*4U);
        if (rd != (pat ^ (i*0x9E3779B1U))) {
            err++;
            if (err <= 3)
                xil_printf("  [%s] @%u exp=%08X got=%08X\r\n", name,
                    (unsigned)i, (unsigned)(pat^(i*0x9E3779B1U)), (unsigned)rd);
        }
    }
    xil_printf("  [%s] %s (err=%u)\r\n", name, err ? "FAIL":"PASS", (unsigned)err);
    return err;
}

int main(void)
{
    Xil_ICacheEnable();
    Xil_DCacheEnable();

    xil_printf("\r\n==== DDR + UART bring-up test ====\r\n");
    xil_printf("UART OK (readable at 115200)\r\n");

    u32 total = 0;
    total += ddr_pattern(0x00000000U, "P0 zeros");
    total += ddr_pattern(0xFFFFFFFFU, "P1 ones");
    total += ddr_pattern(0xAAAAAAAAU, "P2 AA");
    total += ddr_pattern(0x55555555U, "P3 55");
    total += ddr_pattern(0xDEADBEEFU, "P4 mixed");

    if (total == 0) xil_printf("\r\n==== ALL DDR PATTERNS PASS ====\r\n");
    else            xil_printf("\r\n==== DDR FAIL (err=%u) ====\r\n",(unsigned)total);

    while (1) { }
    return 0;
}
```
**성공 출력:**
```
==== DDR + UART bring-up test ====
UART OK (readable at 115200)
  [P0 zeros] PASS (err=0)
  ... (P1~P4 PASS)
==== ALL DDR PATTERNS PASS ====
```

## 검증 체크포인트 요약
| 시점 | 만든 것 | 검증 | 통과 기준 |
|---|---|---|---|
| STAGE 1 끝 | 클럭+DDR+UART+캐시 | ★A ddr_uart_test | UART 출력 + 5패턴 PASS |
| STAGE 3 끝 | +CSR+accelerator | ★B CSR write+제어 | enable 통과, timer 증가 |
| STAGE 4 끝 | +BRAM 5개 | ★C 정확도+latency | 100% MATCH + 측정값 |

## 우리가 실제로 막혔던 함정 (시간 절약)
1. 클럭 토폴로지(1-2) — BUFG 분기 안 하면 CLOCK_DEDICATED_ROUTE
2. MicroBlaze 클럭(1-3) — CLK100MHZ 직결 금지, clk_out1
3. **캐시 미설정(1-3, 검증 A) — CPU 100배 느림 (최대 함정)**
4. CSR write hang(3-1) — 데모 FSM 버그, robust handshake로 수정
5. fcw aliasing(4-3) — 13-bit면 weight 깨짐, 14-bit 필요
6. argmax timing — 1-cycle 비교 트리 직렬화로 해결
7. UART baud(1-4) — 115200 고정, 터미널 일치
8. platform 재생성 금지(3-5) — Update Hardware Specification