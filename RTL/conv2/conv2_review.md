# Conv2 코드 검증 보고서

검토 파일: `conv2_fsm.v`, `conv2_engine.v`, `kcol_accumulator.v`, `krow_ic_adder_tree.v`, `weight_loader.v`, `pe_cell.v`, `line_buffer.v`, `window_register.v`, `truncate_relu.v`

---

## 1. Critical / 잠재적 데이터 오염

### 없음
전체 계산 로직(SIMD packing, carry 보정, 누산, truncate/ReLU, 타이밍 정렬)은
코드-문서 간 일치하며 오버플로우도 발생하지 않음. 상세 검증 내역은 §5 참조.

---

## 2. Medium — 보드 투입 전 수정 권장

### M1. `line_buffer.v` — `ptr` 동기 리셋 없음 (실보드 위험)

```verilog
// 현재 코드
reg [ADDR_W-1:0] ptr = {ADDR_W{1'b0}};  // initial value만, rst 없음
```

`rst` 인가 시 `ptr`이 현재 위치에서 멈춘다. 다음 PIPELINE_FILL(57 사이클)이
DEPTH=25 슬롯을 전부 덮어쓰므로 **정상 흐름에서는 무해**하다. 하지만
계산 도중 런타임 리셋(에러 복구, watchdog 등)이 발생하면 다음 이미지의
행 정렬이 어긋날 수 있다.

**수정안**

```verilog
// rst를 포트로 추가하고:
always @(posedge clk) begin
    if (rst) begin
        ptr  <= {ADDR_W{1'b0}};
        dout <= {WIDTH{1'b0}};
    end else if (en) begin
        dout     <= mem[ptr];
        mem[ptr] <= din;
        ptr      <= (ptr == DEPTH-1) ? {ADDR_W{1'b0}} : ptr + 1'b1;
    end
end
```

`conv2_engine.v`에서 lb1_inst, lb2_inst에 `.rst(rst)` 추가 필요.

---

### M2. `krow_ic_adder_tree.v` / `kcol_accumulator.v` — 단일 `en`으로 전 스테이지 게이팅

5단 파이프라인의 모든 스테이지가 **같은** `en` 신호로 동시에 전진/정지한다.
`en`에 빈 구멍(gap)이 생기면 스테이지 간 데이터 정렬이 깨진다.

현재 conv2 설계에서는 `pe_en`(→ `adder_en`, `kcol_en`)이 compute 구간 내내
연속 1이므로 **현재 코드는 안전**하다. 그러나 향후 PAUSE/재시작 기능 추가 시
자동으로 버그가 된다.

**단기 조치**: 설계 제약으로 문서화 (`CLAUDE.md` 또는 주석).
```verilog
// INVARIANT: en must be continuous (no gaps) during one pixel's K_col=0..2 pass.
// Breaking this invariant corrupts pipeline alignment across all 5 stages.
```

---

## 3. Low — 동작 정확성에는 무해하나 주의 필요

### L1. `conv2_engine.v` — `opc_reset_event` 간접 감지

```verilog
wire opc_reset_event = (opc_d1 != 10'd0) && (fsm_output_pixel_cnt == 10'd0);
```

DRAIN→DONE 전이 외에 `output_pixel_cnt`가 0으로 떨어지는 경로가 생기면
`c2pool_write_addr`가 엉뚱한 타이밍에 0 리셋된다.
현재 FSM에는 그런 경로가 없으므로 안전하지만, FSM 수정 시 blind spot이 됨.

**권고**: 명시적 1-cycle FSM 신호(`drain_done_pulse`)를 추가해 리셋 트리거를
FSM이 직접 제어하도록 변경.

---

### L2. `weight_loader_conv2.v` — `c2w_enb`가 DRAIN 1 사이클 동안 HIGH 유지

```verilog
c2w_enb <= (state == LOADING);  // registered → DRAIN 진입 cycle에도 1
```

DRAIN 진입 사이클에 addr=575를 한 번 더 read하지만 값은 동일하므로 무해.
단, `conv2_engine.v`에서 `.regceb(1'b1)` 상수 연결이 **필수**다. 만약
`regceb`를 `enb`에 연결하도록 변경하면 마지막 weight(pe_id=191, slot=2)가
소실된다.

---

### L3. `pe_cell.v` — `p1_raw` 조합 adder가 DSP 외부 critical path에 추가됨

```verilog
wire signed [16:0] p1_raw = p1_slot + carry_corr;  // combinational, DSP 출력 → 출력 레지스터 사이
```

`carry_corr`는 1-bit carry이므로 합성 시 increment 회로 1개로 최적화되나,
180 MHz 타이밍 closure 시 PREG → 출력 레지스터 경로에 추가 지연이 붙는다.
합성 후 타이밍 리포트에서 이 경로를 확인할 것.

---

## 4. Open Items (설계 문서가 미확인으로 명시한 항목)

| # | 항목 | 위험도 | 확인 방법 |
|---|------|--------|-----------|
| O1 | DRAIN 12 사이클 정확성 | **High** — 1 off이면 pixel (23,23) 소실 | testbench에서 첫 c2pool write 사이클 측정 (= PE input cycle + 12) |
| O2 | r=23 마지막 행 lb ptr 정렬 | **High** — win_r0/r1 오정렬이면 모든 r=23 픽셀 오염 | testbench에서 lb 내부 mem dump, cycle 1782의 win_r0/r1 값 검증 |
| O3 | PE → c2pool 실제 lag ±1 | Medium | wdone 발생 사이클 직접 측정 |

### O1 상세: DRAIN 12 사이클 검증 앵커

마지막 PE input: cycle 1784 (ADV, kw=2, pixel (23,23)).
기대 c2pool write: cycle 1784 + 11 = **1795** (c2pool_we_reg=1).
기대 wdone: cycle **1796** (wdone_reg ← 1).
DRAIN d=11: cycle **1796** (→ DONE 전이).

testbench에서 `c2pool_we` 신호의 마지막 pulse cycle이 1795인지 확인.

### O2 상세: r=23 라인버퍼 정렬

타이밍 테이블 §4.1에 따르면 cycle 1782의 PE in col =
`((23,23), (24,23), (25,23))`. 즉 win_r0 = row 23, win_r1 = row 24 데이터 필요.

r=23 구간에서 shift_en=1 event는 24회 (ADV 24회, WRAP 없음). lb1에 26회 필요한
입력 행 전환에 2회 부족. cap으로 동일 값이 2회 추가 입력되는 것으로 보정되는지
lb ptr 레벨에서 cycle-by-cycle 검증 필요 (현재 설계 문서의 미확인 항목).

---

## 5. 정상 동작 확인 항목 (검토 결과 버그 없음)

| 항목 | 결론 |
|------|------|
| SIMD packing P[16:0]/P[32:17] carry 보정 | ✓ W∈[-127,127] → |WX|≤16256 < 2^17, 17-bit safe |
| adder_tree 비트폭 (17→18→19→20→21→22) | ✓ max 24×16256=390144 < 2^22 |
| kcol_acc 24-bit 누산 | ✓ max 3×390144=1170432 < 2^24 |
| truncate_relu sat_relu (val[7:0] 슬라이싱) | ✓ [0,127] 구간에서 상위 6bit=0 보장 |
| PIPELINE_FILL 종료 조건 (row=2, col=4) L=2 | ✓ cycle 56→57 전이, win_r2=[(2,0),(2,1),(2,2)] |
| WRAP 진입 조건 (col_cnt==1, r=0..22) | ✓ cap으로 r=23에서 col_cnt≤25, WRAP 미트리거 보장 |
| output_pixel_cnt WRAP 시 이중 카운트 없음 | ✓ ADV에서 +1 (r,22용), WRAP w=2에서 +1 (r,23용) |
| rdone cycle (1786) | ✓ opc 575→576 전이 다음 cycle |
| wdone cycle (1796) | ✓ write_addr=575 && we=1 다음 cycle |
| drain_cnt 초기값=0 보장 | ✓ rst 또는 이전 DRAIN 종료에서만 0 |
| weight_loader 3-stage ctrl/data 정렬 | ✓ packed_w와 pe_load_en이 cycle T+3에 동시 valid |
| prior_diff/after_diff 3-bit signed 범위 | ✓ ping-pong 2bank → [-2,0] / [0,2] |
| DSP48E1 OPMODE=7'b0000101 | ✓ X=M, Y=M, Z=0 → P=A×B (표준 multiply-only) |
| window_register k0..k8 매핑 → pe_x[kh][ic] | ✓ kh=0→win_r0(row r), kh=2→win_r2(row r+2) |

---

## 6. 검증 우선순위 요약

```
즉시 수정:
  M1 — line_buffer rst 추가 (실보드 안전을 위해)

보드 투입 전 testbench 확인:
  O1 — DRAIN 12 cycle (cycle 1795 c2pool_we 확인)
  O2 — r=23 lb 정렬 (cycle 1782 win_r0/r1 dump)

문서화 후 보류:
  M2 — adder pipeline en gap 제약 주석 추가
  L1 — opc_reset_event 리팩터 (차기 수정 시)
  L2 — regceb 상수 의존성 주석 추가
  L3 — 타이밍 클로저 후 critical path 확인
```
