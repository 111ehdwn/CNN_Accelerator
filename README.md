# CNN Accelerator

> Arty A7-100T FPGA 보드 위에서 동작하는 MNIST CNN 추론 가속기.
> Conv1 → Conv2 → MaxPool → FC 파이프라인을 INT8 데이터패스로 구현하며,
> Conv2 레이어 병목을 Winograd Convolution 으로 가속하는 것이 최종 목표.

**수업**: 지능형시스템설계및응용
**팀원**: 김도현, 김동주, 신지민

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

## 2. 로드맵

프로젝트는 단계별 마일스톤으로 진행된다. 각 단계는 직전 단계의 hardware/software 인프라를 그대로 재사용하며 누적적으로 발전한다.

### Phase 0 — Sobel Baseline (완료)

`AS1_Sobel_Baseline/` 에 위치. 102×102 grayscale 이미지에 대한 3×3 Sobel edge detection IP. CNN 가속기를 위한 기본 인프라(Line buffer + 3×3 window register, AXI CSR 슬레이브, BRAM Port A/B 분리, PS-PL 데이터 전송 프로토콜) 를 검증하는 단계.

### Phase 1 — INT8 Direct CNN Accelerator (진행 중)

`RTL/` 에서 본격적으로 시작. 명세 그대로의 INT8 Direct Convolution 으로 전체 파이프라인 구현. 1만 장 처리 latency 의 기준선(baseline) 을 확보하는 단계.

- Output Stationary 데이터플로우 채택
- Conv2 기준 `oc_par × ic_par × K × K = 8 × 2 × 3 × 3 = 144 DSP` 사용
- 채널별 line buffer + window register 로 streaming 처리
- 사이클 단위 동작 분해는 `docs/imple_1.md` 참조

### Phase 2 — Winograd Conv2 가속 (예정)

Conv2 가 전체 latency 의 병목임을 확인했으므로, F(4,3) 또는 complex F(4,3) Winograd 변환으로 Conv2 의 multiply 수를 줄여 1만 장 처리 시간을 단축한다.

- 8×8 INT8 SIMD packing 알고리즘은 `docs/DSP48E1_signed8x8_SIMD_Packing.md` 에 정리
- 알고리즘 reference 구현은 `sim/3_complex_winograd_f(4,3).py`

### Phase 3 — 최적화

1만 장 batch 의 end-to-end 시간을 더 줄이기 위한 추가 pipelining, PS-PL 전송 오버랩, 메모리 access pattern 개선 등.

---

## 3. 시스템 아키텍처 (Block Design)

전체 시스템은 Vivado Block Design 상에서 다음과 같이 구성된다. Microblaze 가 PS 역할을 담당하며 AXI Interconnect 를 통해 BRAM Controller, CSR, 디버그용 Uartlite 와 연결되고, CNN 가속 본체는 `cnn_accel_top` 내부에 모두 들어간다.

```
Block Design (Vivado GUI)
├── Microblaze (D-cache enabled)
├── AXI Interconnect
├── Clocking Wizard
├── Processor System Reset
│   ├── ext_reset_in ← 외부 버튼 (BTN0)
│   ├── dcm_locked   ← Clocking Wizard.locked
│   └── peripheral_aresetn → 모든 AXI peripheral reset
│       ├── CSR_AXI.S_AXI_ARESETN
│       ├── BRAM Controller × 4의 reset
│       └── cnn_accel_top.reset (자체 reset port 만들어서)
├── AXI BRAM Controller × 4
│   ├── input_bram_ctrl
│   ├── conv1_w_ctrl
│   ├── conv2_w_ctrl
│   └── fc_w_ctrl
├── AXI Uartlite (debug)
└── Custom IP
    ├── csr_slave_axi_inner (수정 버전)
    └── cnn_accel_top
        ├── conv1_engine (Direct conv, DSP+LUT mult)
        │   ├── input_bram (BRAM × 2 bank)
        │   ├── conv1_w_bram
        │   └── pe_array
        ├── conv2_engine (Direct baseline, Winograd stretch)
        │   ├── conv2_w_bram
        │   ├── line_buffer × 8
        │   └── pe_array
        ├── maxpool_engine
        ├── fc_engine
        │   ├── fc_w_bram
        │   └── MAC tree (LUT mult)
        ├── argmax_unit → result (4-bit), img_done
        └── ping_pong_buffer instances
```

주요 설계 포인트:

- **AXI BRAM Controller × 4** — 입력 이미지와 세 종류의 weight (Conv1, Conv2, FC) 가 각각 독립된 BRAM 에 매핑되어 PS 가 병렬로 적재 가능
- **Reset 트리** — `Processor System Reset` 이 외부 버튼과 Clocking Wizard `locked` 를 받아 모든 AXI peripheral 및 가속기 IP 의 `peripheral_aresetn` 을 동기 release
- **`cnn_accel_top` 내부 dataflow** — Conv1 → Conv2 → MaxPool → FC → argmax 의 single-image inference 파이프라인. `ping_pong_buffer` 로 stage 간 producer/consumer 를 분리해 연속 1만 장 추론의 throughput 을 끌어올림
- **결과 출력** — `argmax_unit` 이 10-class logit 에서 4-bit class index 와 `img_done` 신호를 만들어 PS 로 보고

---

## 4. 폴더 구조 및 역할

```
CNN_Accelerator/
├── AS1_Sobel_Baseline/   # Phase 0: Sobel edge detector IP (인프라 검증용)
├── RTL/                  # Phase 1+: CNN 가속기 RTL (메인 산출물)
├── sim/                  # Python reference / 양자화 / Winograd 알고리즘 검증
├── data_int8/            # 학습 완료된 weight 와 reference input/output (.npy)
└── docs/                 # 설계 명세, 구현 계획, 알고리즘 문서, 협업 가이드
```

### `AS1_Sobel_Baseline/`

Phase 0 산출물. CNN 본 구현에 들어가기 전 PS-PL 인터페이스, AXI CSR, BRAM dual-port 사용법, line buffer 기반 stencil 연산을 검증한 첫 번째 IP.

- `sobel_ip.v` — 102×102 입력 → 100×100 Sobel 출력 (Output Stationary, 3×3 direct conv)
- `line_buffer.v` — 2 줄 circular line buffer (BRAM 추론)
- `axi_slave_csr_inner.v` — start/done 제어용 AXI-Lite slave CSR
- `top_memory_ctrlr.v` — BRAM1/BRAM2 Port A 와 sobel_ip 연결 top
- `testbench.v` — Vivado simulation testbench
- `main.c` — Vitis baremetal app (BRAM1 write → start → done poll → BRAM2 read & verify)

### `RTL/`

Phase 1 이후 모든 CNN 가속기 RTL 이 모이는 메인 디렉토리. 위 Block Design 에서 `cnn_accel_top` 및 그 하위 sub-engine 들이 여기에 위치한다.

- `cnn_accel_top.v` — Top IP. BRAM1 (input) / BRAM2 (output) 을 내장하고, PL-side 는 cnn_accelerator 와 연결, PS-side 는 외부 AXI BRAM Controller 와 연결
- `axi_csr_inner.v` — start / done 제어용 AXI-Lite CSR (Sobel 단계 CSR 의 진화 버전)

(이후 conv1_engine / conv2_engine / maxpool_engine / fc_engine / argmax_unit / ping_pong_buffer 등이 추가될 예정)

### `sim/`

하드웨어 구현에 앞서 알고리즘적으로 명세를 검증하는 Python 시뮬레이터.

- `reference_core.py` — 공통 유틸리티. `.npy` 로드, MNIST 라벨 로드, bit-exact 비교, `Conv2D_Spec` / `FC_Spec` 등 명세 saturation 규칙 (LSB-10bit shift + clip[-128,127]) 을 갖는 base 레이어 클래스 정의
- `0_reference.py` — 시나리오 #1: INT8 Direct 컨볼루션. 명세 그대로 구현하여 `data_int8/output.npy` 와 bit-exact 일치 검증
- `1_quantize.py` — Weight / Activation 추가 양자화 실험 (예: INT4)
- `3_complex_winograd_f(4,3).py` — Complex F(4,3) Winograd 변환 reference 구현
- `MNIST_example.png` — 시각 자료

### `data_int8/`

학습이 완료되어 양자화까지 끝난 INT8 파라미터 및 검증용 입출력.

- `input.npy` — 예제 입력 이미지
- `layer1_0_weight.npy` — Conv1 weight (8, 1, 3, 3)
- `layer2_0_weight.npy` — Conv2 weight (16, 8, 3, 3)
- `fc1_weight.npy` — FC weight (10, 2304)
- `output.npy` — reference 모델의 expected output (bit-exact 검증 목표)
- `mnist_cache/` — torchvision MNIST 캐시 (1만 장 평가에 사용)
- `params.zip` — 원본 파라미터 묶음

### `docs/`

설계·구현·협업 관련 모든 문서.

- `constraint.md` — 보드/자원 한도, 타겟 CNN, 명세 (변경 불가 사항), 결정 사항
- `imple_1.md` — Conv2 엔진의 사이클 단위 동작 분해, dataflow 결정, line buffer 구조 등 구현 상세
- `DSP48E1_signed8x8_SIMD_Packing.md` — DSP48E1 단일 multiplier 로 signed 8×8 두 개를 동시에 수행하는 SIMD packing 알고리즘 (Winograd 단계 핵심 기법)
- `cowork_guide.md` — Git / GitHub / VSCode / Python 환경 세팅부터 PR 까지의 협업 가이드
- `pdfs/` — 과제 안내문, 베이스라인 보고서, 구현 계획 PDF, Winograd 참고 자료

---

## 5. 개발 흐름

전형적인 작업 사이클은 다음과 같다.

1. **알고리즘 검증 (sim)** — Python 으로 명세 구현, `data_int8/output.npy` 와 bit-exact 일치 확인
2. **RTL 설계 (RTL)** — 동일 동작을 Verilog 로 옮기고, testbench 로 동일 입력에 대한 동일 출력 검증
3. **합성 & 보드 검증 (Vivado / Vitis)** — 위 Block Design 으로 bitstream 빌드 → Arty A7-100T 에 적재 → PS 측 baremetal app 으로 MNIST 1만 장 분류 수행
4. **측정 & 최적화** — 1만 장 처리 총 시간 측정 후 다음 마일스톤으로

협업 절차 (브랜치 전략, PR 흐름, 환경 세팅) 는 `docs/cowork_guide.md` 에 자세히 정리되어 있다.

---

## 6. 참고 문서 빠른 링크

- 설계 명세: [`docs/constraint.md`](docs/constraint.md)
- Conv2 사이클 분해: [`docs/imple_1.md`](docs/imple_1.md)
- DSP48E1 SIMD Packing: [`docs/DSP48E1_signed8x8_SIMD_Packing.md`](docs/DSP48E1_signed8x8_SIMD_Packing.md)
- 협업 가이드: [`docs/cowork_guide.md`](docs/cowork_guide.md)
