# CNN Accelerator — 팀 협업 / Convention 가이드

> 본 문서는 **팀원이 일관된 convention 으로 작업할 수 있도록** 정리한 reference manual 입니다.
> Onboarding 보다는 "내가 작업할 layer 의 hex 포맷이 정확히 뭐였지?" 같은 **빠른 참조**를 목적으로 합니다.
>
> 대상: 김도현 (Conv2), 김동주 (Maxpool), 신지민 (Conv1).
> 관련 상위 문서: `docs/project_overview.md` (시스템 구조), `docs/DSP48E1_signed8x8_SIMD_Packing.md` (SIMD 수식 derivation).

---

## 목차

1. [프로젝트 디렉토리 구조](#1-프로젝트-디렉토리-구조)
2. [Hex 파일 포맷 (가장 중요)](#2-hex-파일-포맷-가장-중요)
3. [Weight packing 포맷](#3-weight-packing-포맷)
4. [Script 사용법 (시나리오별)](#4-script-사용법-시나리오별)
5. [RTL 모듈 책임 분담](#5-rtl-모듈-책임-분담)
6. [Testbench 사용법](#6-testbench-사용법)
7. [Pitfall / 주의사항](#7-pitfall--주의사항)
8. [최근 fix 이력](#8-최근-fix-이력)
9. [부록: Git 협업 흐름](#9-부록-git-협업-흐름)

---

## 1. 프로젝트 디렉토리 구조

```
CNN_Accelerator/
├── data/                       ← 모든 .npy / .hex 데이터 (gitignore 대상 아님, 작아서 commit OK)
│   ├── _base_npy/              ← 원본 .npy (변경 금지, 모든 hex 의 source)
│   │   ├── input.npy           (10000, 1, 28, 28)  int8   ← MNIST 10,000 image
│   │   ├── layer1_0_weight.npy (8, 1, 3, 3)        int8   ← Conv1 weight
│   │   ├── layer2_0_weight.npy (16, 8, 3, 3)       int8   ← Conv2 weight
│   │   ├── fc1_weight.npy      (10, 2304)          int8   ← FC weight
│   │   └── output.npy          (10000, 10)         int8   ← Python reference output
│   │
│   ├── weights_simd/           ← SIMD packed weight (testbench 가 $readmemh 로 직접 load)
│   │   ├── conv1_weights_simd.{hex,h}    ← Conv1
│   │   ├── conv2_weights_simd.{hex,h}    ← Conv2
│   │   └── fc_weights_simd.{hex,h}       ← FC
│   │
│   ├── single_img/             ← image 0 (또는 IDX 지정) 의 layer 별 hex
│   │   ├── conv1_input.hex             (Conv1 입력)
│   │   ├── conv1_output_c1c2.hex       (Conv1 출력 = Conv2 입력)
│   │   ├── conv2_output_c2pool.hex     (Conv2 출력 = Maxpool 입력)
│   │   ├── maxpool_output.hex          (Maxpool 출력 = FC 입력)
│   │   └── fc_output.hex               (FC 출력 = 최종 10-class)
│   │
│   └── multi_img/              ← 100 image stress test 용 (img000_*.hex .. img099_*.hex)
│       ├── img000_c1c2.hex     ~ img099_c1c2.hex     (per image, 1024 × 64-bit)
│       ├── img000_c2pool.hex   ~ img099_c2pool.hex   (per image, 576  × 128-bit)
│       ├── all_c1c2.hex        (concatenated 100 × 1024  = 102,400 lines)
│       └── all_c2pool.hex      (concatenated 100 × 576   =  57,600 lines)
│
├── scripts/                    ← Python data 생성 / golden simulation
│   ├── weights/                ← weight packing (drink-and-forget, weight 바뀌면 재실행)
│   │   ├── conv1_simd_pack.py
│   │   └── conv2_simd_pack.py
│   ├── single_img/             ← per-image layer hex (각 RTL 모듈 검증용)
│   │   ├── per_image_layer_hex.py      (Conv1 input, c1c2, c2pool)
│   │   ├── maxpool_out.py              (Maxpool 출력)
│   │   └── fc_out.py                   (FC 출력 + predicted class)
│   ├── multi_img/              ← 100 image 배치 생성
│   │   └── gen_multi_img_hex.py
│   └── golden_sim/             ← Python reference (Conv 알고리즘 검증)
│       ├── 0_reference.py
│       └── reference_core.py
│
├── RTL/
│   ├── conv1/                  ← 신지민 — conv1_engine_2.v (top), _2 suffix 주의
│   ├── conv2/                  ← 김도현 — conv2_engine.v (top)
│   ├── maxpool/                ← 김동주 — maxpool_engine.v (top)
│   ├── fc/                     ← FC layer (담당 TBD)
│   ├── ping_pong_buffer/       ← (legacy / 설계 문서 보관용, 실제 코드 없음)
│   ├── rtl_pingpong/           ← 실제 ping-pong buffer 구현
│   │   └── c2pool_pingpong_buffer.v
│   ├── cnn_accelerator.v       ← top integration (현재 skeleton 만 존재)
│   └── axi_csr_inner.v         ← AXI CSR slave
│
├── TB/
│   ├── single_img/             ← per-engine 단위 검증
│   │   ├── tb_conv1_engine.v
│   │   ├── tb_conv2_engine.v
│   │   └── tb_maxpool_engine.v
│   └── multi_img/              ← 100 image stress
│       └── tb_conv2_engine_multi.v
│
├── docs/                       ← 본 가이드 위치
│   ├── cowork_guide.md         ← 이 파일
│   ├── project_overview.md
│   └── DSP48E1_signed8x8_SIMD_Packing.md
│
└── archive/                    ← 과거 버전 보관 (참고만, 사용 X)
```

> 모든 script 는 **자기 디렉토리에서 실행**한다고 가정 (상대경로 `../../data/...`). cwd 가 다르면 path resolve 실패.

---

## 2. Hex 파일 포맷 (가장 중요)

각 layer 의 BRAM 포맷을 정확히 맞춰야 testbench 가 `$readmemh` 한 줄로 init 가능. **단 한 byte 라도 어긋나면 simulation 결과가 망가집니다.**

### 2.1 한눈에 보기

| 파일 | 라인 수 | bit/line | hex chars/line | addressing | packing |
|---|---|---|---|---|---|
| `conv1_input.hex`         |  784 |   8 |  2 | compact `h*28 + w`                    | raw 1 byte/pixel |
| `conv1_output_c1c2.hex`   | 1024 |  64 | 16 | **padded** `h*32 + w` (h,w ∈ [0,25]) | 8 IC × 8b, IC 0 = LSB |
| `conv2_output_c2pool.hex` |  576 | 128 | 32 | compact `h*24 + w` (write_addr 순)   | 16 OC × 8b, OC 0 = LSB |
| `maxpool_output.hex`      | 2304 |   8 |  2 | flatten `(c, h, w)` C-order           | raw 1 byte/pixel |
| `fc_output.hex`           |   10 |   8 |  2 | 10 class score                        | raw 1 byte/class |

→ 생성 script: `scripts/single_img/per_image_layer_hex.py` (1, 2, 3 번), `maxpool_out.py` (4 번), `fc_out.py` (5 번).

### 2.2 `conv1_input.hex` — Conv1 입력

- **사용처**: `conv1_engine.in_bram_addr[9:0]` / `in_bram_dout[7:0]` (1 채널 MNIST raw)
- **shape**: (1, 28, 28) int8 → 784 lines
- **address**: `addr = h*28 + w` (compact, no padding)
- **포맷**: 1 byte / line, `%02X` (예: `7F`, `00`)

### 2.3 `conv1_output_c1c2.hex` — Conv1 출력 = Conv2 입력 (c1c2 buffer)

- **사용처**: `conv2_engine.c1c2_addr[10:0]` / `c1c2_dout[63:0]`
- **address layout**: `{bank_sel, row[4:0], col[4:0]}` = `bank * 1024 + h*32 + w`
- **valid range**: `h ∈ [0, 25]`, `w ∈ [0, 25]` (Conv1 output 26×26)
- **padding**: `h ∈ [26, 31]` 또는 `w ∈ [26, 31]` → `0000000000000000` (8 byte zero)
- **packing**: 8 IC × 8b
  ```
  word[63:0] = {IC7, IC6, IC5, IC4, IC3, IC2, IC1, IC0}   (IC 0 = LSB, bits[7:0])
  ```
- 1 bank = 1 image = 1024 entry. BMG depth 2048 = 2 bank × 1024 (ping-pong).
- **single_img TB 도 multi_img TB 도 같은 hex 파일을 그대로 사용 가능** (padded format 통일).

### 2.4 `conv2_output_c2pool.hex` — Conv2 출력 (c2pool buffer)

- **사용처**: `conv2_engine.c2pool_addr[10:0]` / `c2pool_din[127:0]`
- **address layout**: `{bank_sel, write_addr[9:0]}` = `bank * 1024 + (h*24 + w)`
- **address 는 compact** (no padding), `write_addr = 0..575` sequential
- **packing**: 16 OC × 8b
  ```
  word[127:0] = {OC15, OC14, ..., OC1, OC0}   (OC 0 = LSB, bits[7:0])
  ```
- 1 bank = 576 entry 사용 (BMG depth 2048 = 2 bank × 1024 중 0..575, 1024..1599).

### 2.5 `maxpool_output.hex` — Maxpool 출력 = FC 입력

- shape (16, 12, 12) int8 → **2304 entries**, C-order flatten (`np.tobytes()`)
- 1 byte / line.
- (현재 RTL/fc/maxpool_output.hex 가 별도로 존재 — 같은 source 인지 확인 필요.)

### 2.6 `fc_output.hex` — 최종 출력

- 10 class score (int8, post-saturation), `argmax` = predicted class.
- 1 byte / line.

→ 관련 파일:
- 생성: `scripts/single_img/per_image_layer_hex.py`, `scripts/multi_img/gen_multi_img_hex.py`
- 사용: `TB/single_img/tb_conv2_engine.v` (line 26-28), `TB/multi_img/tb_conv2_engine_multi.v` (line 25-27)

---

## 3. Weight packing 포맷

모든 conv weight 는 **DSP48E1 SIMD packing** (1 곱셈으로 2 OC 동시 계산) 을 사용합니다. 수식 derivation 은 `docs/DSP48E1_signed8x8_SIMD_Packing.md` 참조.

**공통 packing 식** (Conv1, Conv2 동일):
```
packed_25bit = W1 * 2^17 + W0          (W0, W1 ∈ [-127, 127], 25-bit 2's complement)
BRAM word    = zero_extend(packed_25bit, 32)   (상위 7 bit = 0)
```

> ⚠️ **W0, W1 = -128 동시 사용 금지** (carry 보정이 깨짐). `conv*_simd_pack.py` 가 `ovf_count` 로 검증.

### 3.1 Conv1 weight (`conv1_weights_simd.hex`)

- **shape**: 36 lines × 32-bit
- **구조**: 18 PE = 2 group (g1, g2) × 9 PE, 각 PE 가 DEPTH=2 weight register (round 1/2)
  - 1 group 9 PE = 3 KH × 3 KW, PE idx `i → (kh, kw) = (i/3, i%3)`
  - 1 PE = 2 OC SIMD pack (W0, W1)

| addr   | group | sel (round) | OC pairing (W0, W1) |
|:------:|:-----:|:-----------:|:--------------------|
|  0.. 8 | g1    | 0           | (oc0, oc1)          |
|  9..17 | g2    | 0           | (oc2, oc3)          |
| 18..26 | g1    | 1           | (oc4, oc5)          |
| 27..35 | g2    | 1           | (oc6, oc7)          |

공식: `oc_w0 = sel*4 + (group-1)*2`, `oc_w1 = oc_w0 + 1`.

→ 관련 파일: `scripts/weights/conv1_simd_pack.py`, `RTL/conv1/conv1_weight_loader.v`, `RTL/conv1/conv1_design.md`

### 3.2 Conv2 weight (`conv2_weights_simd.hex`)

- **shape**: 576 lines × 32-bit (8 pair × 8 IC × 3 KH × 3 KW)
- **OC pairing**: `W0 = W[k, ic, kh, kw]`, `W1 = W[k+8, ic, kh, kw]`, `k = 0..7`
- **iteration order**: `(pair, ic, kh, kw)` outer-to-inner (즉, 연속된 9 entry = 한 (pair, ic) 의 3×3 kernel)
- **addr**: `pair*72 + ic*9 + kh*3 + kw` (= 0..575)

→ 관련 파일: `scripts/weights/conv2_simd_pack.py`, `RTL/conv2/weight_loader.v`, `RTL/conv2/conv2_design.md`

### 3.3 Verification

두 packing script 모두 **exhaustive verify** 포함 (`254 × 254 × 256 ≈ 16.5 M case`). 실행 시 자동으로 통과 확인.

---

## 4. Script 사용법 (시나리오별)

> 모든 script 는 **자기 디렉토리에서 `python3 *.py` 로 실행**. 다른 디렉토리에서 실행하면 `../../data/...` 상대경로가 깨짐.

### 4.1 "weight `.npy` 가 바뀌었어요" (재학습 등)

```bash
cd scripts/weights
python3 conv1_simd_pack.py
python3 conv2_simd_pack.py
```

→ `data/weights_simd/conv1_weights_simd.{hex,h}`, `conv2_weights_simd.{hex,h}` 갱신.
→ packed hex 가 바뀌었으므로 모든 testbench 재실행 필요.

### 4.2 "다른 image 로 single_img test 하고 싶어요"

```bash
cd scripts/single_img
python3 per_image_layer_hex.py 28     # image index 28
python3 per_image_layer_hex.py        # default: image 0
```

→ `data/single_img/conv1_input.hex`, `conv1_output_c1c2.hex`, `conv2_output_c2pool.hex` 갱신.
→ Maxpool / FC golden 도 필요하면 `maxpool_out.py`, `fc_out.py` 실행 (현재는 IMAGE_IDX 가 hard-coded = 0, 필요시 수정).

### 4.3 "multi_img 데이터 새로 만들 거예요"

```bash
cd scripts/multi_img
python3 gen_multi_img_hex.py
```

→ `data/multi_img/img000_*.hex` .. `img099_*.hex` (총 200 file) + `all_c1c2.hex` + `all_c2pool.hex` 갱신.
→ 약 5-10 초 소요.

### 4.4 "Conv weight packing 식이 맞는지 확인하고 싶어요"

→ `scripts/weights/conv1_simd_pack.py` (또는 `conv2_simd_pack.py`) 실행. 끝 부분 `[Verify] PASS — ...` 출력 확인.

---

## 5. RTL 모듈 책임 분담

| 디렉토리 | 담당자 | Top module | Key files |
|---|---|---|---|
| `RTL/conv1/`  | **신지민** | `conv1_engine_2.v` | `conv1_fsm.v`, `conv1_weight_loader.v`, `conv1_pe_cell.v`, `conv1_design.md` |
| `RTL/conv2/`  | **김도현** | `conv2_engine.v`   | `conv2_fsm.v`, `weight_loader.v`, `pe_cell.v`, `krow_ic_adder_tree.v`, `conv2_design.md`, `conv2_timing.md` |
| `RTL/maxpool/`| **김동주** | `maxpool_engine.v` | `maxpool_fsm.v`, `max_compare_tree.v` |
| `RTL/fc/`     | TBD       | `fc_engine.v`      | `fc_fsm.v`, `pe_array_fc.v`, `accumulator.v`, `argmax.v` |
| 통합          | (전원)    | `cnn_accelerator.v` | + `RTL/rtl_pingpong/c2pool_pingpong_buffer.v` |

> Conv1 의 top file 이름이 `conv1_engine_2.v` 인 이유: 신지민이 v1 → v2 로 refactor 한 후 `_2` suffix 를 그대로 둠. 인스턴스 module name 은 `conv1_engine` 으로 동일.

### 5.1 Module 간 interface (요약)

```
              [c1c2 buffer]                  [c2pool buffer]                  [pool buffer]
              64-bit × 2048                 128-bit × 2048                   8-bit × 4608
                    │                              │                              │
                    ▼                              ▼                              ▼
  Conv1 ─wdone→  c1c2  ─rdone→  Conv2  ─wdone→  c2pool  ─rdone→  Maxpool  ─wdone→  pool  ─→  FC
        ←rdone─       ←wdone─         ←rdone─         ←wdone─           ←rdone─
```

Handshake: 각 engine 은 `prior_wdone` (입력 데이터 준비됨) / `succ_rdone` (출력 buffer 비었음) 을 받고, `rdone` (입력 다 읽음) / `wdone` (출력 다 씀) 을 발행. **1-cycle pulse**.

---

## 6. Testbench 사용법

### 6.1 단위 검증 (single image)

| TB | DUT | 입력 hex | Expected hex | 비고 |
|---|---|---|---|---|
| `TB/single_img/tb_conv1_engine.v`   | `conv1_engine`   | `conv1_weight.mem` + `input_image.mem` | (script 가 비교) | 출력 → `conv1_out.hex` 저장 |
| `TB/single_img/tb_conv2_engine.v`   | `conv2_engine`   | `conv1_output_c1c2.hex` + `conv2_weights_simd.hex` | `conv2_output_c2pool.hex` | bit-exact 비교 |
| `TB/single_img/tb_maxpool_engine.v` | `maxpool_engine` | `conv2_out.hex` + `python_maxpool_ref.hex` | (내장 비교) | 출력 → `maxpool_out.hex` |

### 6.2 Stress test (multi image)

| TB | DUT | 입력 hex | Expected hex | 비고 |
|---|---|---|---|---|
| `TB/multi_img/tb_conv2_engine_multi.v` | `conv2_engine` | `all_c1c2.hex` (102,400 line) + `conv2_weights_simd.hex` | `all_c2pool.hex` (57,600 line) | 100 image 연속 검증 |

### 6.3 실행 방법 (Vivado XSIM)

```
Vivado → Open Project → 본 repo 의 .xpr (없으면 Create Project → Add Sources → RTL/* + TB/*)
→ Run Simulation → Run Behavioral Simulation
```

> **DSP48E1 primitive** 사용 → Xilinx `unisim` library 필수. iverilog/verilator 는 stub 필요.

### 6.4 hex file path (TODO: 통일 필요)

현재 모든 TB 가 **Windows 절대경로 hard-coded**:
```verilog
`define CONV1_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/.../conv1_output_c1c2.hex"
```
→ 본인 경로로 수정 또는 (TODO) `data/single_img/...` 상대경로로 통일.

---

## 7. Pitfall / 주의사항

### 7.1 Reset polarity — Conv1 vs Conv2 다름!

| Module | Reset signal | Polarity |
|---|---|---|
| `conv1_engine` | `rst_n` | **active low** |
| `conv2_engine` | `rst`   | **active high** |
| `maxpool_engine` | `rst` | **active high** |
| `fc_engine` | `rst`     | **active high** |

→ `cnn_accelerator.v` 에서 통합할 때 **inverter 추가 필요** (`conv1.rst_n = ~reset` 또는 `~resetn`). 현재 top file 에 `wire reset = ~resetn;` 만 있음.

### 7.2 BMG IP 설정 — Conv2 의 weight, c1c2, c2pool 이 모두 다름

| BMG | Depth | Width | Primitive Output Register | Latency (L) | Byte Write |
|---|---|---|---|---|---|
| `conv2_weight_bram` | 1024 (576 entry 사용) |  32 | **Enable** (Port B) | 2 | Disable |
| `c1c2 buffer`       | 2048 (2 bank × 1024)   |  64 | **Enable** (Port B) | 2 | Disable |
| `c2pool buffer`     | 2048 (2 bank × 1024)   | 128 | **Disable**         | 1 | Disable |

→ Vivado IP catalog 에서 BMG 생성 시 위 설정대로. **`L` 이 틀리면 pipeline timing 어긋남** → conv2_engine.v 의 9-cycle delay pipeline 이 정확히 L=2 를 가정하고 설계됨.

### 7.3 데이터 stride — padded vs compact

| Buffer | Stride | Padding | Address 공식 |
|---|---|---|---|
| `c1c2`   | 32 (padded) | h ∈ [26,31] or w ∈ [26,31] → 0 | `bank*1024 + h*32 + w` |
| `c2pool` | 24 (compact) | 없음 (write_addr sequential) | `bank*1024 + h*24 + w` |

→ Conv2 입력 BRAM 의 valid `(h, w)` 는 0..25 이지만 stride 가 32 임에 주의. **hex line index = `h*32 + w`** (NOT `h*26 + w`).

### 7.4 SIMD overflow (W1 = -128, W0 < 0)

DSP48E1 의 carry 보정이 깨지는 corner case. `conv*_simd_pack.py` 실행 시 `ovf_count` 출력 → **0 이어야 안전**. 학습된 weight 의 range 는 ±127 로 clip 되어 있어 보통 0.

### 7.5 Weight loader 는 시스템 부팅 시 1회만 동작

`conv2_engine.v` 의 `weight_loader` 는 LOAD_WEIGHTS state 에서 BMG → 192 PE 로 weight 적재 후 종료. **Inference 중에는 weight 가 PE register 에 상주**. weight 가 바뀌면 `start` pulse 로 재로드.

---

## 8. 최근 fix 이력

| 날짜 | 영역 | 내용 | 자세한 분석 |
|---|---|---|---|
| 2026-05-28 | Conv2 | **Adder drain bug** — image 28 의 마지막 2 pixel (addr 574, 575) 만 fail. `adder_en` 이 1-cycle 만 high → 5-stage adder pipeline 끝까지 마지막 PE 출력이 도달 못 함. **fix**: `adder_en` 을 5-cycle window OR 로 수정. | `RTL/conv2/conv2_adder_drain_bug_fix.md` |
| 2026-05-28 | Conv2 weight loader | BRAM read 메커니즘 수정 (BMG L=2 latency 고려) | `commit de35763` |
| 2026-05-23 | Conv2 | SystemVerilog 문법 → Verilog 변환, FSM BRAM latency 반영 | `commit 951f358` |
| 2026-05-?? | Conv2 | SIMD add (DSP48E1 패킹 정식 적용) | `commit 2f4e5c1` |

→ 새 bug fix 발견 시 본 표에 1 줄 추가 + 분석 문서는 해당 RTL/<module>/ 디렉토리에 `<module>_<bug>_fix.md` 형식으로 작성.

---

## 9. 부록: Git 협업 흐름

> 기본 git/PR workflow 는 본 가이드의 이전 버전 (commit history 참조) 에서 별도로 다뤘습니다. 본 섹션은 **본 프로젝트 특유의 git 규약** 만 다룹니다.

### 9.1 브랜치 전략

- **main**: 항상 동작하는 상태 유지. 직접 push 금지.
- **feature/<이름>-<모듈>** : 본인 작업 브랜치. 예: `feature/dohyun-conv2`, `feature/jimin-conv1`.
- **fix/<짧은 설명>** : bug fix 용. 예: `fix/conv2-adder-drain`.

### 9.2 Commit message convention

```
<scope>: <한 줄 요약>

(선택) 자세한 본문
```

scope 예시: `conv1`, `conv2`, `maxpool`, `fc`, `tb`, `scripts`, `docs`.

좋은 예:
- `conv2: fix adder drain bug for last 2 pixels`
- `scripts/weights: add Conv1 SIMD packing with exhaustive verify`
- `tb: unify hex file paths to relative data/`

피할 것:
- `update`, `fix`, `work in progress` 같은 정보 없는 메시지
- 한 commit 에 여러 module 섞기 (가능하면 scope 별 분리)

### 9.3 Code review 체크리스트

- [ ] Reset polarity 가 본인 모듈 convention 과 맞는지 (Conv1 active low, 나머지 active high)
- [ ] BRAM read latency (L) 가 가정한 값과 일치 (c1c2 L=2, c2pool L=1, conv2_weight L=2)
- [ ] Hex 포맷 (padding, packing order) 이 본 문서 §2 와 일치
- [ ] DSP48E1 / unisim 의존 코드는 simulation library 명시
- [ ] FSM state transition 이 다른 engine 의 handshake (rdone/wdone) 와 정렬

---

## 마무리

본 문서는 **convention 의 single source of truth** 입니다. RTL 에서 hex 포맷이 본 문서와 다르면 본 문서가 우선 (또는 본 문서를 update). 변경 시 PR 에 본 문서 갱신 포함.

질문 / 모호한 부분 → 김도현 (Conv2, 본 문서 작성자) 또는 해당 모듈 담당자에게 문의.
