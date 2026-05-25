# Convolution Layer 2 Design Document

**모듈**: `conv2_engine.v`
**버전**: v2.0

---

## 1. 개요

### 1.1 Layer 명세

````
Input:    (8, 26, 26) signed INT8  (Conv1 출력)
Weight:   (16, 8, 3, 3) signed INT8, pre-packed [-127, 127]
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
BRAM:   Conv2 weight 1개 (32-bit × 576) + Input/Output ping-pong (외부)
````

---

## 2. 모듈 계층

### 2.1 conv2_engine.v 내부 구조

````
conv2_engine.v
├── conv2_fsm.v             (control plane FSM)
├── weight_loader_conv2.v   (시스템 시작 시 1번만 동작)
├── conv2_weight_bram (BMG IP, 32-bit × 576)
├── line_buffer × 16        (IC 8개 × 2 stage)
├── window_register × 8     (IC별)
├── pe_array (192 PE)
├── krow_ic_adder_tree × 16 (5-stage pipeline)
├── kcol_accumulator × 16
└── truncate_relu (#N=16)
````

### 2.2 외부 인터페이스 (cnn_accelerator와)

````
// System control
clk, rst, start

// Internal weight BMG (Port A, PS write via AXI BRAM Ctrl)
c2w_ena, c2w_addra, c2w_dina

// c1c2 buffer (Port B, read)
c1c2_re, c1c2_addr (with input_bank_sel), c1c2_dout

// c2pool buffer (Port A, write)
c2pool_we, c2pool_addr (with output_bank_sel), c2pool_din

// Handshake
prior_wdone (from Conv1), rdone (to Conv1)
succ_rdone (from Maxpool), wdone (to Maxpool)
````

---

## 3. PE Array 구조

### 3.1 DSP 분배 (192 PE)

````
PE 배열 차원: K_row × IC × OC_pair = 3 × 8 × 8 = 192 PE
각 PE: SIMD packing으로 2개 OC 동시 처리

한 cycle 동시 연산:
  3 K_row × 8 IC × 8 OC_pair × 2 SIMD = 384 multiplications

K_col은 3-cycle time-multiplexing (PE 내부 weight register 3개)
````

### 3.2 PE 인스턴스

````
pe_cell #(N_WEIGHTS = 3)
  - Weight register: 3개 (K_col 0, 1, 2 각각의 25-bit packed Aport)
  - sel: K_col weight selector (0, 1, 2)
  - mul0, mul1: 17-bit signed output (OC k, OC k+8)

→ 192 PE × 3 weight register = 576 weight register slots
````

### 3.3 OC Pairing (SIMD packing)

````
oc_pair i의 packing:
  W0 = W[i,   ic, kh, kw]   ← OC i (0~7)
  W1 = W[i+8, ic, kh, kw]   ← OC i+8 (8~15)
  Aport = W1 * 2^17 + W0    ← signed integer
  pattern = Aport & 0x1FFFFFF (25-bit two's complement)
  packed_32 = pattern (upper 7 bits naturally 0)

PE 출력:
  mul0 = W0 * X (OC k)
  mul1 = W1 * X (OC k+8)
````

---

## 4. Window Register 및 Line Buffer (IC별 8 instance)

### 4.1 구조

IC 8개 독립 처리:

````
Per IC:
  line_buffer × 2 (DEPTH=25)
    lb1: 1 row 지연
    lb2: 2 row 지연
  window_register: 3×3 sliding window
  
Total IC=8: 16 line_buffer + 8 window_register
````

### 4.2 데이터 흐름

````
BRAM (c1c2 ping-pong, 8 IC × 8-bit) → 8개 stream
  Per IC stream → lb1 (1 row 지연)
                → lb2 (2 row 지연)
                → 3 row 동시 보유

Window register:
  row 0 (오래된): lb2 출력
  row 1 (중간):  lb1 출력
  row 2 (최신):  BRAM 직접 출력
  
col positions: col_pos_0, col_pos_1, col_pos_2
  col_pos_2 ← new data (lb/direct)
  col_pos_1 ← prev col_pos_2
  col_pos_0 ← prev col_pos_1
  prev col_pos_0 → discard
````

---

## 5. K_col Time-Multiplexing 설계

### 5.1 핵심 아이디어

````
한 output pixel 계산 = 3×3 = 9 multiplications/IC × 8 IC = 72 multiplications

전체 unroll 시 192 DSP × 3 K_col = 576 DSP 필요 (자원 초과)
K_col time-mux: 192 DSP × 3 cycle = 1 output pixel
````

### 5.2 매 cycle 동작

````
한 cycle:
  PE 입력: window의 한 col_position (col_sel로 선택)
  PE weight: K_col index (sel로 선택, 0/1/2)
  
3 cycle 동안 같은 output pixel 누적:
  Cycle A: col_sel=0, sel=0 → contribution K_col=0
  Cycle B: col_sel=1, sel=1 → contribution K_col=1
  Cycle C: col_sel=2, sel=2 → contribution K_col=2

col_sel과 sel은 일반적으로 동일 (steady state)
COMPUTE_WRAP에서는 col_sel 고정, sel만 변화
````

---

## 6. FSM 설계

### 6.1 상태 정의 (7개)

````
IDLE             : 시스템 reset 후 PS의 start 신호 대기
LOAD_WEIGHTS     : weight loader 동작 중 (576 cycle, 시스템 시작 시 1번만)
DONE             : image 처리 끝, 다음 image 대기
PIPELINE_FILL    : line_buffer + window 초기 fill (55 cycle)
COMPUTE_HOLD     : compute, window 정지 (2 cycle, kcol 0/1)
COMPUTE_ADVANCE  : compute, window 1 col 진행 (1 cycle, kcol 2)
COMPUTE_WRAP     : compute, row 변경 처리 (3 cycle, kcol 0/1/2)
````

### 6.2 상태 전이 다이어그램

````
[Reset]
   ↓
IDLE                              (start 대기)
   ↓ start
LOAD_WEIGHTS                      (576 cycle, 1번만)
   ↓ loader_done
DONE  ←─────────────────────┐    (image 끝, 다음 image 대기)
   ↓ ready_to_compute       │
PIPELINE_FILL                │   (55 cycle)
   ↓ fill 끝                 │
COMPUTE_HOLD  ←───┐  ←───────┤
   ↓ 2 cycle      │          │
COMPUTE_ADVANCE  ─┤          │
   ↓ row_boundary │          │
COMPUTE_WRAP ─────┘          │
                             │
   (COMPUTE_ADVANCE: last_input_read 시 DONE)
````

### 6.3 상태별 control signal 패턴

````
                  sel       col_sel    shift_en  pe_en
IDLE              0         0          0         0
LOAD_WEIGHTS      0         0          0         0
DONE              0         0          0         0
PIPELINE_FILL     0         0          1         0
COMPUTE_HOLD      0/1       0/1        0         1
COMPUTE_ADVANCE   2         2          1         1
COMPUTE_WRAP      0/1/2     0          1         1
````

### 6.4 상태 전이 조건 상세

````
IDLE → LOAD_WEIGHTS:    start (PS로부터 1-cycle pulse)
LOAD_WEIGHTS → DONE:    loader_done (weight_loader 완료)
DONE → PIPELINE_FILL:   ready_to_compute (data_ready && output_avail)

PIPELINE_FILL → COMPUTE_HOLD: fill_cnt == 54

COMPUTE_HOLD → COMPUTE_ADVANCE: kcol_phase == 1

COMPUTE_ADVANCE:
  → DONE:           last_input_read (read_row=25 && read_col=25)
  → COMPUTE_WRAP:   row_boundary (read_col=25, read_row != 25)
  → COMPUTE_HOLD:   그 외 (정상 진행)

COMPUTE_WRAP → COMPUTE_HOLD: wrap_cnt == 2
````

---

## 7. COMPUTE_WRAP 상세 (Row Boundary 처리)

### 7.1 핵심 통찰

````
일반적 row boundary 처리: PE idle 3 cycle (read만 진행)
본 설계: row 마지막 output의 9 곱셈을 3 cycle에 걸쳐 진행
        → PE idle 시간 0
        → 약 70 cycle/image 절감 (row boundary 23회 × 3 cycle)
````

### 7.2 동작 메커니즘

Conv1 output row의 마지막 output pixel을 (r, 23)이라 할 때:

````
COMPUTE_ADVANCE의 마지막 read = (r+2, 25)
이후 COMPUTE_WRAP 진입

진입 시 window 상태:
  col_pos_0:  (r,   23), (r+1, 23), (r+2, 23)
  col_pos_1:  (r,   24), (r+1, 24), (r+2, 24)
  col_pos_2:  (r,   25), (r+1, 25), (r+2, 25)

이 window로 output (r, 23) 계산 가능
````

### 7.3 COMPUTE_WRAP 3 cycle 상세

````
Cycle 0 (wrap_cnt=0):
  PE input: col_sel=0 → window의 col_pos_0
            = (r, 23), (r+1, 23), (r+2, 23)
  PE weight: sel=0 → w_regs[0] (f0, f3, f6)
  곱셈: f0×(r,23), f3×(r+1,23), f6×(r+2,23)
        → output (r, 23) K_col=0 contribution
  Cycle 끝: shift_en=1, read (r+3, 0)
  
Cycle 1 (wrap_cnt=1, shift 후 window):
  col_pos_0: (r,   24), (r+1, 24), (r+2, 24)
  col_pos_1: (r,   25), (r+1, 25), (r+2, 25)
  col_pos_2: (r+1, 0),  (r+2, 0),  (r+3, 0)   ← 새 row 들어옴
  
  PE input: col_sel=0 → col_pos_0
            = (r, 24), (r+1, 24), (r+2, 24)
  PE weight: sel=1 → w_regs[1] (f1, f4, f7)
  곱셈: f1×(r,24), f4×(r+1,24), f7×(r+2,24)
        → output (r, 23) K_col=1 contribution
  Cycle 끝: shift_en=1, read (r+3, 1)

Cycle 2 (wrap_cnt=2, shift 후 window):
  col_pos_0: (r,   25), (r+1, 25), (r+2, 25)
  col_pos_1: (r+1, 0),  (r+2, 0),  (r+3, 0)
  col_pos_2: (r+1, 1),  (r+2, 1),  (r+3, 1)
  
  PE input: col_sel=0 → col_pos_0
            = (r, 25), (r+1, 25), (r+2, 25)
  PE weight: sel=2 → w_regs[2] (f2, f5, f8)
  곱셈: f2×(r,25), f5×(r+1,25), f8×(r+2,25)
        → output (r, 23) K_col=2 contribution
  Cycle 끝: shift_en=1, read (r+3, 2)

→ output (r, 23) 9 multiplications 완료 (K_col 0,1,2 누적)
````

### 7.4 COMPUTE_WRAP 후 상태

````
WRAP 끝난 후 window:
  col_pos_0: (r+1, 0), (r+2, 0), (r+3, 0)
  col_pos_1: (r+1, 1), (r+2, 1), (r+3, 1)
  col_pos_2: (r+1, 2), (r+2, 2), (r+3, 2)

→ 정확히 output (r+1, 0)의 valid window
→ COMPUTE_HOLD 진입하여 output (r+1, 0) K_col=0 시작
````

### 7.5 COMPUTE_HOLD/ADVANCE vs COMPUTE_WRAP 차이

````
                col_sel 변화    sel 변화      window 변화
COMPUTE_HOLD     0 → 1          0 → 1         정지
COMPUTE_ADVANCE  2              2             1 col shift + 새 read
COMPUTE_WRAP     0 (고정)       0 → 1 → 2     1 col shift × 3 + 새 read × 3

WRAP은 col_sel을 0에 고정시키고 sel만 변화시켜
이전 row의 마지막 output의 K_col 0/1/2를 진행
````

---

## 8. Handshake 프로토콜 (양방향)

### 8.1 차이 카운터 (signed 3-bit)

FSM 내부 두 카운터:

````
prior_diff = (Conv2 rdone count) - (Conv1 wdone count)
           = Conv2가 Conv1보다 얼마나 앞서있나
           = 보통 음수 (-2 ~ 0): Conv1이 앞서감 (ping-pong 2 bank max)
           
           data_ready = (prior_diff < 0)
                      = Conv1이 만들었지만 Conv2가 아직 처리 안 한 image 있음

after_diff = (Conv2 wdone count) - (Maxpool rdone count)
           = Conv2가 Maxpool보다 얼마나 앞서있나
           = 보통 양수 (0 ~ +2): Conv2가 앞서감
           
           output_avail = (after_diff < 2)
                        = Conv2 출력 bank에 여유 있음 (max 2 bank dirty 안 됨)

ready_to_compute = data_ready && output_avail
````

### 8.2 신호 명명

````
자기 출력 (datapath에서 생성, registered):
  rdone:    Conv2가 input bank 1개 다 read 끝 → Conv1로
  wdone:    Conv2가 output bank 1개 다 write 끝 → Maxpool로

외부 입력:
  prior_wdone: Conv1으로부터 (input data 준비됨)
  succ_rdone:  Maxpool으로부터 (output bank 비워짐)
````

### 8.3 카운터 update 규칙

````
prior_diff:
  rdone        → prior_diff + 1
  prior_wdone  → prior_diff - 1
  동시 발생    → 변화 없음 (cancel out)

after_diff:
  wdone        → after_diff + 1
  succ_rdone   → after_diff - 1
  동시 발생    → 변화 없음
````

### 8.4 부트스트래핑

````
Reset 시:
  prior_diff = 0, after_diff = 0
  data_ready = (0 < 0) = false
  output_avail = (0 < 2) = true
  ready_to_compute = false
  → DONE 머무름 (PS의 start 후 LOAD_WEIGHTS → DONE)

Conv1 첫 image 완료:
  prior_wdone pulse → prior_diff: 0 → -1
  data_ready = true
  output_avail = true
  ready_to_compute = true
  → PIPELINE_FILL 진입

→ 자연 부트스트래핑, 속도 가정 무관
````

### 8.5 Bank Select (1-bit toggle FF)

차이 카운터와 별도:

````
input_bank_sel:  rdone에 toggle (다음 read할 c1c2 bank)
output_bank_sel: wdone에 toggle (다음 write할 c2pool bank)

reset 시 0, image 1개 처리 후 1, 다음 1개 처리 후 0, ...
````

### 8.6 책임 분리

````
[conv2_fsm.v - control plane]
  - prior_diff, after_diff 카운터 관리
  - input_bank_sel, output_bank_sel toggle
  - 상태 전이 결정 (ready_to_compute 평가)

[conv2_engine.v - datapath]
  - rdone pulse 생성: 마지막 BRAM read 시점 (read_row=25, col=25, shift_en=1)
  - wdone pulse 생성: 마지막 c2pool BRAM write 시점 (output_pixel_cnt=575)
  - 신호는 1-stage register 후 FSM과 외부 동시 전달
````

---

## 9. Weight Loading

### 9.1 Loading 정책

````
시스템 시작 시 1번만 (LOAD_WEIGHTS 상태, 576 cycle)
이후 모든 image 처리 동안 weight stationary
overhead: ~3 μs (전체 99 ms 처리 시간의 0.003%)
````

### 9.2 Weight BMG IP 명세

````
Width: 32-bit (AXI 32-bit과 정렬)
  bit [24:0]: 25-bit packed Aport pattern
  bit [31:25]: unused (zero padding)
Depth: 576 (8 oc_pair × 8 IC × 3 KH × 3 KW)
Memory Type: SDP (Simple Dual Port)
Port A: PS write (via AXI BRAM Ctrl)
Port B: Conv2 weight_loader read
Primitive Output Register: Enable (Port B)
Common Clock: Yes
````

### 9.3 Pre-pack 매핑 (Python)

````python
# Loop order (outer to inner): oc_pair → ic → kh → kw
# addr = ((oc_pair * 8 + ic) * 3 + kh) * 3 + kw

for oc_pair in range(8):
    for ic in range(8):
        for kh in range(3):
            for kw in range(3):
                w0 = W[oc_pair,   ic, kh, kw]   # OC 0~7
                w1 = W[oc_pair+8, ic, kh, kw]   # OC 8~15
                aport = (w1 * (1 << 17)) + w0
                packed = aport & 0x01FFFFFF
````

### 9.4 weight_loader_conv2.v 동작

````
시스템 시작 시:
  loader_start pulse 받음 (FSM에서)
  
Cycle 0~575:
  BMG addr 0 → 575 순차 read
  매 cycle 1 weight 추출 (BMG dout)
  → (kh, ic, oc_pair, kw) 디코딩
  → PE에 broadcast (pe_id, slot_id, packed_a, load_en)

BMG read latency (2 cycle) 흡수:
  PE 제어 신호 (pe_id, slot_id, load_en)를 2 cycle 지연 register
  
완료 시:
  loader_done pulse 출력 (FSM 받아 DONE 진입)
````

---

## 10. PE 출력 → Buffer write 데이터 경로

### 10.1 PE Array 출력

````
192 PE × {mul0, mul1} = 384 outputs (17-bit signed each)
차원: K_row(3) × IC(8) × OC_pair(8) × SIMD(2)
````

### 10.2 K_row × IC adder tree (Tree Pipeline)

````
같은 (OC_pair, SIMD) 조합 16개의 24:1 합산:
  입력: 24개 17-bit (K_row 3 × IC 8)
  출력: 22-bit signed

Tree 구조 (5 stage pipeline):
  Stage 1: 12 adders (24 → 12), 18-bit
  Stage 2: 6 adders (12 → 6), 19-bit
  Stage 3: 3 adders (6 → 3), 20-bit
  Stage 4: 2 adders (3 → 2), 21-bit
  Stage 5: 1 adder (2 → 1), 22-bit

Timing: 200 MHz 가능 (5 ns budget 내)
Throughput: 1 result/cycle

16개 (OC_pair × SIMD) 병렬 instance:
  자원: ~9K LUT (전체 14%)
  Latency: 5 cycle
````

### 10.3 K_col Accumulator

````
3 cycle 동안 K_col 0, 1, 2 결과 누적:
  
Cycle 0 (sel=0): accumulator = krow_ic_sum_kcol0  (22→24 sign-ext)
Cycle 1 (sel=1): accumulator += krow_ic_sum_kcol1
Cycle 2 (sel=2): accumulator += krow_ic_sum_kcol2 → final, valid

비트 폭: 22 + log2(3) = 24-bit signed
인스턴스: 16 (각 OC_pair × SIMD)
````

### 10.4 Truncate + ReLU

````
truncate_relu #(.N(16))
  입력: 24-bit sum × 16 (packed)
  처리: >>>10 → saturate [-128, 127] → ReLU
  출력: 8-bit signed × 16 (packed)
  
en: kcol_sum_valid (3 cycle에 1번)
````

### 10.5 Output Buffer Write (c2pool)

````
16 OC × 8-bit = 128-bit per output pixel
3 cycle에 1 pixel write

c2pool BRAM 명세:
  Width: 128 (Port A/B)
  Depth: 1152 (576 × 2 bank)
  Address: 11-bit, {bank_sel, row[4:0], col[4:0]}
  Byte Write Enable: Disable
  Memory Type: SDP
  Primitive Output Register: Enable (Port B)
````

---

## 11. Cycle 분석

### 11.1 전체 latency

````
PIPELINE_FILL: 55 cycle
Compute phase:
  Output 576 pixel × 3 cycle = 1,728 cycle
  Row boundary는 COMPUTE_WRAP으로 흡수, 추가 stall 없음

Total: ~55 + 1,728 = ~1,783 cycle/image

Pipeline depth (PE → buffer write):
  PE: 4 cycle
  K_row × IC adder tree: 5 cycle
  K_col accumulator: 1 cycle
  Truncate_relu: 1 cycle
  Buffer write: 1 cycle
  Total: ~12 cycle (한 image당 한 번만, 무시 가능)

이론 throughput: 1,783 cycle/image @ 180MHz = 9.9 μs/image
10,000 images: ~99 ms (compute only)
````

### 11.2 비교 - row boundary 처리 방식

````
방식 A (단순 stall): row boundary에서 PE idle 3 cycle
  Total: 55 + 1,728 + 23 × 3 = 1,852 cycle

방식 B (COMPUTE_WRAP, 본 설계): row boundary에서도 compute 진행
  Total: 55 + 1,728 = 1,783 cycle

차이: 69 cycle/image (~4% 성능 향상)
````

---

## 12. 인터페이스 명세

### 12.1 conv2_fsm.v 포트

````verilog
module conv2_fsm (
    input  wire        clk,
    input  wire        rst,

    // System control
    input  wire        start,             // PS로부터 (csr 통해)

    // Internal weight loader
    output reg         loader_start,
    input  wire        loader_done,

    // Input side handshake (Conv1)
    input  wire        prior_wdone,       // 외부
    input  wire        rdone,             // 내부 (datapath에서)
    output reg         input_bank_sel,

    // Output side handshake (Maxpool)
    input  wire        succ_rdone,        // 외부
    input  wire        wdone,             // 내부 (datapath에서)
    output reg         output_bank_sel,

    // Datapath control
    output reg  [1:0]  sel,
    output reg  [1:0]  col_sel,
    output reg         shift_en,
    output reg         pe_en,

    // BRAM coords (datapath 공유)
    output reg  [4:0]  read_row,
    output reg  [4:0]  read_col
);
````

### 12.2 conv2_engine.v 포트 (외부)

````verilog
module conv2_engine (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,

    // Conv2 weight BMG (Port A, from PS)
    input  wire         c2w_ena,
    input  wire [9:0]   c2w_addra,
    input  wire [31:0]  c2w_dina,

    // c1c2 buffer (Port B read)
    output wire         c1c2_re,
    output wire [10:0]  c1c2_addr,
    input  wire [63:0]  c1c2_dout,

    // c2pool buffer (Port A write)
    output wire         c2pool_we,
    output wire [10:0]  c2pool_addr,
    output wire [127:0] c2pool_din,

    // Handshake
    input  wire         prior_wdone,
    output wire         rdone,
    input  wire         succ_rdone,
    output wire         wdone
);
````

---

## 13. 검증 전략

### 13.1 단계별 검증

````
Stage 1: PE cell exhaustive test (2^24 패턴, 별도 testbench)
Stage 2: K_row × IC adder tree (random input, golden 비교)
Stage 3: K_col accumulator (3 cycle 패턴)
Stage 4: Truncate_relu (경계값 + random)
Stage 5: weight_loader (BMG read, broadcast 정확성)
Stage 6: FSM (각 state 전이 + handshake counter)
Stage 7: Conv2 engine 통합 (1 image bit-exact)
Stage 8: Cycle count 측정 (~1,783 cycle)
````

### 13.2 검증 데이터

````
PyTorch golden model:
  Input: (8, 26, 26) INT8 (Conv1 출력 시뮬레이션)
  Weight: (16, 8, 3, 3) INT8 [-127, 127]
  Pre-packed: 576 × 32-bit (conv2_simd_pack.py)
  Expected output: (16, 24, 24) INT8

Exhaustive verification (SIMD packing):
  254 × 254 × 256 = 16,646,144 케이스 ✓ 통과 완료
````

---

## 14. 자원 정리

````
DSP:    192 (전체 240의 80%)
BRAM:   1 (Conv2 weight, RAMB18) + 외부 c1c2/c2pool
LUT:    추정 약 15K
  - PE array control: ~3K
  - K_row × IC adder tree: ~9K (5 stage × 16 instances)
  - K_col accumulator: ~500
  - Truncate_relu: ~200
  - FSM, weight_loader, mux: ~2K
FF:     추정 약 8K
````

---

## 15. 주요 설계 결정 요약

````
1. K_col 3-cycle time-multiplexing
   - 자원: 192 DSP (vs 576 fully unrolled)
   - PE 내부 weight register 3개로 multiplex

2. COMPUTE_WRAP (row boundary 처리)
   - PE idle 시간 0
   - 약 4% 성능 향상 (69 cycle/image 절감)
   - col_sel 고정 + sel 변화로 이전 row 마지막 output 완성

3. K_row × IC adder tree (5 stage pipeline)
   - 24:1 합산을 5 stage로 분할
   - 200 MHz 가능

4. Inter-image pipelining (ping-pong buffer)
   - Conv1과 Conv2가 다른 image 동시 처리
   - 차이 카운터 기반 handshake (signed 3-bit)
   - 속도 가정 무관 (양쪽 어느 쪽이든 빠르거나 느림 가능)

5. Counter-based handshake
   - prior_diff, after_diff (signed 3-bit per side)
   - rdone/wdone은 datapath에서 생성, FSM이 받아 카운터 update
   - bank_sel은 별도 1-bit toggle FF

6. Direct BMG IP instantiation (cnn_accelerator.v 단일 모듈)
   - Wrapper 없음, 분산 데이터플로우
   - Inter-layer buffer는 cnn_accelerator level
   - Intra-layer weight BMG는 각 engine 내부

7. Weight loading once at system start
   - LOAD_WEIGHTS 상태 (576 cycle, 1번만)
   - Weight stationary 동안 모든 image 처리

8. Pre-packed SIMD weight (Python)
   - (oc, oc+8) pair로 25-bit Aport packing
   - 32-bit aligned for AXI BRAM Ctrl
   - Exhaustive verification 통과 (16M cases)

9. FSM control plane only
   - rdone/wdone은 datapath에서 생성
   - FSM은 상태 전이 + 카운터 관리만
````

---

## 16. 부록 - 명명 컨벤션

### 16.1 신호 명명

````
prior_*    : upstream layer (Conv1)으로부터 / 으로
succ_*     : downstream layer (Maxpool)으로부터 / 으로
*_done     : 1-cycle pulse, image 1개 단위 완료 알림
*_bank_sel : 1-bit, ping-pong bank index (0 또는 1)
````

### 16.2 카운터 명명

````
prior_diff: 자기 처리 - prior 처리 (signed 3-bit)
after_diff: 자기 처리 - succ 처리 (signed 3-bit)
````

### 16.3 좌표 명명

````
read_row, read_col   : c1c2 BRAM read 좌표 (0~25)
kcol_phase           : K_col 시간 다중화 phase (0, 1, 2)
wrap_cnt             : COMPUTE_WRAP 내부 cycle (0, 1, 2)
fill_cnt             : PIPELINE_FILL 카운터 (0~54)
````