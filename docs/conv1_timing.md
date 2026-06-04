# Conv1 Pipeline Timing & Overclock Refactor

> ★ **상태(2026-06-04): 프로젝트는 200MHz 에서 timing MET** (impl WNS +0.011). 아래 "300MHz" 는 이 리팩터링의 **원래 목표**이며 — L=2 + adder 4-stage 파이프라인은 그 목표를 위해 도입됐고 200MHz 에 충분한 마진으로 유지된다. 전체 오버클럭 여정과 200MHz 마감 근거: `docs/overclock_journey_100_to_200mhz.md`.

`conv1_engine` 의 cycle-by-cycle 타이밍 single source of truth.
`conv2_timing.md` 와 같은 역할 — BRAM L / pipeline depth / FSM 수정 시 파급 효과 추적용.

본 문서는 **오버클럭 (원래 목표 300MHz → 최종 200MHz, target `xc7a100t-csg324-1`, speed grade −1)** 작업의 conv1 파트를 기록한다.
maxpool 의 동일 패턴(`bram_c2_to_pool` L=1→L=2 + `maxpool_fsm` phase +1) 과 일관.

> **표의 모든 셀은 "해당 cycle 시작 시점의 register 값"** (= 직전 edge 에서 latch 된 값). 조합 신호는 그 cycle 의 register 값으로 즉시 계산.

관련 문서: [[conv1_design]] (아키텍처), [[conv1_timing_table]] (bank race 분석), [[block_memory_generator]] (BMG 설정), [[conv2_timing]] (L=2 선례).

---

## 0. 한 줄 요약

| 항목 | 변경 전 (L=1, adder 1-stage) | 변경 후 (L=2, adder 4-stage) |
|---|---|---|
| `bram_input` Port B | L=1 (no output reg) | **L=2 (Primitives Output Register)** |
| `conv1_adder_tree` | 1-stage 조합 9입력 가산 | **4-stage pipeline (1 add-level/stage)** |
| 입력 read latency 보상 | — | +1 cycle |
| adder latency 보상 | — | +3 cycle |
| `conv1_fsm` `OUT_DELAY` (valid_sr 깊이) | 6 | **10** (= L + N + 4 = 2 + 4 + 4) |
| `conv1_fsm` `FLUSH_LEN` | 6 (= OUT_DELAY, drain 2-short ⚠️) | **12** (= OUT_DELAY + 2, drain 완전) |
| 엔진 `we_pipe` / `ch_final` / `bank_sel_pipe` | 3 / 1 / 3 | **무변경** (tr_out 하류) |

핵심: 입력 BRAM 에 output register 를 넣고(L=2), 9입력 가산기를 4-stage 로 파이프라인 → conv1 의 두 임계 경로(BRAM read→fabric, 9입력 조합 가산)를 끊어 300MHz 대응. 늘어난 datapath latency(총 +4 cycle)는 `conv1_fsm` 의 valid_sr 깊이(OUT_DELAY)와 FLUSH 길이만 조정해 흡수. **데이터패스 정렬 구조(round0=ch_final, round1=tr_out 직결)는 그대로 유지.**

---

## 1. 데이터패스와 pipeline 깊이

```
   in_bram_addr (= in_addr counter, FSM row/col 과 lockstep)
        │
        ▼  BMG read latency L  (L=1 → +1 / L=2 → +2)
   in_bram_dout
        │
        ▼  window_register latch (+1)
   k0..k8 (3×3 window)  ← "window ready" @ T_addr + (L+1)
        │
        ▼  pe_cell × 18  (DSP AREG→MREG→PREG + output reg = 4 stage)
   mul0/mul1 (17-bit)
        │
        ▼  conv1_adder_tree  (N stage: 변경 전 1, 변경 후 4)
   sum0/sum1 (24-bit)
        │
        ▼  truncate_relu (+1)
   tr_out0..3 (8-bit)   ← tr_out @ T_addr + (L+1) + 4 + N + 1 = T_addr + L + N + 6   (RUN1)
        │
        ▼  ch_final latch (+1, round0 전용)
   ch0_final..ch3_final
        │
        ▼  we_pipe / addr_pipe / sel_pipe / bank_sel_pipe × 3 stage
   c1c2_we, c1c2_addr, c1c2_din
        │
        ▼
   c1c2 BMG write
```

**핵심 latency 식** (T_addr = in_addr 가 해당 입력 픽셀 주소를 발행하는 cycle, = FSM counter 가 그 픽셀을 가리키는 cycle, lockstep):

| 신호 | RUN1 (round0) latency | RUN2 (round1) latency |
|---|---|---|
| window ready | T_addr + (L+1) | T_addr + (L+1) + 1 |
| mul (pe out) | T_addr + L + 5 | T_addr + L + 6 |
| sum (adder out) | T_addr + L + N + 5 | T_addr + L + N + 6 |
| **tr_out** | **T_addr + L + N + 6** | **T_addr + L + N + 7** |
| ch_final | T_addr + L + N + 7 | (미사용) |

> RUN2 가 RUN1 보다 **+1 cycle 늦은** 이유는 §2 참조 (LBRST 진입 비대칭). 이 +1 을 round0=ch_final / round1=tr_out 직결로 흡수.

`window_register` formula (conv2_timing §1.2 와 동일):
`win_r2[2] @ T = mem[counter @ (T − L − 1)]` → 주소 발행 후 `L+1` cycle 에 window 의 newest 픽셀이 win_r2[2] 도달.

---

## 2. 두 라운드 정렬 비대칭 (round0 = ch_final, round1 = tr_out 직결)

RUN1(sel=0, oc0~3)과 RUN2(sel=1, oc4~7)는 같은 datapath 를 쓰지만 **RUN2 의 데이터가 RUN1 보다 정확히 1 cycle 늦게 정렬**된다.

- RUN1 은 `LOAD → RUN1` 으로 진입 (load_done edge 에서 pipe_en 1).
- RUN2 는 `FLUSH1 → LBRST → RUN2` 로 진입 (LBRST 에서 pipe_en=0, lb_rst=1 로 line_buffer/window 클리어 후 재시작).

이 entry 경로 차이(LBRST 1 cycle 삽입)로 RUN2 의 in_addr 스트림이 FSM 제어 대비 1 cycle 밀린다. (entry 비대칭이라 L·N 과 무관 — 데이터패스 깊이를 바꿔도 +1 은 유지.)

**엔진의 보상** (`conv1_engine.v` §9~§10):

| Round | 데이터 소스 | 효과 |
|---|---|---|
| round0 (RUN1) | `ch_final` (= tr_out 1-cycle 지연 latch) | tr_out(T_addr+L+N+6) → ch_final(T_addr+L+N+7) |
| round1 (RUN2) | `tr_out` 직결 | tr_out(T_addr+L+N+7) 그대로 |

두 경우 모두 **데이터가 write cycle 에 T_addr + L + N + 7 에 정렬**. → 같은 `we_pipe`/`addr_pipe`(3-stage) 제어로 둘 다 정확히 write.

> ⚠️ 이 round0/round1 구조는 L·N 변경과 **독립** — 본 refactor 에서 **건드리지 않는다**.

---

## 3. 제어 정렬 (OUT_DELAY + we_pipe = 데이터 latency)

- `conv1_fsm` : `pixel_valid` (@ T_addr) → `out_valid` = valid_sr 를 **OUT_DELAY** 단 지연.
- `conv1_engine` : `out_valid` → `c1c2_we` = we_pipe 를 **3** 단 지연.
- 따라서 write cycle = T_addr + OUT_DELAY + 3.

데이터(ch_final/tr_out)는 write cycle 에 T_addr + L + N + 7 에 도착해야 하므로:

```
OUT_DELAY + 3 = L + N + 7   →   OUT_DELAY = L + N + 4
```

| 구성 | L | N | OUT_DELAY | 비고 |
|---|---|---|---|---|
| 변경 전 | 1 | 1 | **6** | 현재 conv1_fsm PIPE_DELAY=6 ✓ (probe 검증) |
| 변경 후 | 2 | 4 | **10** | valid_sr 깊이 10 |

엔진의 `we_pipe`(3) / `ch_final`(1) / `sel_pipe`(3) / `addr_pipe`(3) / `bank_sel_pipe`(3) 는 모두 **무변경**. (tr_out 하류라 L·N 영향 없음.)

---

## 4. Drain 분석 (마지막 픽셀) — 잠재 버그 + 수정

FLUSH 는 `pipe_en=1` 을 유지해 마지막 valid 픽셀 데이터가 datapath 끝(tr_out)까지 흐르게 한다. pe/adder/trunc 각 stage 는 `en=pipe_en` 게이팅.

**drain 요구**: RUN2 마지막 픽셀 (25,25) 의 tr_out 이 그 write 전에 유효해야 함 → `pipe_en=1` 이 trunc 의 마지막 latch edge 까지 유지.
- RUN2 (25,25): tr_out @ T0 + L + N + 7 (T0 = scan_done = (27,27) 발행 cycle). trunc latch edge = (T0+L+N+6)→(T0+L+N+7) → **pipe_en=1 @ T0 + L + N + 6** 필요.
- FLUSH 는 pipe_en=1 을 T0 + FLUSH_LEN 까지 유지 → **FLUSH_LEN ≥ L + N + 6 = OUT_DELAY + 2**.

### 4.1 변경 전의 잠재 off-by-one (probe 로 확정)

변경 전 `FLUSH_LEN = PIPE_DELAY = OUT_DELAY = 6` < 요구치 8 (= L+N+6 = 1+1+6). → **2 short.**

`tb_conv1_engine` probe (single image, T0 = scan_done @ cycle 1851):

```
c=1851 RUN2 scan_done (counter=(27,27))      pipe_en=1
c=1857 pipe_en 마지막 1 (= T0+6)             out_valid 마지막 1
c=1858 state→DONE, pipe_en=0                 tr_out FREEZE (마지막 fresh latch = edge 1857→1858)
c=1858 write addr=823=(25,23)  ← tr_out fresh = (25,23) ✓
c=1859 write addr=824=(25,24)  ← tr_out FROZEN=(25,23) ✗  (should be (25,24))
c=1860 write addr=825=(25,25)  ← tr_out FROZEN=(25,23) ✗  (should be (25,25))
```

→ RUN2 마지막 2 픽셀 (25,24),(25,25) 가 frozen tr_out 으로 corrupt.
**single/multi TB 에서 안 잡힌 이유**: MNIST 코너가 background → conv→ReLU = 0. expected c1c2 의 row 25 전체 = `0000000000000000` → masked. (conv2 adder drain bug 가 image 28 에서야 잡힌 것과 동일 mechanism.)

### 4.2 변경 후 수정

`FLUSH_LEN = OUT_DELAY + 2 = L + N + 6` 으로 설정 → 마지막 픽셀까지 완전 drain.
- 테스트 벡터(코너 0)에서는 결과 동일(0) → bit-exact 유지.
- 코너 nonzero 이미지에서는 **올바르게** 계산 (변경 전 버그 수정).
- 추가 FLUSH cycle 은 out_valid=0 구간이라 extra write 없음 — 무해. (in_addr 는 다음 image 의 load_start 에서 리셋.)

FLUSH1(RUN1, round0) 도 같은 FLUSH_LEN 사용. RUN1 drain 요구는 L+N+5 (round0 가 1 적음) 이므로 1-cycle 여유 — 무해.

---

## 5. 300MHz 변경 상세

### 5.1 `bram_input` L=1 → L=2 (Primitives Output Register)

- Artix-7 −1 BRAM 정격 Fmax 388MHz 는 **output register 전제**. L=1(core reg only) 은 BRAM clock-to-out ~2.3ns + window 캡처 경로가 300MHz(3.33ns) 에서 negative slack.
- L=2 → clock-to-out ~0.45ns 로 단축, ~+1.8ns 슬랙 (maxpool c2pool 와 동일 근거).
- sim model (`TB/models/bmg_sim_models.v`): core read reg (ENB gated) + output reg (REGCEB tied 1, 항상 follow) — `bram_c2_to_pool` L=2 모델과 동일 스타일.
- **Vivado IP 재생성 (수동 PENDING)**: Port B Primitives Output Register ✓ Enable, REGCEB 미체크(내부 tie-1).

### 5.2 `conv1_adder_tree` 1-stage → 4-stage

9입력 signed 가산(17-bit → 24-bit)을 1 cycle 조합으로 처리 → Artix-7 −1 300MHz 에서 4 add-level 경로가 임계. conv2 `krow_ic_adder_tree`(24:1, 5-stage) 와 동일 철학으로 **1 add-level/stage** 파이프라인:

```
Stage 1: 9 → 5   s1[0]=m0+m1, s1[1]=m2+m3, s1[2]=m4+m5, s1[3]=m6+m7, s1[4]=m8(sign-ext)   18-bit
Stage 2: 5 → 3   s2[0]=s1[0]+s1[1], s2[1]=s1[2]+s1[3], s2[2]=s1[4]                          19-bit
Stage 3: 3 → 2   s3[0]=s2[0]+s2[1], s3[1]=s2[2]                                              20-bit
Stage 4: 2 → 1   sum  =s3[0]+s3[1]                                                            21→24-bit
```

- 각 stage `en=pipe_en` 게이팅. latency 1 → 4 (+3).
- 포트 시그니처(mul0_0..8, mul1_0..8, sum0, sum1) **무변경** → conv1_engine 결선 그대로.
- 두 그룹(g1: sum0, g2: sum1) 독립 동일 구조.

---

## 6. `conv1_fsm` 파라미터 유도 요약

| localparam | 변경 전 | 변경 후 | 식 |
|---|---|---|---|
| `PIPE_DELAY` (= OUT_DELAY, valid_sr/row_sr/col_sr/sel_sr 깊이) | 6 | **10** | L + N + 4 = 2 + 4 + 4 |
| `FLUSH_LEN` (FLUSH1/FLUSH2 길이) | 6 (= PIPE_DELAY) | **12** | OUT_DELAY + 2 = L + N + 6 |
| `flush_cnt` 폭 | [2:0] | **[3:0]** | FLUSH_LEN−1 = 11 > 7 |

- valid_sr/row_sr/col_sr/sel_sr 는 `[0:PIPE_DELAY-1]` 로 PIPE_DELAY 따라 자동 확장.
- FLUSH 비교를 `flush_cnt == FLUSH_LEN-1` 로 (PIPE_DELAY 와 분리).

---

## 7. Verification anchors (iverilog, 검증 완료)

| # | TB | 구성 | 결과 | compute |
|---|---|---|---|---|
| V0  | tb_conv1_engine      | 변경 전 (L=1, N=1) | **0/1024 PASS** | 1624 cyc |
| V0b | tb_conv1_conv2_multi | 변경 전           | **40/40, 0/23040 PASS** | avg 1855 |
| V1  | tb_conv1_engine      | B1 (L=2, N=1)     | **0/1024 PASS** | 1630 cyc (+6 FLUSH) |
| V2  | tb_conv1_engine      | 최종 (L=2, N=4)   | **0/1024 PASS** | 1636 cyc |
| V3  | tb_conv1_conv2_multi | 최종 (L=2, N=4)   | **40/40, 0/23040 PASS** | avg 1861 |
| V4  | probe (최종)          | drain 정확성       | **확인** (아래) | — |

### 7.1 V4 — RUN2 마지막 픽셀 drain (probe trace, 최종 L=2/N=4)

```
c=1857  RUN2 scan_done (counter=(27,27)=T0)     pipe_en=1  out_valid=1
c=1858  FLUSH2 fc=0                              pipe_en=1
...
c=1869  FLUSH2 fc=11 (= FLUSH_LEN-1)             pipe_en=1  ← 마지막 pipe_en=1 (= T0+12)
c=1870  DONE, pipe_en=0                          write addr=825=(25,25)  ← tr_out fresh latch @ edge 1869→1870
```

- RUN2 (25,25): tr_out fresh @ T0 + L+N+7 = T0+13 = 1870. trunc latch edge (1869→1870) 에서 **pipe_en=1 @ 1869** → (25,25) 가 자기 값으로 latch (frozen 아님). write(round1, tr_out 직결) @ 1870 = 정확.
- 변경 전(L=1): pipe_en=1 이 T0+6 까지만 → (25,24),(25,25) 가 frozen tr_out 으로 corrupt (코너 0 이라 masked). → **본 refactor 로 수정됨** (§4).
- RUN1(round0)은 drain 요구가 1 적어 1-cycle 여유.

---

## 8. 변경 이력

| 날짜 | 변경 |
|---|---|
| 2026-06-01 | 초안. 300MHz refactor: bram_input L=1→L=2 + conv1_adder_tree 1→4-stage. conv1_fsm OUT_DELAY 6→10 (= L+N+4), FLUSH_LEN 6→12 (= OUT_DELAY+2, drain off-by-one 수정). 엔진 we_pipe/ch_final/bank_sel_pipe 무변경. iverilog V0~V4 bit-exact 검증 완료 (single 0/1024, multi 40/40). probe 로 현재/신규 타이밍 모두 cycle-exact 확정. Vivado bram_input IP 재생성 (Port B Primitives Output Register Enable) PENDING. |
