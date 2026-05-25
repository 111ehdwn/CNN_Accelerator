# Conv2 Cycle-by-Cycle Timing

이 문서는 conv2_engine 의 cycle 별 동작을 표로 기록한다. 용도:

- Testbench 결과 검증 (cycle 별 register 값 1:1 대조)
- Timing 변경 (BRAM L, pipeline depth, FSM 수정) 시 파급 효과 추적
- 미래 디버깅의 single source of truth

**표의 모든 셀은 "해당 cycle 시작 시점에서의 register 값"** 을 나타낸다 (= 직전 edge 에서 latch 된 값). 조합 신호 (`shift_en`, `BRAM addr`, `row2_in`, `dout` 등) 는 그 cycle 의 register 값으로 즉시 계산되는 값.

---

## 0. 약속

### 0.1 좌표 / register 의미

| Symbol | 의미 |
|---|---|
| `(row_cnt, col_cnt)` | c1c2 BRAM 의 입력 raster 좌표. **항상 0 ≤ row_cnt ≤ 25, 0 ≤ col_cnt ≤ 25** (cap 보장). |
| `(R, C)` | 표 셀 안에서 mem 내용 표기. "입력 row R, col C 의 8 IC × 8b 데이터" 의 의미. |
| `X` | uninitialized / don't-care |
| `kw_cnt` | K_col index, 0/1/2 (compute phase 내 cycle 분할: HOLD0=0, HOLD1=1, ADV=2). |
| `wrap_cnt` | COMPUTE_WRAP 내부 cycle 0/1/2. |
| `drain_cnt` | DRAIN state 내부 cycle 0..11. |
| `output_pixel_cnt` | 0..576. 출력 픽셀 완성 카운터 (FSM 과 datapath 공유, c2pool write addr 의 일부). |

### 0.2 c1c2 BRAM (L = 2)

- BMG IP: SDP, common clock, **Primitive Output Register Enable** (Port B 출력 reg 활성).
- `ENA = REGCE = shift_en` (단일 신호 게이팅).
- Edge T → T+1 동작:
  - `shift_en @ T = 1`: `core ← mem[addr @ T]`, `out reg ← (core @ T 의 edge 직전 값)`.
  - `shift_en @ T = 0`: core, out reg 모두 hold.
- `dout @ T = out reg @ T`.

### 0.3 line_buffer / window_register

`line_buffer #(.DEPTH(25))` (`en = shift_en`):

```
en=1 일 때, edge T → T+1 동작:
    dout ← mem[ptr] (= 25 shift_en=1 events 전에 written 된 값)
    mem[ptr] ← din
    ptr ← (ptr == 24) ? 0 : ptr + 1
```

→ 효과적 지연: shift_en=1 event 26 개 = 입력 1 행 (26 columns).

`window_register` (`en = shift_en`): shift_en=1 cycle 의 edge 에 left-shift:

```
win_r2[2] ← row2_in    win_r2[1] ← win_r2[2]    win_r2[0] ← win_r2[1]
win_r1[2] ← row1_in    win_r1[1] ← win_r1[2]    win_r1[0] ← win_r1[1]
win_r0[2] ← row0_in    win_r0[1] ← win_r0[2]    win_r0[0] ← win_r0[1]

row2_in = c1c2_dout     row1_in = lb1.dout     row0_in = lb2.dout
```

`win_r2[i]` 중 i=2 가 newest col, i=0 가 oldest col.

### 0.4 PE → c2pool pipeline depth (참고)

| Stage | Latency (cycle) |
|---|---|
| PE (DSP48E1 4-stage: AREG/BREG/MREG/PREG → output reg) | 4 |
| krow_ic_adder_tree (5-stage pipeline) | 5 |
| kcol_accumulator | 1 |
| truncate_relu | 1 |
| c2pool BRAM write (edge 에서 mem update) | 1 |
| **합계 (PE input @ T → c2pool memory updated at edge T+11→T+12)** | **12** |

### 0.5 FSM (수정 후 — DRAIN 추가, cap 적용)

8 states:

```
IDLE → LOAD_WEIGHTS → DONE ⇄ PIPELINE_FILL → COMPUTE_HOLD ⇄ COMPUTE_ADVANCE
                                                                 ↓
                                                          COMPUTE_WRAP (r=0..22 만)
                                                                 ↓ wrap_cnt=2 후 HOLD
                                                          DRAIN (마지막 ADV 후 12 cycle)
                                                                 ↓
                                                                DONE
```

핵심 동작:

- **Counter cap**: `shift_en=1` cycle 의 edge 에서 `(row_cnt, col_cnt) == (25, 25)` 이면 증가하지 않음 (그대로 (25, 25) hold).
- **WRAP entry**: `state == COMPUTE_ADVANCE && col_cnt == 1` (r=0..22 의 pixel (r, 22) ADV 에서만 fire; r=23 에서는 cap 으로 col_cnt 가 항상 25).
- **DRAIN entry**: `state == COMPUTE_ADVANCE && output_pixel_cnt == 575` (이 ADV 가 마지막 출력 픽셀 (23, 23) 의 K_col=2 cycle. 종료 edge 에서 state ← DRAIN, drain_cnt ← 0, output_pixel_cnt ← 576).
- **DRAIN 내부**: `shift_en = 0`, `pe_en = 0`, `drain_cnt += 1`. `drain_cnt == 11` cycle 의 edge 에서 state ← DONE, 모든 카운터 reset.
- **r=23 에 WRAP 없음**: 24 픽셀 모두 HOLD/HOLD/ADV 로 처리. 가능한 이유는 §6 에서 증명.

### 0.6 Cycle 번호 약속

- **Cycle 0 = PIPELINE_FILL 의 첫 cycle** (DONE → PIPELINE_FILL 전이 직후 첫 cycle). counter @ 0 = (0, 0).
- 절대 cycle 번호는 image 단위로 reset (다음 image 의 cycle 0 = 그 image 의 PIPELINE_FILL 첫 cycle).
- PIPELINE_FILL 동안 shift_en=1 매 cycle → counter 매 cycle 증가. cycle k 의 counter = `(k div 26, k mod 26)`.

---

## 1. PIPELINE_FILL → 첫 compute (cycle 50..62)

### 1.1 BRAM pipeline + counter

| Cycle T | state | counter @ T | shift_en | BRAM addr @ T | BRAM core @ T | dout @ T | row2_in @ T |
|---|---|---|---|---|---|---|---|
| 50 | FILL | (1, 24) | 1 | (1, 24) | (1, 23) | (1, 22) | (1, 22) |
| 51 | FILL | (1, 25) | 1 | (1, 25) | (1, 24) | (1, 23) | (1, 23) |
| 52 | FILL | (2, 0)  | 1 | (2, 0)  | (1, 25) | (1, 24) | (1, 24) |
| 53 | FILL | (2, 1)  | 1 | (2, 1)  | (2, 0)  | (1, 25) | (1, 25) |
| 54 | FILL | (2, 2)  | 1 | (2, 2)  | (2, 1)  | (2, 0)  | (2, 0)  |
| 55 | FILL | (2, 3)  | 1 | (2, 3)  | (2, 2)  | (2, 1)  | (2, 1)  |
| **56** | **FILL (last)** | **(2, 4)** | 1 | (2, 4) | (2, 3) | (2, 2) | (2, 2) |
| 57 | HOLD kw=0 (pixel (0,0)) | (2, 5) | 0 | (2, 5) | (2, 4) | (2, 3) | (2, 3) |
| 58 | HOLD kw=1 | (2, 5) | 0 | (2, 5) | (2, 4) | (2, 3) | (2, 3) |
| 59 | ADV  kw=2 | (2, 5) | 1 | (2, 5) | (2, 4) | (2, 3) | (2, 3) |
| 60 | HOLD kw=0 (pixel (0,1)) | (2, 6) | 0 | (2, 6) | (2, 5) | (2, 4) | (2, 4) |
| 61 | HOLD kw=1 | (2, 6) | 0 | (2, 6) | (2, 5) | (2, 4) | (2, 4) |
| 62 | ADV  kw=2 | (2, 6) | 1 | (2, 6) | (2, 5) | (2, 4) | (2, 4) |

**FSM 전이 trigger**: cycle 56 에서 `(row_cnt, col_cnt) == (2, 4)` 성립 → edge 56→57 에 state ← COMPUTE_HOLD, counter ← (2, 5).

**Hold 구간 BRAM 동작**: cycle 57, 58 의 shift_en=0 → BRAM core, out reg 모두 hold. cycle 59 의 shift_en=1 → edge 59→60 에 core ← mem[(2, 5)], out reg ← (core @ 59 before edge = mem[(2, 4)]).

### 1.2 Window register

`win_r2[i] @ T = (row2_in @ "T 직전 shift_en=1 cycle" latched at the next edge)`. shift_en=0 cycle 동안은 hold. win_r1, win_r0 도 동일 패턴 (row1_in = lb1.dout, row0_in = lb2.dout).

FILL 에서 shift_en=1 매 cycle 이므로 일반식:

```
win_r2[i] @ T = mem[counter @ (T - 3 - (2-i))]   (FILL phase, BRAM L=2)
              = mem[counter @ (T - 5 + i)]
```

(`T-3` 은 BRAM L=2 + window 1-cycle latch. `2-i` 는 newest col → oldest col 의 추가 지연.)

cycle T 의 counter = `(T div 26, T mod 26)`. 따라서:

| Cycle T | win_r2[0] | win_r2[1] | win_r2[2] | 비고 |
|---|---|---|---|---|
| 54 | (1, 23) | (1, 24) | (1, 25) | FILL 중간 |
| 55 | (1, 24) | (1, 25) | (2, 0)  | |
| 56 | (1, 25) | (2, 0)  | (2, 1)  | edge 56→57 직전 |
| **57** | **(2, 0)** | **(2, 1)** | **(2, 2)** | **첫 valid window (HOLD0 of (0, 0))** |
| 58 | (2, 0) | (2, 1) | (2, 2) | hold (shift_en @ 57 = 0) |
| 59 | (2, 0) | (2, 1) | (2, 2) | hold |
| 60 | (2, 1) | (2, 2) | (2, 3) | edge 59→60 latch (HOLD0 of (0, 1)) |
| 61 | (2, 1) | (2, 2) | (2, 3) | hold |
| 62 | (2, 1) | (2, 2) | (2, 3) | hold |
| 63 | (2, 2) | (2, 3) | (2, 4) | HOLD0 of (0, 2) |

**Verification anchor (cycle 57 의 full 3×3 window for output (0, 0))**:

`win_r1[2] @ T = lb1.dout @ T-1`. lb1.dout 은 BRAM stream 보다 1 입력 row (= 26 shift_en=1 events) 지연. FILL 에서 cycle 0 부터 shift_en=1 매 cycle 이므로 lb1.dout @ T = `mem[counter @ T-28]`. lb2.dout @ T = `mem[counter @ T-54]`.

```
Cycle 57 의 window (full 3×3, IC 0):
  win_r0 = [(0, 0), (0, 1), (0, 2)]   ← lb2 chain (row 0, oldest)
  win_r1 = [(1, 0), (1, 1), (1, 2)]   ← lb1 chain (row 1)
  win_r2 = [(2, 0), (2, 1), (2, 2)]   ← BRAM 직결 (row 2, newest)

= 출력 (0, 0) 의 input 9 pixel (입력 row 0..2, col 0..2). ✓
```

→ pixel (r, c) HOLD0/HOLD1/ADV cycle 의 **win_r2 = [(r+2, c), (r+2, c+1), (r+2, c+2)]**. (win_r1 은 row r+1 의 같은 col triplet, win_r0 은 row r 의 같은 col triplet.)

### 1.3 PE 제어 신호 (cycle 57..62)

| Cycle T | state | kw_cnt @ T | sel @ T | col_sel @ T | shift_en | pe_en | PE 가 보는 col_pos | PE weight (K_col=sel) |
|---|---|---|---|---|---|---|---|---|
| 57 | HOLD kw=0 | 0 | 0 | 0 | 0 | 1 | col_pos_0 | K_col=0 (f0, f3, f6) |
| 58 | HOLD kw=1 | 1 | 1 | 1 | 0 | 1 | col_pos_1 | K_col=1 (f1, f4, f7) |
| 59 | ADV  kw=2 | 2 | 2 | 2 | 1 | 1 | col_pos_2 | K_col=2 (f2, f5, f8) |
| 60 | HOLD kw=0 (next pixel) | 0 | 0 | 0 | 0 | 1 | col_pos_0 | K_col=0 |

→ 한 출력 pixel = 3 cycle (HOLD/HOLD/ADV). 매 cycle PE 가 3 K_row × 8 IC × 8 OC_pair × 2 SIMD = 384 곱셈. 3 cycle = 1152 곱셈 = 9 K × 8 IC × 16 OC = 한 출력 pixel 전체.

---

## 2. Steady-state pattern (한 픽셀의 3 cycle)

steady-state 일반식 (r=0..23, c=0..20 에서 row 경계 안 넘는 경우):

| Cycle | state | counter | shift_en | dout @ T | win_r2[0,1,2] @ T (steady-state) | kw_cnt | col_sel | PE input |
|---|---|---|---|---|---|---|---|---|
| T   | HOLD kw=0 | (r+2, 5+c) | 0 | (r+2, c+3) | [(r+2, c), (r+2, c+1), (r+2, c+2)] | 0 | 0 | col_pos_0 = (r+2, c) (row 2 only) |
| T+1 | HOLD kw=1 | (r+2, 5+c) | 0 | (r+2, c+3) | hold (same as T) | 1 | 1 | col_pos_1 |
| T+2 | ADV kw=2 | (r+2, 5+c) | 1 | (r+2, c+3) | hold | 2 | 2 | col_pos_2 |
| T+3 | HOLD kw=0 (next pixel (r, c+1)) | (r+2, 6+c) | 0 | (r+2, c+4) | [(r+2, c+1), (r+2, c+2), (r+2, c+3)] | 0 | 0 | col_pos_0 |

**일반화 invariant (L=2 fix + steady-state)**:

- counter col − win_r2[2] col = **3** (즉 dout 의 col 은 counter col − 1, win_r2[2] 의 col 은 counter col − 3).
- 매 ADV 의 edge 에서 win_r2 가 1 col 진행, dout 이 1 col 진행.

(window 의 row 1 = `win_r1` 은 input row r+1, row 0 = `win_r0` 은 input row r 의 같은 col triplet. lb1, lb2 의 1 행/2 행 delay 결과.)

---

## 3. Row boundary: WRAP for output (0, 23) (cycle 123..132)

전제: pixel (0, 22) ADV (cycle 125) 의 counter (3, 1) 에서 `col_cnt == 1` → WRAP entry. WRAP 3 cycle 후 HOLD for (1, 0).

### 3.1 Cycle 추적

| Cycle T | state | counter @ T | shift_en | kw / wrap | sel | col_sel | dout @ T | win_r2 @ T | 비고 |
|---|---|---|---|---|---|---|---|---|---|
| 123 | HOLD kw=0 (pixel (0, 22)) | (3, 1) | 0 | kw=0 | 0 | 0 | (2, 25) | [(2, 22), (2, 23), (2, 24)] | 출력 (0, 22) 시작 |
| 124 | HOLD kw=1 | (3, 1) | 0 | kw=1 | 1 | 1 | (2, 25) | (hold) | |
| 125 | **ADV  kw=2** | (3, 1) | 1 | kw=2 | 2 | 2 | (2, 25) | (hold) | `col_cnt==1` → next state WRAP. edge: counter (3, 2) |
| 126 | **WRAP w=0** | (3, 2) | 1 | wrap=0, kw=0 | 0 | **0 (WRAP 고정)** | (3, 0) | [(2, 23), (2, 24), (2, 25)] | 출력 (0, 23) K_col=0. PE input = col_pos_0 (= row 0:(0,23), row 1:(1,23), row 2:(2,23)) |
| 127 | **WRAP w=1** | (3, 3) | 1 | wrap=1, kw=1 | 1 | **0** | (3, 1) | [(2, 24), (2, 25), (3, 0)] | 출력 (0, 23) K_col=1. PE input = col_pos_0 (= (?, 24)) |
| 128 | **WRAP w=2** | (3, 4) | 1 | wrap=2, kw=2 | 2 | **0** | (3, 2) | [(2, 25), (3, 0), (3, 1)] | 출력 (0, 23) K_col=2. PE input = col_pos_0 (= (?, 25)). edge: state ← HOLD, counter (3, 5) |
| 129 | HOLD kw=0 (pixel (1, 0)) | (3, 5) | 0 | kw=0 | 0 | 0 | (3, 3) | **[(3, 0), (3, 1), (3, 2)]** | 출력 (1, 0) 시작. window 가 새 row 정렬 |
| 130 | HOLD kw=1 | (3, 5) | 0 | kw=1 | 1 | 1 | (3, 3) | (hold) | |
| 131 | ADV  kw=2 | (3, 5) | 1 | kw=2 | 2 | 2 | (3, 3) | (hold) | |
| 132 | HOLD kw=0 (pixel (1, 1)) | (3, 6) | 0 | kw=0 | 0 | 0 | (3, 4) | [(3, 1), (3, 2), (3, 3)] | |

**Verification anchor**: cycle 129 의 win_r2 = [(3, 0), (3, 1), (3, 2)] — 출력 (1, 0) 의 row 2 (= input row 3, col 0..2). ✓

### 3.2 WRAP 가 하는 일

- `col_sel = 0` 고정: PE 가 항상 col_pos_0 (oldest) 를 봄. cycle 126/127/128 의 win_r2[0] 가 차례로 (2, 23), (2, 24), (2, 25) 로 진행하면서 출력 (0, 23) 의 K_col=0/1/2 contribution 누적.
- `sel = wrap_cnt = 0/1/2`: 같은 PE 가 K_col=0/1/2 의 weight 를 차례로 적용.
- shift_en=1 매 cycle: window 가 1 col 씩 shift, 새 row r+3 (= 3) 의 col 0/1/2 가 win_r2[2] 에 차례로 들어옴 → 다음 row 첫 픽셀 (1, 0) 의 window 정렬 준비.

---

## 4. 마지막 행 (r=23) — cap, no WRAP, DRAIN (cycle 1770..1797)

마지막 행 핵심: counter 가 (25, 25) 에 cap 되어 col_cnt 가 1 이 되지 않으므로 WRAP 트리거 없음. 24 픽셀 모두 HOLD/HOLD/ADV 로 처리.

Cycle 번호: pixel (r, c) HOLD0 cycle = `57 + 72*r + 3*c` for r=0..22; r=23 도 동일 식 (`1713 + 3*c`).

### 4.1 Cycle 추적

| Cycle T | state | counter @ T | shift_en | dout @ T | win_r2 @ T | output_pixel_cnt @ T | 비고 |
|---|---|---|---|---|---|---|---|
| 1770 | HOLD kw=0 (pixel (23, 19)) | (25, 24) | 0 | (25, 22) | [(25, 19), (25, 20), (25, 21)] | 23·24+19 = 571 | 출력 (23, 19) |
| 1772 | ADV  kw=2 | (25, 24) | 1 | (25, 22) | (hold) | 571 | edge: counter (25, 25), output_pixel_cnt → 572 |
| 1773 | HOLD kw=0 (pixel (23, 20)) | **(25, 25)** | 0 | (25, 23) | [(25, 20), (25, 21), (25, 22)] | 572 | 출력 (23, 20) — counter 첫 도달 |
| 1774 | HOLD kw=1 | (25, 25) | 0 | (25, 23) | (hold) | 572 | |
| 1775 | **ADV  kw=2** | (25, 25) | 1 | (25, 23) | (hold) | 572 | edge: counter 증가 시도 → **cap 적용** → (25, 25) 그대로. output_pixel_cnt → 573 |
| 1776 | HOLD kw=0 (pixel (23, 21)) | (25, 25) | 0 | (25, 24) | [(25, 21), (25, 22), (25, 23)] | 573 | 출력 (23, 21). BRAM 이 (25, 25) 재read 시작 |
| 1777 | HOLD kw=1 | (25, 25) | 0 | (25, 24) | (hold) | 573 | |
| 1778 | ADV  kw=2 | (25, 25) | 1 | (25, 24) | (hold) | 573 | edge: cap 유지, output_pixel_cnt → 574 |
| 1779 | HOLD kw=0 (pixel (23, 22)) | (25, 25) | 0 | (25, 25) | [(25, 22), (25, 23), (25, 24)] | 574 | 출력 (23, 22) |
| 1780 | HOLD kw=1 | (25, 25) | 0 | (25, 25) | (hold) | 574 | |
| 1781 | ADV  kw=2 | (25, 25) | 1 | (25, 25) | (hold) | 574 | edge: cap, output_pixel_cnt → 575 |
| 1782 | HOLD kw=0 (pixel (23, 23)) | (25, 25) | 0 | (25, 25) | [(25, 23), (25, 24), (25, 25)] | 575 | **마지막 출력 (23, 23)** |
| 1783 | HOLD kw=1 | (25, 25) | 0 | (25, 25) | (hold) | 575 | |
| **1784** | **ADV  kw=2** | (25, 25) | 1 | (25, 25) | (hold) | 575 | **마지막 PE input cycle**. `output_pixel_cnt == 575` → edge 1784→1785: state ← **DRAIN**, drain_cnt ← 0, output_pixel_cnt → 576 |
| 1785 | DRAIN drain=0 | (25, 25) | 0 | (25, 25) | (hold) | 576 | pipeline 진행 중 (PE 출력은 cycle 1788 에 도착, c2pool write 는 cycle 1796) |
| 1786 | DRAIN drain=1 | (25, 25) | 0 | (25, 25) | (hold) | 576 | |
| ... | DRAIN drain=2..10 | (25, 25) | 0 | (25, 25) | (hold) | 576 | |
| 1796 | DRAIN drain=11 | (25, 25) | 0 | (25, 25) | (hold) | 576 | **마지막 c2pool write 가 edge 1796→1797 에 mem 갱신**. edge: state ← DONE, 모든 카운터 reset |
| 1797 | DONE | (0, 0) | 0 | — | — | 0 | 다음 image 대기 |

**Verification anchors**:

- **Cycle 1775 edge (cap 첫 발동)**: counter 가 (25, 25) → (25, 25) (변화 없음).
- **Cycle 1782 win_r2**: [(25, 23), (25, 24), (25, 25)] — 마지막 출력 (23, 23) 의 input col 23/24/25.
- **Cycle 1784 ADV**: 마지막 PE input. output_pixel_cnt next-edge 값이 576. state next-edge 가 DRAIN.
- **Cycle 1797 DONE 진입**: 모든 카운터 reset. 다음 image 의 PIPELINE_FILL 첫 cycle 이 그 image 의 cycle 0.

### 4.2 Cap 의 정당성 검증

cap 후 BRAM 이 (25, 25) 재read 를 4번 (cycle 1775, 1778, 1781, 1784 의 ADV). 이게 데이터 흐름에 안전한 이유:

- pixel (23, 21) HOLD0 (cycle 1776) 의 win_r2[2] = (25, 23). 이 값은 cycle 1775 의 edge 에서 latch 되었고, row2_in @ 1775 = dout @ 1775 = (25, 23) (= BRAM 이 마지막 정상 read 한 데이터의 pipeline 통과 결과).
- pixel (23, 22) HOLD0 의 win_r2[2] = (25, 24): cycle 1778 edge 에서 latch. row2_in @ 1778 = (25, 24) (= cycle 1775 의 BRAM addr (25, 25) 가 core 에 latch → out reg 에 latch → 이 시점 출력).
- pixel (23, 23) HOLD0 의 win_r2[2] = (25, 25): cycle 1781 edge 에서 latch. row2_in @ 1781 = (25, 25).

→ BRAM pipeline 안에 (25, 23), (25, 24), (25, 25) 가 **마지막 정상 read 들 (cycle 1772, 1775 의 ADV)** 시점에 이미 들어가 있어서 cap 후에도 적시에 win_r2 에 latch 됨. cap 으로 인한 BRAM 의 (25, 25) 재read 는 wasted 이지만 무해.

### 4.3 만약 cap 없으면

cycle 1775 ADV edge → counter (26, 0). cycle 1778 ADV → counter (26, 1) → `col_cnt == 1` 트리거 → WRAP 진입. 그러나 WRAP 는 r=24 행 시작 정렬용인데 r=24 가 없음. BRAM 이 row=26 (입력 영역 밖) 의 garbage 또는 다음 image 의 ping-pong 영역을 read → **다음 image 의 데이터 corrupt 위험**. 따라서 cap 필수.

---

## 5. PE → c2pool pipeline lag (출력 (0, 0) 의 예)

출력 (0, 0) 의 K_col 별 PE input cycle: 57 (K_col=0), 58 (K_col=1), 59 (K_col=2).

| Cycle T | PE input (출력 / K_col) | PE out (lag 4) | adder tree out (lag 9) | kcol_acc out (lag 10) | truncate out (lag 11) | c2pool mem updated (lag 12, edge T-1 → T) |
|---|---|---|---|---|---|---|
| 57 | (0,0) K=0 | — | — | — | — | — |
| 58 | (0,0) K=1 | — | — | — | — | — |
| 59 | (0,0) K=2 | — | — | — | — | — |
| 61 | (0,1) K=1 | (0,0) K=0 | — | — | — | — |
| 62 | (0,1) K=2 | (0,0) K=1 | — | — | — | — |
| 63 | (0,2) K=0 | (0,0) K=2 | — | — | — | — |
| 66 | (0,3) K=0 | (0,1) K=2 | (0,0) K=0 | — | — | — |
| 67 | (0,3) K=1 | (0,2) K=0 | (0,0) K=1 | — | — | — |
| 68 | (0,3) K=2 | (0,2) K=1 | (0,0) K=2 | — | — | — |
| 69 | (0,4) K=0 | (0,2) K=2 | (0,1) K=0 | (0,0) accumulated, **out_valid pulse** | — | — |
| 70 | (0,4) K=1 | (0,3) K=0 | (0,1) K=1 | (0,1) K=0 (= input from this cycle) | (0,0) truncated | — |
| 71 | (0,4) K=2 | (0,3) K=1 | (0,1) K=2 | (0,1) K=1 | — | **(0, 0) c2pool write 가 edge 70 → 71 에 mem 갱신** |

(`kcol_acc out_valid` 는 K_col=2 의 마지막 누적 cycle 에 pulse. truncate_relu 가 이걸 받아 다음 cycle 에 출력.)

(c2pool BRAM write 는 datapath 가 we, addr, din 을 cycle 70 에 set → edge 70 → 71 에 mem 갱신.)

**Verification anchor**: 첫 c2pool write 의 mem 갱신 = 첫 PE input cycle 57 + 14 = cycle 71. (단, 실제 c2pool register 위치에 따라 ±1 cycle 변동 가능 — conv2_engine.v 작성 시 확정.)

---

## 6. r=23 에서 WRAP 미사용 의 정당성 (no-WRAP-for-last-row)

r=0..22 에서 WRAP 가 필요한 이유는 **다음 행 (r+1, 0) 의 window 정렬** 때문. 출력 (r, 23) compute 중에 col_sel=0 으로 고정하면서 새 row r+3 데이터를 동시에 line buffer 에 흘려보내야 함.

r=23 의 경우 다음 행 (r=24) 가 존재하지 않으므로 정렬 불필요. 따라서 출력 (23, 23) 을 HOLD/HOLD/ADV 로 일반 처리 가능. cap 이 효과적으로 다음과 같은 결과를 보장:

- pixel (23, 23) HOLD0 의 win_r2 = [(25, 23), (25, 24), (25, 25)] (= 출력 (23, 23) 의 col 23/24/25)
- HOLD0/HOLD1/ADV 의 PE input 이 차례로 col_pos_0, col_pos_1, col_pos_2 → 출력 (23, 23) 의 K_col=0/1/2 contribution 모두 누적

→ WRAP 없이도 모든 r=23 픽셀이 정확히 계산됨.

---

## 7. Verification anchors 요약

| # | Cycle | 검증 항목 | 기대값 |
|---|---|---|---|
| A1 | 56 | PIPELINE_FILL last cycle | state=FILL, counter (2, 4), shift_en=1 |
| A2 | 57 | 첫 COMPUTE_HOLD cycle | state=HOLD, counter (2, 5), kw_cnt=0, shift_en=0 |
| A3 | 60 | 출력 (0, 1) HOLD0 | win_r2[2] = (2, 3) (= col_pos_2 row 2 of output (0, 1)) |
| A4 | 125 | WRAP entry trigger | counter (3, 1), col_cnt==1 → state next-edge ← WRAP |
| A5 | 129 | WRAP 종료 후 정렬 | win_r2 = [(3, 0), (3, 1), (3, 2)] (= 출력 (1, 0) 의 row 2) |
| A6 | 1775 | Cap 첫 발동 | counter (25, 25) edge → 그대로 (25, 25) (no overflow) |
| A7 | 1782 | 마지막 픽셀 win | win_r2 = [(25, 23), (25, 24), (25, 25)] |
| A8 | 1784 | 마지막 PE input | output_pixel_cnt next-edge = 576. state next-edge = DRAIN |
| A9 | 1796 | DRAIN 종료 | drain_cnt = 11. mem 의 마지막 c2pool write 이 이 edge 에 완료 |
| A10 | 1797 | DONE 진입 | 모든 카운터 reset, 다음 image 대기 |

---

## 8. Open items (다음 검토 / testbench 단계)

- **§5 의 PE → c2pool lag**: conv2_engine.v 작성 시 datapath register 위치 (kcol_acc 와 truncate_relu 사이, output buffer 직전 등에 추가 register 가 있는지) 에 따라 ±1 cycle 변동. 실제 cycle 은 코드 작성 후 본 표를 update.
- **DRAIN cycle 정확값**: 12 가정 (pipeline depth 합). 실제 datapath register 수에 따라 ±1 조정 필요. testbench 의 첫 c2pool write 완료 cycle 측정으로 확정.
- **line_buffer ptr 갱신 순서**: §1.2 의 lb1.dout, lb2.dout 식은 "shift_en=1 매 cycle" 가정. compute phase 에서 shift_en 은 ADV 에만 1 → effective delay 가 26 ADV events = 78 cycles. row 경계 (WRAP) 와 cap 의 영향은 §3, §4 의 trace 와 일치하지만 lb 의 ptr 위치까지 cycle 별로 trace 하지는 않았음. testbench 에서 lb 내부 mem dump 로 검증 권장.

---

## 9. 변경 이력

| Date | Change |
|---|---|
| (TBD, 2026-05-25) | 초안. L=2 fix 가정. DRAIN state 12 cycle. Cap @ (25, 25). r=23 에서 WRAP 미사용. §1.2 의 line buffer 정확 trace 는 open item 으로 남김 (testbench 단계에서 확정). |

