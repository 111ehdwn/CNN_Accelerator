# Conv2 Engine Design

## 1. 레이어 명세

```
Input :  (8 IC, 26 H, 26 W)  INT8 [-128, 127]
Weight:  (16 OC, 8 IC, 3, 3) INT8 [-127, 127]  (pre-packed)
Output:  (16 OC, 24, 24)     INT8 [0, 127]    (ReLU 후)

Conv 3×3, stride 1, no pad.
출력 양자화: accumulated >>10  →  saturate [-128, 127]  →  ReLU
```

---

## 2. 자원 / 성능 요약

```
DSP   : 192 = K_row(3) × IC(8) × OC_pair(8) × SIMD(2)
BRAM  : 1 (Conv2 weight, 32-bit × 576) + 외부 c1c2, c2pool ping-pong
LUT/FF: ~15K / ~8K (추정)

Cycle/image: ~1,796 @ 180 MHz ≈ 10.0 μs
```

자세한 cycle 분해는 `conv2_timing_tables.md` 참조.

---

## 3. 아키텍처

### 3.1 모듈 계층

```
conv2_engine.v  (top, 작성 예정)
├── conv2_fsm.v             — 제어 plane (8 state, counters)
├── weight_loader.v         — BMG → 192 PE 적재 (시스템 시작 1회)
├── conv2_weight_bram       — BMG IP (32-bit × 576)
├── line_buffer × 16        — IC 8개 × 2 stage, DEPTH=25
├── window_register × 8     — IC당 1개 (3×3 sliding window)
├── pe_cell × 192           — DEPTH=3 (K_col weight 3개 보유)
├── krow_ic_adder_tree × 16 — 24:1 합산, 5-stage pipeline
├── kcol_accumulator × 16   — 3-cycle K_col 누적
└── truncate_relu #(.N(16)) — >>10, saturate, ReLU
```

### 3.2 데이터 흐름

```
c1c2 BRAM (8 IC × 8b = 64b/word, L=2)
    ↓                       (IC별 stream)
line_buffer (lb1, lb2)   ─→ 3-row 동시 보유
    ↓
window_register (3×3, 8 IC)
    ↓                       (col_sel, sel 로 매 cycle 선택)
pe_cell × 192 (SIMD ×2)  ─→ 384 mul/cycle
    ↓
krow_ic_adder_tree × 16  ─→ 22-bit, OC_pair × SIMD 별
    ↓
kcol_accumulator × 16    ─→ 24-bit, 3-cycle 누적
    ↓
truncate_relu (N=16)     ─→ 8-bit × 16 OC
    ↓
c2pool BRAM (128b/word)
```

Pipeline depth (PE input → c2pool memory updated): **12 cycle**.

---

## 4. 핵심 설계 결정

### 4.1 Output Stationary + Weight Stationary

Weight 는 시스템 시작 시 1회 적재 후 PE 내부 register 에 영구 고정. Activation 만 BRAM → line_buffer → window 로 stream.

### 4.2 K_col 3-cycle time-multiplexing

한 출력 픽셀 = 9 mul/IC. Full unroll 시 576 DSP 필요 (자원 초과). K_col 만 시간 분할 → 192 DSP × 3 cycle = 1 픽셀.

PE 내부 weight register 3개 (K_col 0/1/2 각각). 매 cycle `sel` 로 활성 weight 선택.

### 4.3 SIMD packing (oc, oc+8) per DSP

DSP 1개의 25×18 multiplier 로 2 OC 동시 처리.

```
W0 = W[k,   ic, kh, kw]   (k = 0..7)
W1 = W[k+8, ic, kh, kw]
A_port = W1 × 2^17 + W0   (25-bit signed, Python 오프라인 pack)
B_port = X (activation, 18-bit signed)
P = A × B                  (43-bit, DSP 출력)

mul0 = P[16:0]                          → W0 × X
mul1 = sint16(P[32:17]) + [P[0]<0]      → W1 × X (carry 보정)
```

weight 범위 [-127, 127] 이면 -128 carry overflow 없음 → 보정 단순.

상세: `docs/DSP48E1_signed8x8_SIMD_Packing.md`.

### 4.4 COMPUTE_WRAP — row boundary 처리

행이 바뀔 때 (r=0..22) window 가 새 row r+3 데이터를 미리 받아 다음 출력 (r+1, 0) window 정렬을 준비해야 함. 단순 stall (3 cycle PE idle) 대신:

- col_sel=0 으로 고정한 채 window 를 1 col 씩 shift × 3 cycle.
- 동시에 sel 0→1→2 변화로 출력 (r, 23) 의 K_col contribution 누적.
- 결과: PE idle 0, 출력 (r, 23) 계산 + window 정렬 동시 수행.

→ ~70 cycle/image 절약. cycle-by-cycle: `conv2_timing_tables.md §3`.

### 4.5 Counter cap @ (25, 25) + DRAIN state (마지막 행)

마지막 행 (r=23) 처리 중 BRAM read addr 이 입력 영역 (0..25) 을 넘어가면 ping-pong buffer 의 다른 image 데이터를 잘못 읽을 수 있음 → counter 를 (25, 25) 에서 freeze (cap).

마지막 행은 다음 행이 없으므로 WRAP 불필요 → 24 픽셀 전부 HOLD/HOLD/ADV 로 처리. cap 후 BRAM 이 (25, 25) 를 재read 하지만 필요한 데이터는 이미 pipeline 안에 들어와 있어 무해.

마지막 PE input 이후 pipeline drain (12 cycle) 을 위해 DRAIN state 진입 → DONE.

상세: `conv2_timing_tables.md §4`.

### 4.6 ping-pong + 양방향 handshake

Conv1 ↔ Conv2 와 Conv2 ↔ Maxpool 사이 각각 ping-pong buffer (input/output bank 2개). Inter-image pipelining 으로 throughput ↑.

차이 카운터 (signed 3-bit) 로 backpressure 처리. 속도 가정 무관 (양쪽 어느 쪽이 빠르거나 느려도 동작).

```
prior_diff = Conv2 rdone count − Conv1 wdone count   (−2..0)
after_diff = Conv2 wdone count − Maxpool rdone count (0..+2)

ready_to_compute = (prior_diff < 0) && (after_diff < 2)
```

bank_sel 은 별도 1-bit toggle FF (rdone/wdone 마다 flip).

---

## 5. 인터페이스 (top-level conv2_engine.v)

```verilog
module conv2_engine (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,

    // Conv2 weight BMG (Port A, PS write via AXI BRAM Ctrl)
    input  wire         c2w_ena,
    input  wire [9:0]   c2w_addra,
    input  wire [31:0]  c2w_dina,

    // c1c2 buffer (Port B read, L=2 — Primitive Output Register Enable 필수)
    output wire         c1c2_re,
    output wire [10:0]  c1c2_addr,    // {input_bank_sel, row[4:0], col[4:0]}
    input  wire [63:0]  c1c2_dout,    // 8 IC × 8b packed

    // c2pool buffer (Port A write)
    output wire         c2pool_we,
    output wire [10:0]  c2pool_addr,  // {output_bank_sel, output_pixel_cnt[9:0]}
    output wire [127:0] c2pool_din,   // 16 OC × 8b packed

    // Handshake (양방향, 1-cycle pulse)
    input  wire         prior_wdone,  // Conv1 → Conv2
    output wire         rdone,        // Conv2 → Conv1
    input  wire         succ_rdone,   // Maxpool → Conv2
    output wire         wdone         // Conv2 → Maxpool
);
```

---

## 6. 검증 전략

| Stage | 대상 | 방법 |
|---|---|---|
| 1 | `pe_cell` SIMD packing | 2²⁴ exhaustive (`scripts/header_hex_gen/conv2_simd_pack.py` 의 verification 함수 참조) |
| 2 | `krow_ic_adder_tree` | random 입력, golden 비교 |
| 3 | `kcol_accumulator` | 3-cycle pattern |
| 4 | `truncate_relu` | 경계값 + random |
| 5 | `weight_loader` | BMG read, PE broadcast 정확성 |
| 6 | `conv2_fsm` | cycle trace 가 `conv2_timing_tables.md` verification anchors A1~A10 와 일치 |
| 7 | `conv2_engine` 통합 | 1 image bit-exact (vs `scripts/golden_sim/0_reference.py`) |
| 8 | cycle count 측정 | ~1,796 cycle/image |

---

## 7. 참조 문서

- **`conv2_timing_tables.md`** — cycle-by-cycle 표, verification anchors. testbench 검증의 정본.
- **`conv2_timing.md`** — 상세 timing 분석 + open items + 책임 분리 설명. AI/long-form 용.
- **`../../CONV2_TIMING_FIX.md`** — c1c2 BRAM L=1 → L=2 fix 의 cycle-by-cycle 증명.
- **`../../docs/DSP48E1_signed8x8_SIMD_Packing.md`** — SIMD packing 알고리즘.
- **`conv2_fsm.v`** — FSM 코드. 헤더 주석에 상태 전이 조건 + 카운터 의미 상세.
- **`weight_loader.v`** — weight 적재 cycle 정합성 (3-stage delay 매칭).

---

## 8. 명명 규칙 (이 모듈 한정)

| Prefix / suffix | 의미 |
|---|---|
| `prior_*` | upstream (Conv1) 으로부터 / 으로 |
| `succ_*` | downstream (Maxpool) 으로부터 / 으로 |
| `*_done` | 1-cycle pulse, image 1개 단위 완료 |
| `*_bank_sel` | ping-pong bank index (1-bit) |
| `kw_cnt` (FSM) / `sel` (PE) | K_col index (0/1/2). 같은 개념 — 미래에 한 이름으로 통일 권장. |
| `row_cnt`, `col_cnt` | BRAM read raster 좌표 (cap @ 25) |
| `output_pixel_cnt` | 완성된 출력 픽셀 수 (0..576). datapath 의 c2pool write addr 와 공유. |
