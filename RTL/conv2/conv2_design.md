# Convolution Layer 2 Design Document

**모듈**: `conv2_engine.v`
**버전**: v1.0

---

## 1. 개요

### 1.1 Layer 명세

````
Input:    (8, 26, 26) signed INT8  (Conv1 출력)
Weight:   (16, 8, 3, 3) signed INT8, pre-packed
Output:   (16, 24, 24) signed INT8 (>>10 + saturate + ReLU 후)

Convolution 파라미터:
  Kernel size: 3×3
  Stride: 1
  Padding: 0
````

### 1.2 자원 사용

````
DSP:    192 = K_row(3) × IC(8) × OC_pair(8) × SIMD(2)
LUT:    약 15K (PE array + adder tree + control)
FF:     약 8K
BRAM:   Conv2 weight 1개 + Input ping-pong (외부)
````

---

## 2. PE Array 구조

### 2.1 DSP 분배 (192 PE)

````
PE 배열 차원: K_row × IC × OC_pair = 3 × 8 × 8 = 192 PE
각 PE: SIMD packing으로 2개 OC 동시 처리

한 cycle 동시 연산:
  3 K_row × 8 IC × 8 OC_pair × 2 SIMD = 384 multiplications

K_col은 3-cycle time-multiplexing (PE 내부 weight register 3개)
````

### 2.2 PE 인스턴스

````
pe_cell #(N_WEIGHTS = 3)
  - Weight register: 3개 (K_col 0, 1, 2 각각의 packed Aport)
  - Sel: K_col 선택 (0, 1, 2 순환)
  - mul0, mul1: 17-bit signed output (OC even, OC odd)

→ 192 PE × 3 weight register = 576 weight register slots
````

### 2.3 PE 매핑

````
PE index = (k_row, ic, oc_pair)
  k_row: 0~2 (kernel row)
  ic:    0~7 (input channel)
  oc_pair: 0~7 (output channel pair)

각 PE의 weight register:
  w_regs[0] = pre-packed (W[2*oc_pair, ic, k_row, kw=0], W[2*oc_pair+1, ic, k_row, kw=0])
  w_regs[1] = pre-packed (.., kw=1)
  w_regs[2] = pre-packed (.., kw=2)
````

---

## 3. Window Register 및 Line Buffer (IC별 8 instance)

### 3.1 구조

IC 8개 독립 처리:

````
Per IC:
  line_buffer × 2 (DEPTH=26)
    lb1: 1 row 지연
    lb2: 2 row 지연
  window_register: 3×3 sliding window
  
Total IC=8: 16 line_buffer + 8 window_register
````

### 3.2 데이터 흐름

````
BRAM (c1c2 ping-pong, 8 IC × 8-bit) → 8개 stream
  Per IC stream → lb1 (1 row 지연)
                → lb2 (2 row 지연)
                → 3 row 동시 보유

Window register:
  row 0 (오래된): lb2 출력
  row 1 (중간):  lb1 출력
  row 2 (최신):  BRAM 직접 출력
  
col 0, 1, 2: shift register
  col_2 ← new data (lb/direct)
  col_1 ← prev col_2
  col_0 ← prev col_1
````

---

## 4. K_col Time-Multiplexing 설계

### 4.1 핵심 아이디어

````
한 output pixel 계산 = 3×3 = 9 multiplications/IC × 8 IC = 72 multiplications

전체 unroll 시 192 DSP × 3 K_col = 576 DSP 필요 (자원 초과)
K_col time-mux: 192 DSP × 3 cycle = 1 output pixel
````

### 4.2 매 cycle 동작

````
한 cycle:
  PE 입력: window의 한 col_position (col_sel로 선택)
  PE weight: K_col index (sel로 선택, 0/1/2)
  
3 cycle 동안 같은 output pixel 누적:
  Cycle A: col_sel=0, sel=0 → contribution K_col=0
  Cycle B: col_sel=1, sel=1 → contribution K_col=1
  Cycle C: col_sel=2, sel=2 → contribution K_col=2
````

---

## 5. FSM 설계

### 5.1 상태 정의

````
IDLE             : start 신호 대기 (시스템 시작 + 다음 이미지 대기 통합)
PIPELINE_FILL    : line_buffer + window 초기 fill (~55 cycle)
COMPUTE_HOLD     : compute, window 정지 (2 cycle, K_col 0/1)
COMPUTE_ADVANCE  : compute, window 1 col 진행 (1 cycle, K_col 2 + shift + read)
COMPUTE_WRAP     : compute, row 변경 처리 (3 cycle, K_col 0/1/2 + col_sel 고정)
DONE             : read_done pulse 출력 후 IDLE 복귀
````

### 5.2 상태별 control signal 패턴

````
                  sel       col_sel    shift_en  read_en   pe_en
IDLE              -         -          0         0         0
PIPELINE_FILL     -         -          1         1         0
COMPUTE_HOLD      0, 1      0, 1       0         0         1
COMPUTE_ADVANCE   2         2          1         1         1
COMPUTE_WRAP      0, 1, 2   0          1         1         1
DONE              -         -          0         0         0
````

### 5.3 상태 전이

````
IDLE → PIPELINE_FILL: peer_write_done 도착 (data_ready=1)

PIPELINE_FILL → COMPUTE_HOLD: fill 완료 (첫 valid window 도달)

COMPUTE_HOLD (2 cycle, kcol_phase 0→1) → COMPUTE_ADVANCE

COMPUTE_ADVANCE (1 cycle, kcol_phase 2):
  → COMPUTE_HOLD:  일반 (방금 read한 col != 25)
  → COMPUTE_WRAP:  row boundary (방금 read한 col == 25)
  → DONE:          BRAM bank 끝 도달

COMPUTE_WRAP (3 cycle, kcol_phase 0→1→2) → COMPUTE_HOLD: 다음 output row 시작

DONE → IDLE: read_done pulse 출력 후
````

---

## 6. COMPUTE_WRAP 상세 설계 (Row Boundary 처리)

### 6.1 핵심 통찰

````
일반적 row boundary 처리: PE idle 3 cycle (read만 진행, 누적 결과 무의미)
본 설계: row 마지막 output의 9 곱셈을 3 cycle에 걸쳐 진행
        → PE idle 시간 0
        → 약 70 cycle/image 절감 (row boundary 23회 × 3 cycle)
````

### 6.2 동작 메커니즘

Conv1 output row의 마지막 output pixel을 (r, 23)라 할 때:

````
COMPUTE_ADVANCE의 마지막 read = (r+2, 25)
이후 COMPUTE_WRAP 진입

진입 시 window 상태:
  col_pos_0:  (r,   23), (r+1, 23), (r+2, 23)
  col_pos_1:  (r,   24), (r+1, 24), (r+2, 24)
  col_pos_2:  (r,   25), (r+1, 25), (r+2, 25)

이 window로 output (r, 23) 계산이 가능 → COMPUTE_WRAP에서 진행
````

### 6.3 COMPUTE_WRAP 3 cycle 상세

````
Cycle 0:
  PE input: col_pos_0 = (r, 23), (r+1, 23), (r+2, 23)
  PE weight: sel=0 → w_regs[0] (f0, f3, f6)
  곱셈: f0×(r,23), f3×(r+1,23), f6×(r+2,23) → output (r, 23) K_col=0
  Cycle 끝: read (r+3, 0), shift_en=1
  
Cycle 1 (shift 후 window):
  col_pos_0: (r,   24), (r+1, 24), (r+2, 24)
  col_pos_1: (r,   25), (r+1, 25), (r+2, 25)
  col_pos_2: (r+1, 0),  (r+2, 0),  (r+3, 0)  ← 새 row 3 들어옴
  
  PE input: col_pos_0 = (r, 24), (r+1, 24), (r+2, 24)
  PE weight: sel=1 → w_regs[1] (f1, f4, f7)
  곱셈: f1×(r,24), f4×(r+1,24), f7×(r+2,24) → output (r, 23) K_col=1
  Cycle 끝: read (r+3, 1), shift_en=1

Cycle 2 (shift 후 window):
  col_pos_0: (r,   25), (r+1, 25), (r+2, 25)
  col_pos_1: (r+1, 0),  (r+2, 0),  (r+3, 0)
  col_pos_2: (r+1, 1),  (r+2, 1),  (r+3, 1)  ← 새 col 1 들어옴
  
  PE input: col_pos_0 = (r, 25), (r+1, 25), (r+2, 25)
  PE weight: sel=2 → w_regs[2] (f2, f5, f8)
  곱셈: f2×(r,25), f5×(r+1,25), f8×(r+2,25) → output (r, 23) K_col=2
  Cycle 끝: read (r+3, 2), shift_en=1

→ output (r, 23) 9 multiplications 완료 (K_col 0,1,2 누적)
````

### 6.4 COMPUTE_WRAP 후 상태

````
WRAP 끝난 후 window:
  col_pos_0: (r+1, 0), (r+2, 0), (r+3, 0)
  col_pos_1: (r+1, 1), (r+2, 1), (r+3, 1)
  col_pos_2: (r+1, 2), (r+2, 2), (r+3, 2)

→ 정확히 output (r+1, 0)의 valid window
→ COMPUTE_HOLD 진입하여 output (r+1, 0) K_col=0 시작
````

### 6.5 핵심 차이 요약

````
                col_sel 변화    sel 변화      window 변화
COMPUTE_HOLD     0 → 1          0 → 1         정지
COMPUTE_ADVANCE  2              2             1 col shift + 새 read
COMPUTE_WRAP     0 (고정)       0 → 1 → 2     1 col shift × 3 + 새 read × 3

WRAP은 col_sel을 고정시키고 sel만 변화시켜
이전 row의 마지막 output의 K_col 0/1/2를 진행
````

---

## 7. PE 출력 → Accumulator 데이터 경로

### 7.1 PE Array 출력

````
192 PE × {mul0, mul1} = 384 outputs (17-bit signed each)

차원: K_row(3) × IC(8) × OC_pair(8) × SIMD(2)
````

### 7.2 K_row × IC 합산 (Tree Pipeline)

````
같은 (OC_pair, SIMD) 조합 16개의 24:1 합산:
  - 입력: 24개 17-bit (= K_row 3 × IC 8 of one OC_pair, SIMD slot)
  - 출력: 22-bit signed (17 + log2(24) = 22)

Tree 구조 (5 stage pipeline):
  Stage 1: 12 adders (24 → 12), 18-bit
  Stage 2: 6 adders (12 → 6), 19-bit
  Stage 3: 3 adders (6 → 3), 20-bit
  Stage 4: 2 adders (3 → 2), 21-bit
  Stage 5: 1 adder (2 → 1), 22-bit

Timing: 200 MHz 가능 (5 ns budget 내 각 stage adder)
Throughput: 1 result/cycle

16개 (OC_pair × SIMD) 병렬 instance:
  자원: ~9K LUT (전체 14%)
  Latency: 5 cycle
````

### 7.3 K_col Accumulator

````
3 cycle 동안 K_col 0, 1, 2 결과 누적:
  
Cycle 0 (sel=0): accumulator = krow_ic_sum_kcol0       (22-bit → 24-bit sign-ext)
Cycle 1 (sel=1): accumulator += krow_ic_sum_kcol1      (24-bit + 22-bit)
Cycle 2 (sel=2): accumulator += krow_ic_sum_kcol2      → final sum (24-bit)
                                                       → kcol_sum_valid 출력

비트 폭: 22 + log2(3) = 23.6 → 24-bit signed
인스턴스: 16 (각 OC_pair × SIMD)
````

### 7.4 Truncate + ReLU

````
truncate_relu #(.N(16))
  입력: 24-bit sum × 16 (packed)
  처리: >>>10 → saturate [-128, 127] → ReLU (음수 → 0)
  출력: 8-bit signed × 16 (packed)
  
en: kcol_sum_valid (3 cycle에 1번)
````

---

## 8. Output Buffer Write (c2pool buffer)

### 8.1 Write 데이터

````
16 OC × 8-bit = 128-bit per output pixel
3 cycle에 1 pixel write
````

### 8.2 Buffer 인터페이스

````
c2pool ping-pong buffer (BMG IP, SDP)
  Width: 128-bit (16 OC × 8-bit)
  Depth: 24 × 24 × 2 bank = 1,152

Address: {bank_sel, output_row[4:0], output_col[4:0]}
Bank toggle: c2_write_done pulse 시 internal counter 증가
````

---

## 9. Cycle 분석

### 9.1 전체 latency 추정

````
PIPELINE_FILL: ~55 cycle (line_buffer + window 채우기)

Compute phase:
  Output 576 pixel × 3 cycle = 1,728 cycle
  Row boundary 효과: COMPUTE_WRAP으로 흡수, 추가 stall 없음

Total: ~55 + 1,728 = ~1,783 cycle/image

Pipeline depth (PE → buffer write):
  PE: 4 cycle
  K_row × IC adder tree: 5 cycle
  K_col accumulator: 1 cycle
  Truncate_relu: 1 cycle
  Buffer write: 1 cycle
  Total: ~12 cycle (한 image당 한 번만)

이론 throughput: 1,783 cycle/image @ 180MHz = 9.9 μs/image
10,000 images: ~99 ms (compute only)
````

### 9.2 비교 - row boundary 처리 방식

````
방식 A (단순 stall): row boundary에서 PE idle 3 cycle
  Total: 55 + 1,728 + 23 × 3 (boundary stall) = 1,852 cycle

방식 B (COMPUTE_WRAP, 본 설계): row boundary에서도 compute 진행
  Total: 55 + 1,728 = 1,783 cycle

차이: 69 cycle/image (~4% 성능 향상)
````

---

## 10. 데이터플로우 동기화

### 10.1 Inter-layer Handshake

````
Conv2 ↔ Conv1 (c1c2 BRAM):
  peer_write_done (in): Conv1으로부터, 이미지 N+1 준비됨
  read_done (out): Conv1으로, 이미지 N read 끝, 다음 쓸 수 있음
  
Conv2 ↔ Maxpool (c2pool BRAM):
  write_done (out): Maxpool로, 이미지 N output 준비됨
  peer_read_done (in): Maxpool로부터, 이미지 N output 다 읽음
````

### 10.2 Bank 관리

````
입력 bank (c1c2 BRAM Port B 측):
  consumed_cnt: 자체 카운터 (자기 read_done 시 증가)
  produced_cnt: peer_write_done pulse로 증가
  data_ready = (produced_cnt - consumed_cnt > 0)
  bank_sel = consumed_cnt[0]

출력 bank (c2pool BRAM Port A 측):
  written_cnt: 자체 카운터 (자기 write_done 시 증가)
  consumed_cnt: peer_read_done pulse로 증가
  can_write = (written_cnt - consumed_cnt < 2)
  bank_sel = written_cnt[0]
````

---

## 11. 인터페이스 명세

### 11.1 Module 포트

````verilog
module conv2_engine (
    input  wire         clk,
    input  wire         rst,

    // c1c2 buffer (Port B read)
    output wire         c1c2_re,
    output wire         c1c2_bank_sel,
    output wire [9:0]   c1c2_raddr,
    input  wire [63:0]  c1c2_rdata,        // 8 IC × 8-bit
    input  wire         peer_write_done,   // from Conv1
    output reg          read_done,         // to Conv1

    // c2pool buffer (Port A write)
    output wire         c2pool_we,
    output wire         c2pool_bank_sel,
    output wire [9:0]   c2pool_waddr,
    output wire [127:0] c2pool_wdata,      // 16 OC × 8-bit
    output reg          write_done,        // to Maxpool
    input  wire         peer_read_done,    // from Maxpool

    // Weight BRAM (Conv2 weight)
    output wire [?:0]   c2w_addr,
    input  wire [?:0]   c2w_dout,
    output wire         c2w_en
);
````

### 11.2 외부 신호 의미

````
clk, rst: standard
peer_write_done: Conv1으로부터 1-cycle pulse, 이미지 1장 완료
read_done: Conv2 자체 1-cycle pulse, c1c2 bank 1개 read 완료
write_done: c2pool 출력 1 bank write 완료
peer_read_done: Maxpool으로부터, c2pool bank 1개 read 완료
````

---

## 12. 검증 전략

### 12.1 Testbench 흐름

````
1. PyTorch golden model에서 Conv2 input/weight/output trace 생성
   - 입력: (8, 26, 26) INT8 image (Conv1 출력 시뮬레이션)
   - Weight: (16, 8, 3, 3) INT8 pre-packed (Aport pattern)
   - Expected output: (16, 24, 24) INT8 (truncate_relu 후)

2. Verilog testbench
   - c1c2 BRAM 모델 (1 bank만)
   - Weight BRAM 모델 (pre-packed Aport)
   - Conv2 engine 실행
   - c2pool BRAM 출력 비교 (bit-exact)
   - Cycle count 측정
```` 

### 12.2 검증 단계

````
Stage 1: PE cell exhaustive test (2^24 패턴, 별도 testbench)
Stage 2: K_row × IC adder tree (random input, golden 비교)
Stage 3: K_col accumulator (3 cycle 패턴)
Stage 4: Truncate_relu (경계값 + random)
Stage 5: FSM (각 state 전이 확인)
Stage 6: Conv2 engine 통합 (1 이미지 bit-exact)
Stage 7: Cycle count 확인 (~1,783 cycle)
````

---

## 13. 자원 정리

````
DSP:    192 (전체 240의 80%)
BRAM:   1 (Conv2 weight) + 외부 (c1c2, c2pool buffer)
LUT:    추정 약 15K
  - PE array: ~3K (control logic)
  - K_row × IC adder tree: ~9K (5 stage × 16 instances)
  - K_col accumulator: ~500
  - Truncate_relu: ~200
  - FSM, mux, control: ~2K
FF:     추정 약 8K
  - PE register: 192 × ~50 = 9.6K → 합성 시 일부 공유
  - Pipeline register: ~3K
  - Control: ~1K
````

---

## 14. 주요 설계 결정 요약

````
1. K_col 3-cycle time-multiplexing
   - 자원: 192 DSP (vs 576 fully unrolled)
   - Latency: 3× 증가하지만 throughput 동일 (pipeline)

2. COMPUTE_WRAP (row boundary 처리)
   - PE idle 시간 0
   - 약 4% 성능 향상 (69 cycle/image 절감)

3. PE 내부 weight register 3개
   - K_col 시간 다중화를 PE 내부 mux로 처리
   - col_sel과 sel을 분리해 WRAP 동작 가능

4. K_row × IC adder tree
   - 24:1 합산을 5 stage pipeline으로 분할
   - 200 MHz 가능

5. Inter-image pipelining
   - c1c2 BRAM ping-pong (Conv1과 Conv2가 다른 이미지 동시 처리)
   - peer counter 기반 handshake

6. Direct BMG IP 인스턴스 (cnn_accelerator.v에 직접)
   - Wrapper 없음, 분산 데이터플로우
   - 각 모듈이 자체 bank_sel과 카운터 관리
````