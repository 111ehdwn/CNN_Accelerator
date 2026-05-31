# Conv1 Pipeline Timing Table & Bank Race Analysis

> **Lesson learned**: conv1 의 c1c2 write pipeline 전체 깊이 = `valid_sr` (6) + `we_pipe` (3) = **9 cycle**. 그런데 FSM 의 `PIPE_DELAY = 6` (FLUSH 길이) 은 valid_sr 만 반영. 마지막 we_pipe 의 trailing 3 cycle 의 write 가 wdone pulse **이후** 발생 → multi-image bank toggle 환경에서 race 발생.

관련 문서: [[handshake_counter_nba_race]] (다른 NBA race 케이스).

---

## 1. 한 줄 요약

Conv1 의 RUN2 scan_done 이후 마지막 c1c2 write 는 **scan_done + 9 cycle** 에 발생.
그런데 wdone pulse 는 FLUSH2 (= `PIPE_DELAY` = 6 cycle) 직후의 DONE state 에서 발생 → wdone register 값이 **scan_done + 8 cycle** 에 1 이 됨.
wdone 을 trigger 로 `bank_sel` 을 토글하면 **마지막 write 와 bank_sel flip 이 같은 cycle** 에 일어남 → write 가 잘못된 bank 에 들어감.

---

## 2. Conv1 모듈 구성과 pipeline 깊이

```
   in_bram_addr (FSM row/col)
        │
        ▼  (BMG read latency 1)
   in_bram_dout
        │
        ▼  line_buffer × 2 (DEPTH=27, 각 1 stage register)
   lb1_out, lb2_out
        │
        ▼  window_register (1 stage)
   k0..k8 (9-element 3×3 window)
        │
        ▼  pe_cell × 18 (DEPTH=2 → 내부 4 stage; design 문서)
   mul0/mul1 (17-bit signed)
        │
        ▼  conv1_adder_tree × 2 (1 stage)
   sum0/sum1 (24-bit signed)
        │
        ▼  truncate_relu (1 stage)
   tr_out0..3 (8-bit signed)
        │
        ▼  ch_final (1 stage latch — round 0 용)
   ch0_final..ch3_final
        │
        ▼  we_pipe / addr_pipe / sel_pipe × 3 stage
   c1c2_we, c1c2_addr, c1c2_din
        │
        ▼
   c1c2 BMG write
```

### 2.1 두 갈래의 지연 보정 신호

| 신호                 | stage | 보상하는 부분                                   |
|----------------------|-------|------------------------------------------------|
| `valid_sr`           | 6     | pe_cell (4) + adder_tree (1) + truncate_relu (1) |
| `we_pipe / addr_pipe`| 3     | ch_final (1) + 추가 alignment (2)              |
| **합계**             | **9** | pixel_valid → c1c2_we 의 총 cycle 차            |

> ⚠️ FSM 의 `PIPE_DELAY = 6` 은 **valid_sr 만 반영**. FLUSH 단계가 `we_pipe` 의 trailing 3 cycle 을 drain 하지 못함.

---

## 3. RUN2 → DONE 전이 시점 cycle-by-cycle 표

기준 시점: RUN2 의 마지막 pixel (scan_done) cycle 을 `T0` 로 잡음.
(img 0 의 실제 trace: `T0 = 2430`.)

| Cycle    | state    | pipe_en | pixel_valid | valid_sr[5] (out_valid) | we_pipe[2] (c1c2_we) | wdone | wdone_count | bank_sel | 비고                                            |
|----------|----------|---------|-------------|--------------------------|----------------------|-------|-------------|----------|-------------------------------------------------|
| T0       | RUN2     | 1       | 1           | (가운데 trailing 1들)    | 1                    | 0     | i           | i[0]     | scan_done. NBA: state←FLUSH2, rdone←1           |
| T0+1     | FLUSH2#0 | 1       | 0           | 1                        | 1                    | 0     | i           | i[0]     | rdone=1 (1-cycle pulse)                         |
| T0+2     | FLUSH2#1 | 1       | 0           | 1                        | 1                    | 0     | i           | i[0]     | rdone=0. rdone_count → i+1 register update      |
| T0+3     | FLUSH2#2 | 1       | 0           | 1                        | 1                    | 0     | i           | i[0]     |                                                 |
| T0+4     | FLUSH2#3 | 1       | 0           | 1                        | 1                    | 0     | i           | i[0]     |                                                 |
| T0+5     | FLUSH2#4 | 1       | 0           | 1                        | 1                    | 0     | i           | i[0]     |                                                 |
| T0+6     | FLUSH2#5 | 1       | 0           | **1 (last 1)**           | 1                    | 0     | i           | i[0]     | flush_cnt == PIPE_DELAY-1. NBA: state←DONE, pipe_en←0 |
| T0+7     | DONE     | 0       | 0           | 0                        | 1                    | 0     | i           | i[0]     | NBA: wdone←1, state←IDLE                        |
| T0+8     | IDLE     | 0       | 0           | 0                        | 1                    | **1** | i           | i[0]     | wdone register=1. wdone_count update queued     |
| **T0+9** | LOAD     | 0       | 0           | 0                        | **1 (last 1)**       | 0     | **i+1**     | **(i+1)[0]** | ⚠️ **마지막 c1c2_we=1 이 이 cycle 에 발생. 그런데 bank_sel 이 이미 flip!** |
| T0+10    | LOAD     | 0       | 0           | 0                        | 0                    | 0     | i+1         | (i+1)[0] | c1c2 write 종료. 다음 image weight load 시작     |

### 3.1 핵심 관찰

`T0+9` cycle 에 동시 발생:
- `we_pipe[2] = 1` (= `out_valid` at `T0+6` = 1) → 마지막 c1c2 write
- `wdone_count` register update (wdone=1 at T0+8 의 다음 edge) → `bank_sel = (i+1)[0]`
- → write addr 의 bank bit 가 **i+1** 이 됨

`addr_pipe[2]` at `T0+9` = `{out_row, out_col}` at `T0+6` = `{row, col}` at `T0` (= scan_done) 에 -2 보정 = `{25, 25}`.

→ **(row=25, col=25, bank=i+1) 위치에 image i 의 마지막 pixel round-1 데이터가 기록됨.** Image i+1 의 c1c2 bank 가 corrupt 됨.

---

## 4. Bank 동작 시뮬레이션 (multi-image)

`bank_sel = conv1_wdone_count[0]` (handshake counter derive) 가정.

| Image i | scan_done | wdone register=1 | bank_sel flip cycle | 마지막 write cycle | 마지막 write 의 bank | 의도된 bank | 결과            |
|---------|-----------|------------------|---------------------|-------------------|--------------------|------------|-----------------|
| 0       | T0        | T0+8             | **T0+9**            | **T0+9**          | **1**              | 0          | bank=1 의 (25,25) 위치 오염 |
| 1       | T1        | T1+8             | **T1+9**            | **T1+9**          | **0**              | 1          | bank=0 의 (25,25) 위치 오염 |
| 2       | T2        | T2+8             | **T2+9**            | **T2+9**          | **1**              | 0          | bank=1 의 (25,25) 위치 오염 |
| ...     | ...       | ...              | ...                 | ...               | ...                | ...        | ...             |

매 image 의 마지막 round-1 write 가 **다음** image 의 bank 를 한 pixel 오염.

### 4.1 왜 image 0 만 PASS 했는가?

Image 0 의 마지막 write 는 bank=1 에 들어감 → image 1 의 c1c2 bank 에 (row=25, col=25) round-1 데이터 잘못 기록.
하지만 image 0 자신의 bank=0 은 영향 없음 → conv2 가 image 0 의 c1c2 bank=0 read 시 모두 정상 → maxpool 결과 정상.

Image 1 부터는 자신의 c1c2 bank 가 이미 image 0 의 마지막 write 로 오염됨 → conv2 가 image 1 의 c1c2 read 시 (25,25) 위치에서 잘못된 데이터 사용 → conv2 의 3×3 convolution 으로 인해 인접 9 pixel 의 conv2 출력이 영향 받음 → 그 영향이 maxpool 의 2×2 pool window 로 추가 확산.

### 4.2 왜 single-image TB 는 PASS 했는가?

Single-image TB 는 `bank_sel = 0` 으로 상수. wdone 시점에 bank 가 flip 하지 않음 → 마지막 write 가 같은 bank=0 의 (25,25) 위치에 정상적으로 기록 → 이 단일 write 가 final 결과로 남음 → 오염 없음.

---

## 5. Root cause 요약

1. `valid_sr` = 6 stage 는 pe + adder + trunc 의 데이터 path 길이를 보상.
2. `we_pipe` = 3 stage 는 ch_final + alignment 를 보상.
3. **FSM 의 `PIPE_DELAY = 6` 은 valid_sr 만 반영. we_pipe 의 trailing 3 cycle 은 FLUSH 가 cover 하지 않음.**
4. 결과적으로 wdone pulse 가 마지막 c1c2 write 보다 1 cycle **이전** 에 발생.
5. wdone trigger 로 bank 가 derive 되면 마지막 1 cycle 의 write 가 잘못된 bank 에 들어감.

---

## 6. Fix 옵션 비교

| 옵션 | 변경 범위 | 추가 cycle | 설명 | trade-off |
|------|----------|-----------|------|-----------|
| **A. PIPE_DELAY = 9** | `conv1_fsm.v` (FSM RTL) | +6 cycle / image (FLUSH1 + FLUSH2 둘 다 영향) | FLUSH 가 전체 write pipe 를 drain → wdone 의 의미가 "모든 write 완료" 가 됨 (semantically correct). | 모든 image 마다 +6 cycle. throughput 약간 감소. wdone semantics 가장 깔끔. |
| **B. conv1 내부 bank toggle FF** | `conv1_engine_2.v` (engine RTL) | +0 | `input_bank_sel` / `bank_sel` 을 외부 port → 내부 register 로 이동. rdone / wdone 시점에 conv1 이 자체 토글. **단, 토글 시점을 we_pipe trailing 이후로 정확히 잡거나 또는 `bank_sel` 을 `addr_pipe` 와 같은 3-stage shift 통과** 필요. | TB 단순화. RTL 캡슐화 좋음. 하지만 토글 시점 정확성 검증 필요. |
| **C. bank_sel 3-stage shift register** | `conv1_engine_2.v` | +0 | 외부 `bank_sel` 을 그대로 두되, 내부에서 `bank_sel_pipe` 3-stage shift 후 `c1c2_addr` 에 사용. addr_pipe 와 같은 timing. | port 호환성 유지. 가장 minimal RTL change. |
| **D. external bank_sel 3-cycle delay** | TB (또는 system controller) | +0 | wdone_count 기반 derive 후 3-cycle FF chain 통과 → `bank_sel` 에 인가. | RTL 무변경. 하지만 conv1 사용처마다 같은 패턴 반복 필요. |

### 6.1 선택 — **옵션 B**

옵션 B 가 캡슐화/외부 단순화 측면에서 가장 적절. conv1 이 자기 ping-pong bank 를 스스로 관리하는 것이 가장 자연스러움.

구현 시 주의:
- `bank_sel` 의 토글 시점은 **we_pipe trailing 이후** 여야 함. wdone signal 그 자체 (DONE state) 의 시점에 토글하면 옵션 A 미적용 시 race 발생.
- 안전한 방법: 내부에서 `wdone` 을 3-cycle 지연시켜 `bank_sel_toggle_pulse` 로 사용. 또는 `bank_sel` 을 `addr_pipe` 와 동일한 3-stage shift 라인에 태움.

---

## 7. 관련 design 결정

- `valid_sr` 와 `we_pipe` 의 분리는 round 0 / round 1 의 1-cycle data shift 차이 보정을 위함 (ch_final 1-cycle latch). 자세한 설명은 `conv1_engine_2.v` 의 module header 참조.
- `conv1_adder_tree` 는 conv1 전용 9:2 토폴로지. conv2 와 공유 불가.

---

## 8. 이력

| 날짜       | 사건 |
|------------|------|
| 2026-05-29 | `tb_conv1_conv2_maxpool_multi.v` 에서 img 1+ FAIL 관찰. 1차 TB bank fix (`input_bank_sel = conv1_rdone_count[0]`, `bank_sel = conv1_wdone_count[0]`) 후 img 0 PASS, img 1+ 여전히 FAIL. 이 문서로 root cause 분석. 옵션 B 채택 결정. |
