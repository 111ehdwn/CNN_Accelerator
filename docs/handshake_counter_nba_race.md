# NBA Register Race in Handshake Counters

> **Lesson learned**: 같은 cycle 의 transition signal 로 update 되는 NBA register 값을 같은 cycle 안에서 condition 으로 사용할 때 발생하는 race. 4-way handshake (`prior_diff` / `after_diff`) 같은 counter-driven FSM 에서 흔히 나타남.

---

## 1. 한 줄 요약

`prior_diff` 같은 **NBA register 의 update** 가 일어나는 같은 cycle 에 `data_ready = (prior_diff < 0)` 같은 **combinational condition** 으로 다른 state machine 의 transition 을 결정하면, register 의 **이전 cycle 값** 을 보고 잘못된 결정을 내림.

---

## 2. 발견 경위

| TB | 결과 |
|----|------|
| `tb_maxpool_engine.v` (single image) | PASS |
| `tb_maxpool_engine_multi.v` (40 image standalone) | PASS |
| `tb_conv1_conv2_maxpool_multi.v` (40 image integration) | **img 0 PASS, img 1~ FAIL** |

Integration TB 에서만 발현된 이유 — 뒤의 §6 에서 설명.

증상:
- img 1 의 `mismatch = ~115/144` (= 거의 모든 pixel)
- maxpool 의 image 1 wdone (cyc 5984) 가 conv2 의 image 1 wdone (cyc 6066) **보다 82 cycle 빠름** → maxpool 이 conv2 가 아직 c2pool 에 write 안 한 영역을 read

---

## 3. Root cause — NBA timing

### 3.1 관련 코드 (수정 전)

```verilog
// maxpool_fsm.v
reg signed [2:0] prior_diff;
wire data_ready = (prior_diff < 3'sd0);

// counter update (NBA)
always @(posedge clk) begin
    case ({rdone, prior_wdone})
        2'b10:   prior_diff <= prior_diff + 3'sd1;
        2'b01:   prior_diff <= prior_diff - 3'sd1;
        default: prior_diff <= prior_diff;
    endcase
end

// FSM (NBA)
always @(posedge clk) begin
    case (state)
        IDLE: if (data_ready && output_avail) state <= RUN;
        ...
        DONE: begin
            rdone <= 1'b1;
            wdone <= 1'b1;
            state <= IDLE;
        end
    endcase
end
```

### 3.2 NBA (`<=`) 의 timing 의미

```verilog
always @(posedge clk) begin
    x <= rhs;
end
```

cycle T 의 `posedge clk` 에서:

1. RHS evaluate — `x` 의 값은 **이전 cycle 의 값** 봄
2. 결과를 NBA queue 저장
3. 같은 time step 의 모든 always block 실행
4. Time step 끝에 LHS update

→ cycle T 동안 다른 logic 들은 **여전히 이전 cycle 의 `x` 값** 을 본다. 새 값은 cycle T+1 부터 visible.

### 3.3 Race 시나리오

```
state machine flow:  RUN → FLUSH → DONE → IDLE → (data_ready check) → RUN/IDLE
                                    ▲         ▲
                                    │         │
                                    rdone <=1 (NBA)
                                              ▲
                                              prior_diff 평가 시 stale value
```

세부 timing:

| Cycle | state | rdone (reg) | prior_diff (reg) | NBA update (이 cycle 끝) |
|-------|-------|-------------|-------------------|--------------------------|
| T-1   | DONE  | 0           | -1                | rdone<=1, state<=IDLE    |
| **T** | **IDLE** | **1**    | **-1 ★**          | **case{1,0}→prior_diff<=0** |
| T+1   | ???   | 0           | 0                 | -                        |

cycle T 의 IDLE state 에서:
- `data_ready = (prior_diff < 0) = (-1 < 0) = TRUE` ★ stale!
- `if (data_ready) state <= RUN` → NBA 로 cycle T+1 에 RUN 진입

같은 cycle T 의 다른 `always` block 은:
- `case ({rdone, prior_wdone}) = {1, 0} = 2'b10` → `prior_diff <= prior_diff + 1 = 0` (NBA)

→ cycle T+1 에 둘 다 적용: `state = RUN`, `prior_diff = 0`. 너무 늦음. RUN 진입은 이미 결정 났음.

### 3.4 결과적 effect

maxpool 이 image i 끝나자마자 (DONE state 다음 cycle) 즉시 image i+1 RUN 진입. 그러나 conv2 가 image i+1 의 c2pool write 끝나기 전이면 maxpool 이 stale 데이터 read.

---

## 4. Anti-pattern

```verilog
// ❌ Race-prone
reg signed [2:0] cnt;
wire ready = (cnt < 0);

always @(posedge clk) cnt <= /* trigger 기반 update */;
always @(posedge clk) begin
    if (state == IDLE && ready) state <= NEXT;  // ready 가 stale cnt 봄
end
```

`cnt` 의 update trigger 와 `ready` 가 평가되는 cycle 이 **같은 cycle** 이면 race. 한 시점 차이로 NBA-적용-전 값을 봐서 잘못된 transition.

---

## 5. Fix — Combinational "next" value

### 5.1 패턴

```verilog
// ✅ Race-free
reg signed [2:0] cnt;
reg signed [2:0] cnt_next;

always @(*) begin
    case ({trigger_up, trigger_down})
        2'b10:   cnt_next = cnt + 1;
        2'b01:   cnt_next = cnt - 1;
        default: cnt_next = cnt;
    endcase
end

wire ready = (cnt_next < 0);    // ★ next value 기준 평가

always @(posedge clk) cnt <= cnt_next;
```

`ready` 가 "이번 cycle 의 trigger 가 반영된 후의 `cnt`" 를 봄. NBA timing 무관하게 항상 정확.

### 5.2 적용된 코드 (`maxpool_fsm.v`)

```verilog
reg signed [2:0] prior_diff, after_diff;
reg signed [2:0] prior_diff_next, after_diff_next;

always @(*) begin
    case ({rdone, prior_wdone})
        2'b10:   prior_diff_next = prior_diff + 3'sd1;
        2'b01:   prior_diff_next = prior_diff - 3'sd1;
        default: prior_diff_next = prior_diff;
    endcase
    case ({wdone, succ_rdone})
        2'b10:   after_diff_next = after_diff + 3'sd1;
        2'b01:   after_diff_next = after_diff - 3'sd1;
        default: after_diff_next = after_diff;
    endcase
end

wire data_ready   = (prior_diff_next < 3'sd0);
wire output_avail = (after_diff_next < 3'sd2);

// register update — next value 그대로 NBA
always @(posedge clk) begin
    prior_diff <= prior_diff_next;
    after_diff <= after_diff_next;
end
```

위 패턴이면 cycle T 의 `rdone=1` 이 즉시 `prior_diff_next` 에 반영되어 `data_ready = (0 < 0) = FALSE` → IDLE→RUN 안 함. 정상.

---

## 6. 왜 standalone TB 에서는 PASS?

`tb_maxpool_engine_multi.v` (standalone, 40 images PASS) 와 integration TB 의 차이:

| 항목 | standalone | integration |
|------|-----------|-------------|
| `maxpool.prior_wdone` source | TB process 가 명시적 `pulse_prior_wdone()` | `conv2.wdone` direct wire |
| backpressure | TB 가 `wait((i - rdone_count) < 2)` 로 명시 제어 | conv2 의 자체 후속 image timing 따름 |
| `prior_wdone` pulse 시점 | TB 가 maxpool.rdone 완료 후 한참 뒤에 pulse | conv2 의 자체 timing — image i+1 의 wdone 가 maxpool 의 image i RUN 시점 부근에 발생 가능 |

Race 발생 조건: maxpool 의 IDLE 진입 cycle 에 `prior_diff = -1` 이라야. 그러려면 conv2.wdone (= prior_wdone) 가 이전에 발생했어야.

- **standalone**: TB 가 prior_wdone pulse 후 maxpool RUN 시작. maxpool 끝 → IDLE → prior_diff = 0 (정상 update). 다음 prior_wdone pulse 시점이 IDLE 한참 후 → race 없음.
- **integration**: conv2 가 image i 처리 끝나면 maxpool 의 image i 가 RUN 시작. conv2 가 image i+1 처리 → image i+1 의 wdone 가 maxpool 의 image i DONE state 시점 부근에 발생. **timing 우연**으로 race window 에 들어감.

→ Race 가 architectural 가 아니라 **timing 으로만 발현** 됨. 그래서 standalone 검증으로는 못 잡음.

---

## 7. 일반화

### 7.1 비슷한 패턴 (project 내)

| 모듈 | counter | 영향 받는 condition | 현재 상태 |
|------|---------|---------------------|-----------|
| `maxpool_fsm.v` | `prior_diff`, `after_diff` | `data_ready`, `output_avail` | **✅ Fixed** |
| `conv2_fsm.v` | `prior_diff`, `after_diff` | `data_ready`, `output_avail` | ⚠️ 동일 패턴, 우연히 PASS — fix 권장 |
| `fc_fsm.v` | `prior_diff` | `data_ready` | **✅ Fixed** (2026-05-29). FC 는 DRAIN+DONE 9-cycle buffer 로 false-positive race 는 원래 없음; 단 `start && data_ready` 패턴 때문에 `prior_wdone`+`start` 동시 cycle 시 **start 손실** (false-negative) race 존재했음 → next-value 평가로 봉쇄. |

→ conv2/fc 도 같은 패턴 적용하면 미래 wiring 변경 시 안전.

### 7.2 더 일반적인 원칙

> **State machine 의 transition 결정에 쓰이는 condition 이 같은 cycle 의 transition trigger 에 의해 update 되는 register 값을 본다면, 그 register 의 next value 를 combinational 으로 계산해서 봐야 한다.**

이건 Mealy machine 의 정의 그대로:
- **Moore**: output/transition 이 현재 state 만 봄 → race 없음
- **Mealy**: output/transition 이 input 변화 (= 같은 cycle 의 trigger) 도 봄 → race-free 하려면 next value 평가 필요

`prior_diff < 0` 같은 register-based condition 은 사실 Mealy-like (current state + current input → next transition). 이 경우 register 의 "input 반영 후 값" 을 봐야.

### 7.3 다른 라이브러리 패턴 비교

같은 issue 가 다음 패턴에도 나타날 수 있음:
- FIFO empty/full flag + write/read 가 같은 cycle 발생
- Credit-based flow control 의 credit counter
- Pipeline stage 의 valid flag 가 stall signal 과 same cycle

대부분 standard FIFO IP 등은 `empty_next` / `full_next` combinational 으로 노출해서 같은 race 회피.

---

## 8. 검증 방법 (이번 case)

Race 를 찾은 디버그 방법:

1. **Symptom 확인**: integration TB FAIL pattern 의 cycle 분석 (per-image cycle 차이)
2. **TB 에 handshake event monitor 추가**: 매 `wdone`/`rdone` pulse 마다 print
3. **TB 에 SNAP monitor 추가**: 200 cycle 마다 `c2pool write_in_img` / `read_in_img` 진행도 print
4. **Cycle 비교**: maxpool 의 image i+1 wdone vs conv2 의 image i+1 wdone 비교 → 시간 역전 발견
5. **RTL 시뮬레이션 trace**: maxpool 의 IDLE→RUN transition cycle 에서 `prior_diff` 와 `rdone` 값 동시 print → race 확정

```verilog
// 디버그 monitor 예시
always @(posedge clk) begin
    if (rst_n && (maxpool.fsm.state == IDLE) && /* next-cycle 진입 조건 */) begin
        $display("[DBG] cyc=%0d : IDLE→RUN check, prior_diff=%0d (next=%0d), rdone=%b, prior_wdone=%b",
                 cycle_cnt,
                 maxpool.fsm.prior_diff, maxpool.fsm.prior_diff_next,
                 maxpool.fsm.rdone, maxpool.fsm.prior_wdone);
    end
end
```

---

## 9. 체크리스트 — Race-free handshake counter 작성 시

- [ ] Counter 자체는 NBA register 로 유지 (synthesis 호환)
- [ ] Counter 의 next value 를 별도 `always @(*)` 또는 `assign` 으로 combinational 계산
- [ ] Condition (`ready` / `available` 등) 은 **next value** 기준 평가
- [ ] Register update 는 `cnt <= cnt_next` 로 (DRY + race-free)
- [ ] Standalone TB 만으로는 race 못 잡을 수 있음 — integration TB 또는 random handshake stress test 권장

---

## 관련 파일

- `RTL/maxpool/maxpool_fsm.v` — fix 적용
- `RTL/conv2/conv2_fsm.v` — 동일 패턴, fix 권장
- `RTL/fc/fc_fsm.v` — 동일 패턴, fix 권장
- `TB/multi_img/tb_conv1_conv2_maxpool_multi.v` — race 발견 TB
