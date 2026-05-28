# Conv1 하드웨어 가속기 설계 문서

## 1. 전체 개요

Conv1은 LeNet 계열 CNN의 첫 번째 합성곱 레이어를 FPGA에서 가속하는 하드웨어입니다.

| 항목 | 값 |
|------|-----|
| 입력 | 28×28, 1채널, signed 8-bit |
| 출력 | 26×26, 8채널, signed 8-bit |
| 커널 | 3×3, 패딩 없음 |
| 활성화 | ReLU |
| 파이프라인 레이턴시 | 6사이클 |

> 패딩이 없으므로 출력 크기 = 28 - 3 + 1 = **26×26**

---

## 2. 모듈 구성 한눈에 보기

```
conv1_engine (최상위)
├── conv1_fsm              ← 전체 타이밍/상태 제어
├── conv1_weight_loader    ← 가중치 BRAM → PE 적재
├── conv1_line_buffer ×2   ← 행 지연 FIFO (1행, 2행 지연)
├── conv1_window_register  ← 3×3 슬라이딩 윈도우
├── conv1_pe_cell ×18      ← DSP48E1 곱셈기 (9개씩 2그룹)
├── conv1_adder_tree ×2    ← 9개 곱 합산
└── conv1_truncate_relu    ← 우측 시프트 + ReLU + 포화
```

### 각 모듈 한 줄 요약

| 모듈 | 역할 |
|------|------|
| `conv1_fsm` | IDLE→LOAD→RUN1→FLUSH1→LBRST→RUN2→FLUSH2→DONE 상태 전환, 모든 제어 신호 생성 |
| `conv1_weight_loader` | 시작 신호를 받으면 weight BRAM에서 36개 가중치를 읽어 18개 PE에 분배 |
| `conv1_line_buffer` | 깊이 27의 순환 FIFO — 1클럭 입력이 28사이클 뒤에 출력 (1행 지연) |
| `conv1_window_register` | 3행×3열 레지스터 배열, 매 사이클 왼쪽으로 시프트하며 슬라이딩 윈도우 유지 |
| `conv1_pe_cell` | DSP48E1 1개로 두 가중치(W0, W1)와 픽셀 X의 곱을 동시에 계산 (4사이클 레이턴시) |
| `conv1_adder_tree` | 9개 PE 곱셈 결과를 1사이클에 모두 더해 채널별 부분합 생성 |
| `conv1_truncate_relu` | 24-bit 합산 결과를 10비트 우측 시프트 → ReLU → 8-bit 포화 |

---

## 3. 두 라운드(Round) 방식

출력 채널이 8개인데 PE 그룹은 2개(각 9개 PE)밖에 없습니다. 따라서 입력 이미지를 **두 번** 스캔합니다.

```
Round 1 (sel=0): oc0, oc1, oc2, oc3 계산  →  ch0~ch3 출력 BRAM에 기록
Round 2 (sel=1): oc4, oc5, oc6, oc7 계산  →  ch4~ch7 출력 BRAM에 기록
```

각 PE 셀은 `w_regs[0]`(Round 1용 가중치)과 `w_regs[1]`(Round 2용 가중치)을 모두 보유하고, `sel` 신호로 어느 가중치를 사용할지 선택합니다.

---

## 4. 파이프라인 단계별 레이턴시

```
입력 픽셀 (BRAM)
      │
      ▼  [1사이클] BRAM 읽기 레이턴시
  line_buffer / window_register  ← 3×3 윈도우 완성
      │
      ▼  [3사이클] DSP48E1 내부 파이프라인 (AREG→BREG→MREG→PREG)
  conv1_pe_cell (mul0, mul1)
      │  [+1사이클] PE 출력 레지스터
      ▼
  conv1_adder_tree               ← 9개 곱 합산 [1사이클]
      │
      ▼
  conv1_truncate_relu            ← 시프트+ReLU [1사이클]
      │
      ▼  [출력 레지스터 1사이클]
  ch_final (ch0~ch3 또는 ch4~ch7)

총 파이프라인 지연 = 6사이클
```

FSM은 이 6사이클 딜레이를 고려하여 `pixel_valid`, `out_row`, `out_col`, `out_sel` 신호를 **6단계 시프트 레지스터**로 함께 지연시킵니다.

---

## 5. 모듈 간 신호 흐름

### 5-1. conv1_fsm → 전체

FSM이 생성하는 주요 제어 신호:

| 신호 | 방향 | 설명 |
|------|------|------|
| `load_start` | → weight_loader | 가중치 적재 시작 펄스 (1사이클) |
| `pipe_en` | → 모든 모듈 CE | 파이프라인 동작 인에이블 |
| `sel` | → pe_cell | 0=Round1, 1=Round2 가중치 선택 |
| `lb_rst` | → line_buffer, window_register | RUN2 시작 전 버퍼 클리어 |
| `out_valid` | → engine 내부 | 현재 픽셀이 유효한 출력 픽셀인지 (row≥2, col≥2) |
| `out_row/col` | → engine | 6사이클 지연된 출력 좌표 |
| `out_sel` | → engine | 6사이클 지연된 라운드 선택 신호 |
| `done` | → 외부 | 전체 conv1 완료 펄스 |

### 5-2. 입력 데이터 경로

```
in_bram_dout (8-bit)
    │
    ├──────────────────────────────────→ window_register.row2_in  (최신 행)
    │
    └──→ line_buffer #1 (DEPTH=27)
              │  (28사이클 뒤)
              ├─────────────────────→ window_register.row1_in  (1행 전)
              │
              └──→ line_buffer #2 (DEPTH=27)
                        │  (56사이클 뒤)
                        └─────────→ window_register.row0_in  (2행 전)
```

`line_buffer` 하나의 깊이가 27인 이유: 28픽셀 1행을 저장하되 읽기/쓰기가 동시에 일어나므로 `DEPTH = 28 - 1 = 27`.

### 5-3. 가중치 로딩 경로

```
weight BRAM (32-bit × 36 addr)  (18개 PE  ×  2라운드(w_regs[0], w_regs[1])  =  36개 addr)
    │  (addr 0~35, 2사이클 BRAM 레이턴시)
    ▼
conv1_weight_loader
    │
    ├── pe_packed_w [24:0]  브로드캐스트 → 18개 pe_cell 전체
    ├── pe_load_en  [17:0]  1-hot 인코딩 → 해당 PE만 수신
    └── pe_load_idx [0]     0=w_regs[0], 1=w_regs[1]
```

가중치 패킹 규칙: `packed_w = W1 × 2^17 + W0` (W0, W1 각 signed 8-bit)  
→ DSP가 한 번의 곱셈으로 `W0×X`(하위 17비트)와 `W1×X`(상위 17비트)를 동시에 계산.

### 5-4. PE 그룹 구성

```
9개 PE (gen_g1): kx[0]~kx[8] × {w_regs[sel] 의 W0, W1}
    → mul0_g1[0~8], mul1_g1[0~8]
    → adder_tree_g1 → sum0_g1(oc0/oc4), sum1_g1(oc1/oc5)

9개 PE (gen_g2): kx[0]~kx[8] × {w_regs[sel] 의 W0, W1}
    → mul0_g2[0~8], mul1_g2[0~8]
    → adder_tree_g2 → sum0_g2(oc2/oc6), sum1_g2(oc3/oc7)
```

Round 1(`sel=0`)이면 g1 → oc0/oc1, g2 → oc2/oc3  
Round 2(`sel=1`)이면 g1 → oc4/oc5, g2 → oc6/oc7

### 5-5. 출력 파이프라인 동기화 (conv1_engine 섹션 9)

데이터 경로와 제어 경로의 지연을 맞추기 위해 engine 내부에 3단 시프트 레지스터를 둡니다.

```
FSM 신호 (out_valid, out_sel, out_row/col)
    │
    ├── addr_pipe[0→1→2]  : 출력 주소 = out_row×26 + out_col
    ├── we_pipe  [0→1→2]  : write enable
    └── sel_pipe [0→1→2]  : 라운드 구분
         │ (3단 후)
         ▼
    out_addr, out_we, out_sel_r  (최종 출력 포트)
```

> **Round 2 1클럭 보정**: ch4~ch7은 `ch_final` 레지스터 대신 `tr_out0~3` 직출력을 사용합니다.  
> 이유: Round 2 데이터가 레지스터에 캡처되는 타이밍이 Round 1보다 1클럭 늦게 정렬되기 때문에, 레지스터 이전 단계의 값을 직접 연결하여 상쇄합니다.

---

## 6. FSM 상태 전환 다이어그램

```
IDLE ──(start)──→ LOAD ──(load_done)──→ RUN1
                                          │
                                     (scan_done=784사이클)
                                          │
                                        FLUSH1 ──(6사이클)──→ LBRST ──(1사이클)──→ RUN2
                                                                                      │
                                                                               (scan_done)
                                                                                      │
                                                                                    FLUSH2 ──(6사이클)──→ DONE ──→ IDLE
```

|  상태  | pipe_en | sel | lb_rst | 설명 |
|------  |---------|-----|--------|------|
| IDLE   |    0    |  0  |    0   | start 대기 |
| LOAD   |    0    |  0  |    0   | 가중치 적재 완료 대기 |
| RUN1   |    1    |  0  |    0   | 28×28 스캔, oc0~3 계산 |
| FLUSH1 |    1    |  0  |    0   | 마지막 픽셀 파이프라인 드레인 (6사이클) |
| LBRST  |    0    |  1  |    1   | line_buffer/window_register 클리어 (1사이클) |
| RUN2   |    1    |  1  |    0   | 28×28 재스캔, oc4~7 계산 |
| FLUSH2 |    1    |  1  |    0   | 마지막 픽셀 파이프라인 드레인 (6사이클) |
| DONE   |    0    |  -  |    0   | done 펄스 1사이클 후 IDLE |

1.IDLE
아무것도 안 함. start 신호 대기

2.LOAD
load_start 펄스 발생 → weight_loader가 BRAM에서 가중치 읽기 시작
load_done 올 때까지 대기 (약 40사이클)
pipe_en=0 → 파이프라인 멈춤

3.RUN1
pipe_en=1, sel=0
row/col 카운터가 돌면서 28×28=784 픽셀 순서대로 스캔
scan_done(row=27, col=27)이 되면 FLUSH1으로

4.FLUSH1
pipe_en=1 유지 — 마지막 픽셀이 파이프라인 끝까지 흘러가게
6사이클 카운트 후 LBRST로
row/col은 0으로 리셋

5.LBRST
lb_rst=1 1사이클 — line_buffer와 window_register를 클리어
RUN1에서 남은 데이터가 RUN2를 오염시키지 않도록
sel=1로 변경, pipe_en=0

6.RUN2
pipe_en=1, sel=1
동일한 28×28 픽셀 재스캔
이번엔 w_regs[1] 가중치 사용 → oc4~7 계산

7.FLUSH2 / DONE

FLUSH1과 동일하게 6사이클 드레인
DONE에서 done=1 펄스 1사이클
---

## 7. truncate_relu 연산 상세

```
sum (24-bit signed)
    │
    ▼  >>> 10  (산술 우측 시프트)
  sh (14-bit signed)
    │
    ▼  sat_relu 함수
      if sh > 127  →  127
      if sh < 0    →  0      ← ReLU
      else         →  sh[7:0]
    │
    ▼
  out (8-bit signed)
```

시프트 양 10비트의 의미: 가중치와 픽셀 값을 정수로 곱했을 때 발생하는 스케일 오프셋을 정규화.

---

## 8. 주요 타이밍 수치 정리

|          항목         |      값      |
|-----------------------|--------------|
|   1회 스캔 사이클 수   | 784 (28×28)  |
|    FLUSH 사이클 수     |      6      |
|    LBRST 사이클 수     |      1      |
| 가중치 적재 사이클 수   | ~40 (BRAM 2사이클 레이턴시 포함) |
| 전체 실행 사이클 (대략) | 40 + 784 + 6 + 1 + 784 + 6 + 1 ≈ **1622사이클** |
|    유효 출력 픽셀 수    | 26×26 = 676개 × 8채널 |

---

## 9. 파일 목록

| 파일 | 모듈 |
|------|------|
| `conv1_engine_2.v` | `conv1_engine` (최상위) |
| `conv1_fsm.v` | `conv1_fsm` |
| `conv1_weight_loader.v` | `conv1_weight_loader` |
| `conv1_line_buffer.v` | `conv1_line_buffer` |
| `conv1_window_register.v` | `conv1_window_register` |
| `conv1_pe_cell.v` | `conv1_pe_cell` |
| `conv1_adder_tree_1.v` | `conv1_adder_tree` |
| `conv1_truncate_relu.v` | `conv1_truncate_relu` |
