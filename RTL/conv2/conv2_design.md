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

자세한 cycle 분해는 `conv2_timing.md` (특히 §8 testbench cycle 매핑, §11 부록) 참조.

---

## 3. 아키텍처

### 3.1 모듈 계층

```
conv2_engine.v  (top)
├── conv2_fsm.v             — 제어 plane (8 state, counters)             [conv2/]
├── weight_loader.v         — BMG → 192 PE 적재 (시스템 시작 1회)         [conv2/]
├── conv2_weight_bram       — BMG IP (32-bit × 576)                       [Vivado IP]
├── line_buffer × 16        — IC 8개 × 2 stage, DEPTH=25                   [core/]
├── window_register × 8     — IC당 1개 (3×3 sliding window)                [core/]
├── pe_cell × 192           — DEPTH=3 (K_col weight 3개 보유)              [core/]
├── krow_ic_adder_tree × 16 — 24:1 합산, 5-stage pipeline                  [conv2/]
├── kcol_accumulator × 16   — 3-cycle K_col 누적                           [conv2/]
└── truncate_relu #(.N(16)) — >>10, saturate, ReLU                         [core/]
```

**공용 모듈** (`RTL/core/`): `line_buffer`, `window_register`, `pe_cell`, `truncate_relu` — Conv1 과 공유 (Conv1 은 DEPTH=27, 1 inst, DEPTH=2, N=4 로 사용).
**Conv2 전용** (`RTL/conv2/`): top + FSM + weight_loader + Conv2-specific adder_tree/kcol_accumulator.

추가로 conv2_engine 내부에:
- **col_sel mux × 24** (3 K_row × 8 IC): window 의 9 cell 중 col_sel 에 따라 3-cell 선택 → PE x 입력
- **PE load enable decoder** (8-bit pe_id → 192-bit one-hot): weight 적재 시점 분배
- **9-cycle delay pipeline** (sel, pe_en): kcol_accumulator 의 `kw_phase`/`en` 을 PE 4 + adder 5 = 9 cycle 지연
- **c2pool write addr 카운터**: c2pool_we 마다 +1

### 3.2 데이터 흐름

```
c1c2 BRAM (8 IC × 8b = 64b/word, L=2)
    ↓                       (IC별 stream)
line_buffer (lb1, lb2)   ─→ 3-row 동시 보유
    ↓
window_register (3×3, 8 IC)
    ↓                       (col_sel mux)
pe_cell × 192 (SIMD ×2)  ─→ 384 mul/cycle
    ↓                       (9-cycle delay alignment)
krow_ic_adder_tree × 16  ─→ 22-bit
    ↓
kcol_accumulator × 16    ─→ 24-bit, 3-cycle 누적
    ↓                       (out_valid → truncate.en)
truncate_relu (N=16)     ─→ 8-bit × 16 OC
    ↓                       (1-cycle 지연 → c2pool_we)
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

→ ~70 cycle/image 절약. cycle-by-cycle: `conv2_timing.md §3` (분석) / `§11.3` (컴팩트 표).

### 4.5 Counter cap @ (25, 25) + DRAIN state (마지막 행)

마지막 행 (r=23) 처리 중 BRAM read addr 이 입력 영역 (0..25) 을 넘어가면 ping-pong buffer 의 다른 image 데이터를 잘못 읽을 수 있음 → counter 를 (25, 25) 에서 freeze (cap).

마지막 행은 다음 행이 없으므로 WRAP 불필요 → 24 픽셀 전부 HOLD/HOLD/ADV 로 처리. cap 후 BRAM 이 (25, 25) 를 재read 하지만 필요한 데이터는 이미 pipeline 안에 들어와 있어 무해.

마지막 PE input 이후 pipeline drain (12 cycle) 을 위해 DRAIN state 진입 → DONE.

상세: `conv2_timing.md §4` (분석) / `§11.4` (컴팩트 표).

### 4.6 Adder tree `en` 의 5-cycle window 보장

`krow_ic_adder_tree` 는 5-stage pipeline 이고 **각 stage 가 `en` 으로 게이팅** 된다. 한 image 의 마지막 valid PE 출력이 sum register 까지 도달하려면 `en=1` 이 **5 cycle 연속 유지** 되어야 한다.

```verilog
// conv2_engine.v
wire adder_en = pe_en_pipe[3] | pe_en_pipe[4] | pe_en_pipe[5]
              | pe_en_pipe[6] | pe_en_pipe[7];   // 5-cycle OR window
```

`pe_en_pipe[3]` 하나만 사용하면 마지막 입력 후 1 cycle 만에 en=0 → s1 에서 데이터가 stuck → sum register freeze → `kcol_accumulator` 가 stale 값을 누적해서 마지막 2 출력 픽셀의 값이 오염된다.

이 bug 는 corner pixel 의 입력이 모두 0 (background) 인 image 에서는 mask 되어 invisible. multi-image 검증 중 image 28 에서 처음 catch 됨. 상세는 **`conv2_adder_drain_bug_fix.md`** 참조.

**일반 원칙**: pipelined 모듈의 `en` 게이팅은 "pipeline depth 만큼의 window" 로 정의. 모든 pipelined 모듈 (adder tree, FIFO, accumulator) 에 동일하게 적용.

### 4.7 ping-pong + 양방향 handshake

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
    input  wire         c2w_ena,      // 1-bit (BMG byte-write disabled 가정)
    input  wire [9:0]   c2w_addra,
    input  wire [31:0]  c2w_dina,

    // c1c2 buffer (Port B read, L=2 — Primitive Output Register Enable 필수)
    output wire         c1c2_re,
    output wire [10:0]  c1c2_addr,    // {input_bank_sel, row[4:0], col[4:0]}
    input  wire [63:0]  c1c2_dout,    // 8 IC × 8b packed

    // c2pool buffer (Port A write)
    output wire         c2pool_we,
    output wire [10:0]  c2pool_addr,  // {output_bank_sel, write_addr[9:0]}
    output wire [127:0] c2pool_din,   // 16 OC × 8b packed

    // Handshake (양방향, 1-cycle pulse, 모두 registered)
    input  wire         prior_wdone,  // Conv1 → Conv2 (image 준비됨)
    output wire         rdone,        // Conv2 → Conv1 (input bank 비움) — DRAIN entry 직후
    input  wire         succ_rdone,   // Maxpool → Conv2 (output bank 비움)
    output wire         wdone         // Conv2 → Maxpool (output bank 준비됨) — DRAIN exit 직전
);
```

**c2pool_addr 하위 10-bit (`write_addr`) 주의**:
- engine 내부의 별도 카운터. c2pool_we pulse 마다 +1.
- FSM 의 `output_pixel_cnt` 와 **다름** — `output_pixel_cnt` 는 PE input 시점, `write_addr` 는 c2pool write 시점 (pipeline 12 cycle 후).
- DRAIN→DONE 시 0 으로 reset (다음 image 의 ping-pong bank 첫 픽셀부터 쓰기).

**rdone/wdone 발생 정확 cycle** (`conv2_timing.md §4.1` / `§8.3` 참조):
- `rdone`: 마지막 ADV (cycle 1784) 의 다음 cycle (1786). DRAIN entry 후 안전하게 input bank 해제.
- `wdone`: 마지막 c2pool write (cycle 1795 edge) 의 다음 cycle (1796). DRAIN exit edge 직전.

---

## 6. 검증 전략

### 6.1 단위 검증

| Stage | 대상 | 방법 |
|---|---|---|
| 1 | `pe_cell` SIMD packing | 2²⁴ exhaustive (`scripts/header_hex_gen/conv2_simd_pack.py` 의 verification 함수 통과) |
| 2 | `krow_ic_adder_tree` | random 입력, golden 비교 |
| 3 | `kcol_accumulator` | 3-cycle pattern, kw_phase=0/1/2 |
| 4 | `truncate_relu` | 경계값 (±127, ±128) + random |
| 5 | `weight_loader` | BMG read 와 PE broadcast 의 3-stage delay 정합성 |
| 6 | `conv2_fsm` | cycle trace 가 `conv2_timing.md §7` verification anchors A1~A11 와 일치 |

### 6.2 통합 검증 (`conv2_engine`)

| Stage | 대상 | 방법 |
|---|---|---|
| 7 | 1 image bit-exact | 입력/weight/expected 를 dump → testbench 가 driving + 비교 (vs `scripts/golden_sim/0_reference.py` 의 `fmap2[0]`) |
| 8 | Multi-image pipelining | 연속 2~3 image, ping-pong bank toggle, rdone/wdone 순서 검증 |
| 9 | Cycle count | 1 image = 1,796 cycle, 2 image = 1,796 + N (N = bank stall 가능) |

---

## 7. Testbench 외부 의존성

`conv2_engine` 은 외부 모듈 (실제 Conv1, Maxpool, CSR, BMG IP) 과 핸드셰이크. testbench 가 이들의 역할을 emulate 해야 함:

### 7.1 외부에서 주어야 하는 데이터

| 데이터 | 크기 | 생성 위치 | 인터페이스 |
|---|---|---|---|
| Conv2 weight (pre-packed) | 576 × 32-bit | `scripts/header_hex_gen/conv2_simd_pack.py` (.hex) | testbench 가 `c2w_ena`/`c2w_addra`/`c2w_dina` 로 LOAD_WEIGHTS 전 또는 BMG `INIT_*` 로 직접 |
| Conv1 출력 = Conv2 입력 (8 IC × 26 × 26 INT8) | 5,408 byte | `scripts/golden_sim/0_reference.py` (fmap1 dump 추가 필요) | testbench 의 virtual Conv1 이 c1c2 BRAM bank 에 write |
| Conv2 expected output (16 OC × 24 × 24 INT8) | 9,216 byte | `scripts/golden_sim/0_reference.py` (fmap2 dump) | testbench 가 c2pool BRAM 내용과 cycle-end 에 비교 |

### 7.2 외부 신호 driving 시퀀스 (single image)

```
[Reset]
   ↓ rst=0 (release)
   ↓
[Weight load 단계] testbench 가 c2w_ena/addra/dina 로 576 word write
   ↓
   ↓ csr.start pulse (1 cycle)
   ↓
[engine LOAD_WEIGHTS] (576 + 2 drain = ~578 cycle, 내부 자동)
   ↓
[engine DONE, prior_wdone 대기]
   ↓
[testbench 의 virtual Conv1] c1c2 BRAM bank 0 에 입력 image write
   ↓ 1-cycle prior_wdone pulse
   ↓
[engine PIPELINE_FILL → compute → DRAIN] (~1,796 cycle)
   ↓                              ↓
   ↓                          (cycle ~1796) wdone pulse
   ↓                              ↓
   ↓                          (testbench virtual Maxpool 이 c2pool 읽음 → succ_rdone pulse)
   ↓
   ↓ (cycle ~1786) rdone pulse → testbench virtual Conv1 이 다음 image 준비 가능
   ↓
[engine DONE 복귀, 다음 image prior_wdone 대기]
```

### 7.3 외부 모듈 emulation 요구사항

- **Virtual Conv1**: c1c2 BRAM bank 에 입력 데이터 write (모든 IC 8개를 64b/word 로 packed format). `input_bank_sel` 과 반대 bank 에 write 후 `prior_wdone` 1-cycle pulse. 다음 `rdone` 받을 때까지 추가 write 없음 (ping-pong 한쪽만 사용).
- **Virtual Maxpool**: `wdone` 받으면 c2pool BRAM bank 의 데이터 검증. 검증 완료 후 `succ_rdone` 1-cycle pulse (ping-pong bank 비움 알림).
- **Virtual CSR**: 시스템 시작 시 `start` 1-cycle pulse 1번 (LOAD_WEIGHTS 진입용).
- **c1c2 BRAM 모델**: SDP, L=2 (Primitive Output Register Enable). 11-bit addr, 64-bit data, 2 bank × 26×26 = 1352 entry 중 676 entry × 2 bank 사용.
- **c2pool BRAM 모델**: SDP, 11-bit addr, 128-bit data, 2 bank × 576 entry.
- **conv2_weight_bram BMG 모델**: SDP, 32-bit dual port, 576 depth, Port B Primitive Output Register Enable, Byte Write Disable. **REGCEB 는 conv2_engine 에서 상수 1 로 묶음** (마지막 weight 까지 출력 reg 통과 보장).

### 7.4 검증 anchor

- 각 cycle 의 register 값 dump 후 `conv2_timing.md §7` anchors A1~A11 과 비교 (특히 cycle 56, 57, 125, 129, 1775, 1784, 1795, 1796, 1797).
- 1 image 처리 후 c2pool BRAM 내용 = `scripts/golden_sim/0_reference.py` 의 `fmap2[0]` 와 bit-exact.

---

## 8. 참조 문서

- **`conv2_timing.md`** — cycle-by-cycle 분석 + verification anchors + testbench 매핑 + 컴팩트 부록 표. timing 의 single source of truth.
- **`../../CONV2_TIMING_FIX.md`** — c1c2 BRAM L=1 → L=2 fix 의 cycle-by-cycle 증명.
- **`conv2_adder_drain_bug_fix.md`** — adder_tree `en` window 누락 bug 의 분석 및 수정 (image 28 에서 발견된 마지막 2 픽셀 오염).
- **`../../docs/DSP48E1_signed8x8_SIMD_Packing.md`** — SIMD packing 알고리즘.
- **`conv2_engine.v`** — top-level 코드. sub-module 인스턴스화, delay pipeline, c2pool write/handshake 생성.
- **`conv2_fsm.v`** — FSM 코드. 헤더 주석에 상태 전이 + 카운터 의미 상세.
- **`weight_loader.v`** — weight 적재 cycle 정합성 (3-stage delay 매칭).
- **`scripts/golden_sim/0_reference.py`** — Python reference, expected output 생성.
- **`scripts/header_hex_gen/conv2_simd_pack.py`** — weight pre-pack, SIMD exhaustive verification 포함.

---

## 9. 명명 규칙 (이 모듈 한정)

| Prefix / suffix | 의미 |
|---|---|
| `prior_*` | upstream (Conv1) 으로부터 / 으로 |
| `succ_*` | downstream (Maxpool) 으로부터 / 으로 |
| `*_done` | 1-cycle pulse, image 1개 단위 완료 |
| `*_bank_sel` | ping-pong bank index (1-bit) |
| `kw_cnt` (FSM) / `sel` (PE) | K_col index (0/1/2). 같은 개념 — 미래에 한 이름으로 통일 권장. |
| `row_cnt`, `col_cnt` | BRAM read raster 좌표 (cap @ 25) |
| `output_pixel_cnt` (FSM) | 완성된 출력 픽셀 수 (0..576). PE input 시점. |
| `c2pool_write_addr` (engine) | c2pool BRAM 의 다음 write 주소 (0..575). c2pool_we 마다 +1, pipeline 12 cycle 후 도착. |
