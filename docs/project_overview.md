# CNN Accelerator - 전체 아키텍처 Overview

**Target**: Arty A7-100T FPGA / MNIST 10,000장 / INT8 quantized **Goal**: Latency 최소화 (목표 ~96 ms)

---

## 1. 시스템 구조

```
┌─────────────────────────────────────────────────────────────┐
│                    Block Design (Vivado)                     │
│                                                               │
│  ┌──────────────┐                                            │
│  │  Microblaze  │  D-cache enabled, AXI4 Full Master         │
│  │  (PS, 100MHz)│                                            │
│  └──────┬───────┘                                            │
│         │                                                     │
│  ┌──────┴──────────────────────────────────────────────┐    │
│  │           AXI Interconnect (SmartConnect)            │    │
│  └──┬──────┬──────┬──────┬──────┬───────────────────────┘    │
│     │      │      │      │      │                            │
│  ┌──▼──┐┌──▼──┐┌──▼──┐┌──▼──┐┌──▼──────┐                    │
│  │BRAM ││BRAM ││BRAM ││BRAM ││ CSR     │                    │
│  │Ctrl ││Ctrl ││Ctrl ││Ctrl ││ Slave   │                    │
│  │Input││Conv1││Conv2││ FC  ││ (Lite)  │                    │
│  │     ││  W  ││  W  ││  W  ││         │                    │
│  └──┬──┘└──┬──┘└──┬──┘└──┬──┘└────┬────┘                    │
│     │      │      │      │        │                          │
│  ┌──▼──────▼──────▼──────▼────────▼──────────────────────┐  │
│  │              cnn_accel_top.v (PL, 180MHz)              │  │
│  │                                                          │  │
│  │  [Conv1] → [C1C2] → [Conv2] → [C2P] → [Pool]            │  │
│  │              ⇅              ⇅                            │  │
│  │   (ping-pong buffers between each stage)                 │  │
│  │              ⇅              ⇅                            │  │
│  │   [Pool] → [PFC] → [FC] → [Argmax] → result              │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘

* 클럭: PS 100 MHz / PL 180 MHz (TBD, post-synthesis 확인)
* External reset: BTN via Processor System Reset
```

---

## 2. CNN Network

```
Input (1, 28, 28) int8
   ↓ Conv2d (8, 1, 3, 3), no pad, stride 1
(8, 26, 26) → [>>10, saturate ±127, ReLU]
   ↓ Conv2d (16, 8, 3, 3), no pad, stride 1
(16, 24, 24) → [>>10, saturate ±127, ReLU]
   ↓ MaxPool 2×2 stride 2
(16, 12, 12)
   ↓ Flatten (W, H, C order) → 2304
   ↓ FC (2304 → 10)
(10,) logits → [>>10, saturate ±127, ReLU]
   ↓ Argmax
result (0~9)
```

**MAC 분포**:

- Conv1: 48,672 (6.6%)
- Conv2: 663,552 (90.2%) ← bottleneck
- FC: 23,040 (3.1%)

---

## 3. DSP 분배 (총 218/240)

|Layer|DSP|구조|Cycle/img|
|---|---|---|---|
|Conv1|18|K=9 unroll × OC_pair=2 × SIMD=2|1,568|
|Conv2|192|K_row=3 × IC=8 × OC_pair=8 × SIMD=2|1,728|
|FC|8|Input=4 × OC_pair=1 × SIMD=2|1,440|

**Conv2가 throughput bottleneck**. 1,728 cycle/image @ 180 MHz ≈ 9.6 μs.

---

## 4. Dataflow 패러다임

**Weight Stationary + Output Stationary, Activation Flowing**

- **Weight**: PE-local register (적재 후 inference 동안 고정)
- **Psum**: 16 OC × 24-bit accumulator (3-cycle K_col 누적)
- **Activation**: BRAM stream → line buffer → window → PE

각 PE 내 weight 1번 적재, 활성화는 매 cycle 흐름.

---

## 5. SIMD Packing (DSP48E1)

단일 DSP의 25×18 multiplier로 **2개 INT8 곱셈 동시 수행**:

```
Aport = W1 × 2^17 + W0    (25-bit)
Bport = X                   (18-bit)
P     = Aport × Bport       (43-bit)

→ P0 = W0 × X = sint17(P mod 2^17)
→ P1 = W1 × X = sint16(⌊P/2^17⌋) + carry - 256X·ovf
```

**핵심 차별점**: DSP48E1 (Artix-7)에서 -128 포함 모든 INT8 케이스 손상 없이 처리. 기존 연구 대비 우위 (Xilinx WP486은 DSP48E2 전용, Vestias FPL'17은 -128 손상).

---

## 6. Memory Architecture

### Ping-pong 구조 (intra-image pipelining)

|Buffer|크기|BRAM|신호|
|---|---|---|---|
|Input BRAM (PS↔Conv1)|2 KB × 2 bank|1|conv1_input_read_done|
|C1C2 (Conv1↔Conv2)|5.3 KB × 2|~5|c1_write_done, c2_read_done|
|C2Pool (Conv2↔Pool)|9.2 KB × 2|~9|c2_write_done, pool_read_done|
|PoolFC (Pool↔FC)|2.3 KB × 2|~3|pool_write_done, fc_read_done|

### Weight BRAM (각각 별도 AXI BRAM Controller)

|BRAM|크기|용도|
|---|---|---|
|Conv1 weight|72 B|적재 후 PE register stationary|
|Conv2 weight|1.2 KB|적재 후 192 PE register stationary|
|FC weight|23 KB|Streaming (BRAM 8개 분산 병렬 read)|

---

## 7. Layer-local Handshake

각 stage 간 **양방향 notification** (중앙 controller 없음):

```
Producer → Consumer: write_done (1-cycle pulse)
Consumer → Producer: read_done  (1-cycle pulse)

각자 internal bank_sel FF로 toggle 관리
```

→ **분산 제어 데이터플로우** (각 PE engine이 자체 FSM 보유)

---

## 8. PS-PL Interface

### CSR Memory Map (AXI4-Lite)

|Addr|Reg|설명|
|---|---|---|
|0x00|CTRL|bit 0: start (pulse), bit 1: enable|
|0x04|STATUS|bit 0: done, [4:1]: result, [18:5]: img_cnt, bit 19: conv1_read_done|
|0x08|TIMER_LO|cycle counter [31:0]|
|0x0C|TIMER_HI|cycle counter [47:32]|

### PS 흐름 (main.c)

```c
// Init: weight transfer (1회)
memcpy(CONV1_W_BASE, conv1_weight, 72);
memcpy(CONV2_W_BASE, conv2_weight, 1152);
memcpy(FC_W_BASE, fc_weight, 23040);

*CTRL = TIMER_START_BIT;  // timer 시작

// Inference loop (10,000 image)
for (i = 0; i < 10000; i++) {
    // 다음 이미지 preload (반대 bank)
    uint32_t offset = (i & 1) ? 0x400 : 0x000;
    memcpy(IMEM_BASE + offset, images[i], 784);
    Xil_DCacheFlushRange(IMEM_BASE + offset, 784);
    
    *CTRL = START_BIT;       // start
    while (!(*STATUS & DONE)); // wait img_done
    result[i] = (*STATUS >> 1) & 0xF;
}

// 종료: timer 읽기
uint64_t cycles = *TIMER_HI;
cycles = (cycles << 32) | *TIMER_LO;
```

---

## 9. 성능 예측

| 구분                    | 값                    |
| --------------------- | -------------------- |
| Per-image latency     | 1,728 cycle ≈ 9.6 μs |
| 10,000 image total    | ~96 ms               |
| Peak throughput       | 138 GOPS             |
| Effective utilization | 95.5%                |
| DSP util              | 218/240 (91%)        |
| BRAM util             | ~30/135 (22%)        |

---

## 10. 모듈 계층 구조 및 작업 범위

```
[ ● 직접 작성 ]  [ ◆ 재사용 ]  [ ▣ IP / 자동생성 ]

Block Design (Vivado GUI 작업)
│
├─ ▣ Microblaze MCS
├─ ▣ AXI SmartConnect
├─ ▣ Clocking Wizard
├─ ▣ Processor System Reset
├─ ▣ AXI Uartlite (debug)
│
├─ ▣ AXI BRAM Controller × 4
│   ├─ input_bram_ctrl
│   ├─ conv1_w_ctrl
│   ├─ conv2_w_ctrl
│   └─ fc_w_ctrl
│
├─ ▣ Block Memory Generator × 4
│   ├─ input_bram      (32-bit PortA / 8-bit PortB, asymmetric)
│   ├─ conv1_w_bram    (32-bit dual port)
│   ├─ conv2_w_bram    (32-bit dual port)
│   └─ fc_w_bram       (32-bit dual port × 8 분산)
│
├─ ◆ csr_slave_axi_inner.v  (기존 코드 + img_cnt/timer/done 추가)
│
└─ ● cnn_accel_top.v
    │
    ├─ ● conv1_engine.v
    │   ├─ ◆ line_buffer.v               (Sobel 재사용, IC=1이라 1개)
    │   ├─ ● window_register.v
    │   ├─ ● pe_array_conv1.v            (18 DSP = K=9 × OC_pair=2)
    │   │   └─ ● pe_cell.v               (SIMD packing, 핵심 알고리즘)
    │   ├─ ● weight_loader.v
    │   ├─ ● activation_broadcast.v       (X fanout to 18 PE)
    │   ├─ ● truncate_relu.v             (>>10 + saturate ±127 + ReLU)
    │   └─ ● conv1_fsm.v
    │
    ├─ ● ping_pong_buffer.v (C1C2)
    │
    ├─ ● conv2_engine.v
    │   ├─ ● conv2_ic_unit.v × 8         (IC별 독립 처리 unit)
    │   │   ├─ ◆ line_buffer.v           (Sobel 재사용)
    │   │   ├─ ● window_register.v
    │   │   └─ ● pe_subarray.v           (24 DSP = 3 K_row × 8 OC_pair)
    │   │       └─ ◆ pe_cell.v × 24      (SIMD ×2 = 48 OC ops/cycle)
    │   ├─ ● weight_loader.v             (BRAM → 192 PE shift chain)
    │   ├─ ● activation_broadcast.v       (X fanout to PE array)
    │   ├─ ● cross_ic_accumulator.v      (8 IC × 16 OC × 24-bit adder tree)
    │   ├─ ● k_col_accumulator.v         (3-cycle K_col 누적)
    │   ├─ ◆ truncate_relu.v
    │   └─ ● conv2_fsm.v
    │
    ├─ ◆ ping_pong_buffer.v (C2Pool)
    │
    ├─ ● maxpool_engine.v
    │   ├─ ● max_compare_tree.v
    │   └─ ● maxpool_fsm.v
    │
    ├─ ◆ ping_pong_buffer.v (PoolFC)
    │
    ├─ ● fc_engine.v
    │   ├─ ● pe_array_fc.v               (8 DSP = Input=4 × OC_pair=1)
    │   │   └─ ◆ pe_cell.v
    │   ├─ ● weight_streamer.v           (8 BRAM 병렬 read, no register)
    │   ├─ ● activation_broadcast.v
    │   ├─ ● accumulator.v               (10 OC × 24-bit, 2304-cycle 누적)
    │   ├─ ◆ truncate_relu.v
    │   └─ ● fc_fsm.v
    │
    └─ ● argmax_unit.v
        └─ ● compare_tree.v
```

### 검증 / 인프라

```
◆ PyTorch golden model                           (완료)
● gen_test_data.py        (hex 파일 생성)
● gen_weight_headers.py   (.h 파일 생성)
● quantize_utils.py       (HW 비트-정확 모사)

Testbench (각 모듈당 1개)
├─ ● pe_cell_tb.v         (2^24 exhaustive)
├─ ● conv1_engine_tb.v
├─ ● conv2_engine_tb.v
├─ ● maxpool_tb.v
├─ ● fc_engine_tb.v
├─ ● argmax_tb.v
├─ ● ping_pong_tb.v
└─ ● cnn_top_tb.v         (전체 통합)
```

### Vitis 측 (PS 코드)

```
● main.c
  ├─ Weight transfer (memcpy 3회)
  ├─ Inference loop (10,000 image, ping-pong preload)
  ├─ Result 비교 (expected_results.h)
  └─ Latency 측정 (TIMER reg 읽기)

▣ Xilinx BSP (자동)
▣ AXI BRAM Controller driver (자동)
```

---

## 11. 역할 분배

| 담당자     | 작업                                                              |
| ------- | --------------------------------------------------------------- |
| **김도현** | PE, conv2_engine.v, header file, hex file, CSR_AXI              |
| **김동주** | PE, conv1_engine.v                                              |
| **신지민** | ping_pong_buffer.v, maxpool_engine.v, fc_engine.v, armax_unit.v |
| **공통**  | Block Design, cnn_accel_top.v                                   |

---

## 12. 검증 전략

```
PyTorch model (golden)
    ↓
gen_test_data.py
    ↓
┌────────────────────┬─────────────────────┐
│   hex files        │   C header files    │
│   (testbench용)    │   (Vitis용)         │
│                    │                     │
│ • conv1_input.hex  │ • mnist_images.h    │
│ • conv1_expected.hex│ • conv1_weight.h   │
│ • conv2_expected.hex│ • conv2_weight.h   │
│ • pool_expected.hex │ • fc_weight.h      │
│ • fc_expected.hex   │ • expected_results.h│
└────────────────────┴─────────────────────┘
    ↓                        ↓
Verilog testbench       Vitis main.c
(unit test per module)  (board 검증)
```

**Bit-exact 검증**: 모든 layer 출력이 PyTorch golden과 INT8 단위로 정확히 일치해야 함.

---