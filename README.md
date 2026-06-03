# CNN Accelerator

> Arty A7-100T FPGA 보드 위에서 동작하는 MNIST CNN 추론 가속기.
> Conv1 → Conv2 → MaxPool → FC 파이프라인을 INT8 데이터패스로 구현하며,
> 1만 장 end-to-end latency 를 최소화하는 것이 목표.

**수업**: 지능형시스템설계및응용

**팀원**: 김도현, 김동주, 신지민

### 진행 현황 요약 (MNIST 1만 장 분류 latency)

| 단계 | 핵심 최적화 | 1만 장 Latency | 비고 |
|------|-------------|----------------|------|
| Baseline | INT8 Direct Conv 전체 파이프라인 | **1079 ms** | 완료 |
| Inter-image Pipelining | 이미지 간 추론 파이프라이닝 (stage 간 ping-pong BRAM) | **586 ms** | 완료 (≈1.84× ↑) |
| AXI Burst + DMA | PS→PL 전송 병목 제거 | **187 ms** | 완료 (≈5.77× ↑) |
| Overclock | 300 MHz 오버클럭 | 진행 중 | 동작 주파수 상향 |
| Complex Winograd | F(4×4, 3×3) | 예정 | 보드 최고 성능 목표 |

---

## 1. 프로젝트 목표

본 프로젝트는 **MNIST 손글씨 분류 CNN** 을 FPGA 상에서 가속하는 IP 를 설계하는 것을 목적으로 한다.
PS (Processing System) 은 데이터 전송과 start/done 제어만 담당하며, 모든 추론 연산은 PL (Programmable Logic) 의 가속기 IP 내부에서 수행된다.

### 타겟 네트워크

```
Input (1, 28, 28) INT8
  ↓ Conv1 (8, 1, 3, 3), stride 1, no pad
Feature Map1 (8, 26, 26)
  ↓ ReLU
  ↓ Conv2 (16, 8, 3, 3), stride 1, no pad
Feature Map2 (16, 24, 24)
  ↓ ReLU
  ↓ MaxPool 2×2
Feature Map3 (16, 12, 12)
  ↓ Flatten (W, H, C order) → 2304
  ↓ FC (2304, 10)
Output Logit (10) → argmax
```

### 설계 제약

- **보드**: Arty A7-100T (Xilinx XC7A100T)
- **자원 한도**: DSP48E1 240 개, BRAM 135 (4.6 Mb), LUT 63K, FF 126K
- **데이터 타입**: Weight / Activation 모두 signed INT8
- **양자화 규칙**: 누적 후 LSB 10 bit 산술 우측 시프트 → ±127 saturation → INT8 출력

### 평가 지표 (우선순위 순)

1. **End-to-end Latency (최우선)** — **MNIST 1만 장 이미지 분류에 걸리는 총 시간**. 이 값을 최소화하는 것이 본 프로젝트의 1순위 목표
2. **Throughput** — 연속 inference 파이프라이닝 효율

> 단일 이미지 latency 뿐 아니라 PS-PL 데이터 전송, BRAM 입출력, 1만 장 batch 전체에 걸친 누적 시간을 모두 고려한 end-to-end 시간이 평가 기준이다.

---

## 2. 로드맵 & 성능 마일스톤

프로젝트는 단계별 마일스톤으로 진행되며, 각 단계는 직전 단계의 hardware/software 인프라를 그대로 재사용하면서 누적적으로 발전한다. 모든 성능 수치는 **MNIST 1만 장 분류 end-to-end latency** 기준이다.

### Phase 0 — Sobel Baseline (완료)

`archive/AS1_Sobel_Baseline/` 에 위치. 102×102 grayscale 이미지에 대한 3×3 Sobel edge detection IP. CNN 가속기를 위한 기본 인프라(Line buffer + 3×3 window register, AXI CSR 슬레이브, BRAM Port A/B 분리, PS-PL 데이터 전송 프로토콜) 를 검증하는 단계.

### Phase 1 — INT8 Direct CNN Baseline (완료 — 1079 ms)

명세 그대로의 INT8 Direct Convolution 으로 Conv1 → Conv2 → MaxPool → FC → argmax 전체 파이프라인을 구현하고, 1만 장 처리 latency 의 기준선(baseline) 을 확보했다.

- Output Stationary + Weight Stationary 데이터플로우 채택
- Conv1 기준 `oc_par × ic_par × KH × KW = 2 × 2 × 3 × 3 = 18 DSP` 사용
- Conv2 기준 `oc_par × ic_par × KH = 8 × 16 × 3 = 192 DSP` 사용
- 채널별 line buffer + window register 로 streaming 처리
- **결과: 1만 장 1079 ms**

### Phase 2 — Inter-image Pipelining (완료 — 586 ms)

단일 이미지 내부 stage 파이프라이닝을 넘어, 한 이미지의 연산이 끝나기 전에 다음 이미지를 적재·처리하도록 이미지 간(inter-image) 파이프라이닝을 적용했다. stage 사이의 **2-bank ping-pong BRAM** (`bram_input` / `bram_c1_to_c2` / `bram_c2_to_pool` / `bram_pool_to_fc`) 으로 producer/consumer 를 분리해 가속기가 쉬는 구간을 줄였다.

- **결과: 1079 ms → 586 ms (약 1.84× 향상)**

### Phase 3 — AXI Burst + DMA (완료 — 187 ms)

Phase 2 이후 프로파일링 결과 **PS→PL 데이터 전송이 새로운 병목**임을 확인했다. 기존의 word 단위 CSR/BRAM 전송을 **AXI burst + DMA** 로 교체하고, `input_consumed` backpressure 로 PS write 와 PL 연산을 오버랩하여 전송 병목을 제거했다.

- **결과: 586 ms → 187 ms (baseline 대비 약 5.77× 향상)**

### Phase 4 — Overclock (진행 중)

동작 주파수를 끌어올려 처리량을 직접적으로 높이는 단계.

- **300 MHz 오버클럭** 적용 및 측정 — 타이밍 클로저가 허용하는 한도까지 동작 주파수 상향
- BRAM read latency 를 `L=1 → L=2` 로 키우고 conv1_fsm / maxpool_fsm 의 phase 를 재배치해 300 MHz 타이밍을 맞춤 (소스 내 `★ 300MHz` 주석 참고)

### Phase 5 — Complex Winograd (예정)

Conv 연산량 자체를 줄여 보드 상 최고 성능을 노리는 단계. Phase 4 의 오버클럭과 결합한다.

- **Complex Winograd F(4×4, 3×3)** — Conv 의 multiply 수를 줄여 연산 throughput 향상. DSP48E1 단일 multiplier 로 signed 8×8 둘을 동시에 수행하는 SIMD packing 과 결합
  - SIMD packing 알고리즘: `docs/DSP48E1_signed8x8_SIMD_Packing.md`
  - 알고리즘 reference 구현: `scripts/golden_sim/1_complex_winograd_f(4,3).py`
- 오버클럭과 Winograd 를 결합해 주어진 보드에서 최고 성능을 목표로 한다.

---

## 3. 시스템 아키텍처 (Block Design)

전체 시스템은 Vivado Block Design 상에서 구성된다. MicroBlaze 가 PS 역할을 담당하며, DDR3(MIG) 와 UART 위에서 도는 baremetal app 이 AXI Interconnect 를 통해 CSR 과 5 개의 BRAM Controller 에 접근한다. CNN 가속 본체는 `cnn_accelerator` IP 내부에 모두 들어간다. 단계별 빌드·검증 절차는 `docs/block_design_manual.md` 에 정리되어 있다.

```
Block Design (Vivado GUI)
├── MicroBlaze (D-cache enabled) + Local Memory
├── DDR3 SDRAM (MIG)  ← baremetal app / 이미지 스트림
├── AXI Uartlite (debug / 결과 출력)
├── Clocking Wizard (100 MHz 시스템, 200 MHz MIG ref, 300 MHz stretch)
├── Processor System Reset
│   ├── ext_reset_in ← 외부 버튼
│   ├── dcm_locked   ← Clocking Wizard.locked
│   └── peripheral_aresetn → 모든 AXI peripheral / cnn_accelerator.resetn
├── AXI BRAM Controller × 5  (PS-facing)
│   ├── bram_input   (PS write → conv1)
│   ├── bram_output  (fc 결과 → PS read, 32b burst)
│   ├── conv1_weight_bram
│   ├── conv2_weight_bram
│   └── fc_weight_bram
└── Custom IP
    ├── csr_axi  (start / img_ready / enable / done CSR)
    └── cnn_accelerator
        ├── conv1_engine  (Direct conv, DSP+LUT mult)
        │   └── pe_array  ※ core (line_buffer, window_register, pe_cell, truncate_relu)
        ├── conv2_engine  (Direct baseline, Winograd stretch)
        │   └── pe_array  ※ core 공용 (line_buffer × 8 포함)
        ├── maxpool_engine
        ├── fc_engine
        │   └── fc_argmax → class index (4-bit), img_done
        └── stage 간 ping-pong BRAM
            bram_input → bram_c1_to_c2 → bram_c2_to_pool → bram_pool_to_fc → bram_output
```

주요 설계 포인트:

- **PS-facing BRAM Controller × 5** — 입력 이미지(`bram_input`), 출력 결과(`bram_output`), 그리고 세 종류 weight (Conv1/Conv2/FC) 가 각각 독립된 BRAM 에 매핑되어 PS 가 burst 로 적재/회수
- **Stage 간 ping-pong BRAM** — `bram_c1_to_c2` / `bram_c2_to_pool` / `bram_pool_to_fc` 는 PL 내부 전용. 2-bank ping-pong 으로 producer/consumer 를 분리해 inter-image 파이프라이닝을 구현
- **Reset 트리** — `Processor System Reset` 이 외부 버튼과 Clocking Wizard `locked` 를 받아 모든 AXI peripheral 및 `cnn_accelerator.resetn` 을 동기 release
- **`cnn_accelerator` 내부 dataflow** — `start` 로 weight 1 회 적재 후, `img_ready` 펄스마다 이미지를 흘려보내 Conv1 → Conv2 → MaxPool → FC → argmax 를 수행. `input_consumed` backpressure 로 PS write 와 오버랩
- **`core` 모듈 공용화** — `line_buffer`, `window_register`, `pe_cell`, `truncate_relu` 는 `RTL/core/` 에 분리하여 conv1_engine / conv2_engine 이 동일 PE 빌딩 블록을 인스턴스화. parameter 로 channel / output width 만 조정
- **결과 출력** — `fc_engine` 내부 `fc_argmax` 가 10-class logit 에서 4-bit class index 를 만들고, `img_done` 마다 `bram_output` 에 누적해 PS 가 회수

---

## 4. 폴더 구조 및 역할

```
CNN_Accelerator/
├── RTL/                  # CNN 가속기 RTL (메인 산출물)
│   ├── cnn_accelerator.v # Top IP (Conv1→Conv2→MaxPool→FC→argmax + stage BRAM)
│   ├── control_status_register/  # AXI-Lite CSR (csr_axi)
│   ├── core/             # Conv1/Conv2 공용 PE 빌딩 블록
│   ├── conv1/            # Conv1 engine
│   ├── conv2/            # Conv2 engine (+ 설계/타이밍 노트)
│   ├── maxpool/          # MaxPool engine
│   └── fc/               # FC + argmax
├── TB/                   # Verilog testbench
│   ├── models/           # 시뮬레이션 모델 (dsp48e1_model.v, bmg_sim_models.v)
│   ├── single_img/       # 단일 이미지 엔진별 testbench
│   └── multi_img/        # 다중 이미지 (system / inter-image) testbench
├── vitis/                # PS-side baremetal app (MicroBlaze)
│   ├── main.c            # 이미지 적재 → start/done → 결과 회수 & latency 측정
│   ├── test_images.h     # 테스트 이미지 데이터
│   └── uart_test.c       # UART 디버그
├── scripts/              # Python reference / weight·hex 변환 스크립트
│   ├── golden_sim/       # 명세 검증 reference (bit-exact 비교, Winograd 알고리즘)
│   ├── weights/          # weight SIMD packing (.h / .hex 생성)
│   ├── single_img/       # 단일 이미지 layer hex 생성
│   └── multi_img/        # 다중 이미지 batch hex 생성
├── data/                 # weight·reference 입출력 및 스크립트 산출물
│   ├── _base_npy/        # .npy 원본 (input, weight, expected output, params.zip)
│   ├── weights_simd/     # scripts/weights 산출물 (SIMD-packed .h/.hex)
│   ├── single_img/       # 단일 이미지 layer hex (testbench 입력)
│   └── multi_img/        # 다중 이미지 batch hex (testbench 입력)
├── docs/                 # 설계 명세, 알고리즘·타이밍 문서, IP 스펙, 협업 가이드
│   ├── ip_spec/          # Vivado BRAM/IP 설정 스크린샷 + 메모
│   └── pdfs/             # 구현 계획 등 참고 PDF
└── archive/              # Phase 0 산출물 보관 (AS1_Sobel_Baseline)
```

### `RTL/`

모든 CNN 가속기 RTL 이 모이는 메인 디렉토리. Block Design 의 `cnn_accelerator` 및 그 하위 sub-engine 들이 여기에 위치한다.

- `cnn_accelerator.v` — Top IP. stage 간 ping-pong BRAM 을 내장하고 conv1/conv2/maxpool/fc 엔진을 wiring. `start` / `img_ready` / `input_consumed` / `img_done` 으로 PS 와 핸드셰이크
- `control_status_register/` — start/done 제어용 AXI-Lite CSR (`csr_axi.v`, `csr_axi_slave_lite_v1_0_csr.v`, `axi_inner_ref.v`)
- `core/` — Conv1/Conv2 공용 PE 빌딩 블록
  - `line_buffer.v`, `window_register.v` — streaming stencil 처리용 라인/윈도우 버퍼
  - `pe_cell.v` — INT8 MAC 단위 PE (parameter 화)
  - `truncate_relu.v` — LSB-10bit shift + saturation + ReLU (parameter 화)
- `conv1/` — Conv1 engine (`conv1_engine.v`, `conv1_fsm.v`, `conv1_adder_tree.v`, `conv1_weight_loader.v`, `conv1_design.md`)
- `conv2/` — Conv2 engine (`conv2_engine.v`, `conv2_fsm.v`, `kcol_accumulator.v`, `krow_ic_adder_tree.v`, `weight_loader.v`)
  - 설계/타이밍 노트: `conv2_design.md`, `conv2_timing.md`, `conv2_adder_drain_bug_fix.md`
- `maxpool/` — MaxPool engine (`maxpool_engine.v`, `maxpool_fsm.v`, `max_compare_tree.v`)
- `fc/` — FC + argmax (`fc_engine.v`, `fc_fsm.v`, `fc_pe_array.v`, `fc_adder_tree.v`, `fc_accumulator.v`, `fc_argmax.v`)

### `TB/`

엔진별 Verilog testbench. `data/` 의 hex 파일을 입력으로 읽어 RTL 출력을 reference 와 비교한다.

- `models/` — 시뮬레이션 모델 (`dsp48e1_model.v`, `bmg_sim_models.v` — Block Memory Generator 모델)
- `single_img/` — 단일 이미지 검증 (`tb_conv1_engine.v`, `tb_conv2_engine.v`, `tb_conv1_conv2.v`, `tb_maxpool_engine.v`, `tb_fc_engine.v`)
- `multi_img/` — 다중 이미지(inter-image 파이프라인) 및 system 레벨 검증
  - `tb_cnn_accelerator_multi.v`, `tb_system_axi_multi.v`, `tb_conv1_conv2_maxpool_fc_multi.v`, `tb_conv1_conv2_maxpool_multi.v`, `tb_conv1_conv2_multi.v`, `tb_conv2_engine_multi.v`, `tb_maxpool_engine_multi.v`

### `vitis/`

MicroBlaze 에서 도는 PS-side baremetal app. 이미지/weight 를 BRAM 에 적재하고 `start`/`img_ready` 를 찔러 가속기를 구동, `img_done`/결과 BRAM 을 회수하며 1만 장 latency 를 측정한다.

- `main.c` — 메인 추론 루프 + latency 측정
- `test_images.h` — 테스트 이미지 데이터
- `uart_test.c` — UART 디버그 유틸리티

### `scripts/`

하드웨어 구현에 앞서 알고리즘적으로 명세를 검증하고, 검증된 데이터를 RTL/SW 가 먹을 수 있는 형식으로 변환하는 Python 스크립트 모음.

- `golden_sim/` — 명세 검증 reference
  - `reference_core.py` — 공통 유틸리티. `.npy` 로드, MNIST 라벨 로드, bit-exact 비교, `Conv2D_Spec` / `FC_Spec` 등 명세 saturation 규칙 (LSB-10bit shift + clip[-128,127]) 을 갖는 base 레이어 클래스 정의
  - `0_reference.py` — INT8 Direct 컨볼루션 reference. 명세 그대로 구현하여 `data/_base_npy/output.npy` 와 bit-exact 일치 검증
  - `1_complex_winograd_f(4,3).py` — Complex F(4,3) Winograd 변환 reference 구현
- `weights/` — weight 를 SIMD-packed `.h` / `.hex` 로 변환 (`weight_simd_pack.py`, 산출물: `data/weights_simd/`)
- `single_img/` — 단일 이미지 layer-by-layer hex 생성 (`gen_single_img_hex.py`, 산출물: `data/single_img/`)
- `multi_img/` — 다중 이미지 batch hex 생성 (`gen_multi_img_hex.py`, 산출물: `data/multi_img/`)

### `data/`

학습이 완료되어 양자화까지 끝난 INT8 파라미터 및 검증용 입출력. `scripts/` 산출물의 저장소 역할도 겸한다.

- `_base_npy/` — 원본 `.npy` 파라미터 및 reference 입출력
  - `input.npy` — 예제 입력 이미지
  - `layer1_0_weight.npy` — Conv1 weight (8, 1, 3, 3)
  - `layer2_0_weight.npy` — Conv2 weight (16, 8, 3, 3)
  - `fc1_weight.npy` — FC weight (10, 2304)
  - `output.npy` — reference 모델의 expected output (bit-exact 검증 목표)
  - `params.zip` — 원본 파라미터 묶음
- `weights_simd/` — `scripts/weights` 산출물. Vitis 펌웨어용 `.h` 와 BRAM init 용 `.hex` (conv1 / conv2 / fc)
- `single_img/` — 단일 이미지 layer 입출력 hex (`conv1_input`, `conv1_output_c1c2`, `conv2_output_c2pool`, `maxpool_output`, `fc_output`)
- `multi_img/` — 다중 이미지 batch hex (`all_input`, `all_c1c2`, `all_c2pool`, `all_maxpool`, `all_fc_logit`, `all_fc_output`)

### `docs/`

설계·구현·협업 관련 모든 문서.

- `project_overview.md` — 보드/자원 한도, 타겟 CNN, 결정 사항, 업무 분담 결정 내역
- `block_design_manual.md` — Vivado Block Design 단계별 빌드·검증 매뉴얼 (DDR/UART/MicroBlaze/CSR/BRAM)
- `DSP48E1_signed8x8_SIMD_Packing.md` — DSP48E1 단일 multiplier 로 signed 8×8 두 개를 동시에 수행하는 SIMD packing 알고리즘 (Winograd 단계 핵심 기법)
- `conv1_timing.md`, `conv1_timing_table.md` — Conv1 사이클 타이밍 분석
- `axi_lite_write_hang_fix.md`, `handshake_counter_nba_race.md` — 디버깅 노트
- `cowork_guide.md` — Git / GitHub / VSCode / Python 환경 세팅부터 PR 까지의 협업 가이드
- `ip_spec/` — Vivado BRAM/IP 설정 스크린샷과 메모 (`block_memory_generator.md`, `output_result_bram.md`, 각 BRAM 포트별 설정 캡처)
- `pdfs/` — 구현 계획 등 참고 PDF

### `archive/`

Phase 0 산출물 보관소. `AS1_Sobel_Baseline/` 에 CNN 본 구현 전 PS-PL 인터페이스·AXI CSR·BRAM dual-port·line buffer stencil 연산을 검증한 첫 IP (`sobel_ip.v`, `line_buffer.v`, `axi_slave_csr_inner.v`, `top_memory_ctrlr.v`, `testbench.v`, `main.c`) 가 들어 있다.

---

## 5. 개발 흐름

전형적인 작업 사이클은 다음과 같다.

1. **알고리즘 검증 (scripts/golden_sim)** — Python 으로 명세 구현, `data/_base_npy/output.npy` 와 bit-exact 일치 확인
2. **RTL 설계 (RTL)** — 동일 동작을 Verilog 로 옮기고, `TB/` testbench 로 동일 입력에 대한 동일 출력 검증
3. **합성 & 보드 검증 (Vivado / Vitis)** — `docs/block_design_manual.md` 의 단계별 절차로 bitstream 빌드 → Arty A7-100T 에 적재 → `vitis/main.c` baremetal app 으로 MNIST 1만 장 분류 수행
4. **측정 & 최적화** — 1만 장 처리 총 시간 측정 후 다음 마일스톤으로

협업 절차 (브랜치 전략, PR 흐름, 환경 세팅) 는 `docs/cowork_guide.md` 에 자세히 정리되어 있다.

---

## 6. 참고 문서 빠른 링크

- 프로젝트 명세 및 계획: [`docs/project_overview.md`](docs/project_overview.md)
- Block Design 매뉴얼: [`docs/block_design_manual.md`](docs/block_design_manual.md)
- DSP48E1 SIMD Packing: [`docs/DSP48E1_signed8x8_SIMD_Packing.md`](docs/DSP48E1_signed8x8_SIMD_Packing.md)
- 협업 가이드: [`docs/cowork_guide.md`](docs/cowork_guide.md)
