Vivado & Verilog 로 작성하는 프로젝트이므로, RTL 코드는 반드시 베릴로그 문법에 맞춰서 작성할 것.

---

# 프로젝트 개요

Arty A7-100T FPGA 용 INT8 CNN 가속기 (MNIST 10,000장, latency 최소화 목표). PL 데이터패스 파이프라인:

```
Input BRAM → Conv1 →(c1c2)→ Conv2 →(c2pool)→ Maxpool →(poolfc)→ FC → class(0~9)
```

- stage 사이는 ping-pong BRAM 버퍼. 중앙 컨트롤러 없이 각 engine 이 **자체 FSM + bank-toggle FF** 로 분산 제어 (producer→consumer `write_done`, consumer→producer `read_done` 핸드셰이크).
- PS(MicroBlaze)는 AXI4-Lite CSR 로 제어(start/enable/img_ready, result/done/timer), AXI BRAM Controller 로 weight·image write.
- 깊은 아키텍처 설명은 `docs/project_overview.md` 참고 (단, 일부 모듈명은 이상화된 옛 이름이라 실제 파일명과 다를 수 있음 — 아래 맵이 현재 기준).

# 디렉터리 구조

## RTL/ — 합성 대상 Verilog
- `cnn_accelerator.v` — 최상위 모듈. 전체 배선 + 필요한 BMG IP 목록이 **파일 헤더 주석**에 정리돼 있음.
- `core/` — stage 공유 primitive
  - `pe_cell.v` — DSP48E1 SIMD INT8×2 곱셈 (핵심 알고리즘)
  - `line_buffer.v`, `window_register.v` — sliding-window 생성
  - `truncate_relu.v` — `>>shift` + saturate(±127) + ReLU
- `conv1/` — `conv1_engine` + `conv1_fsm` + `conv1_adder_tree` + `conv1_weight_loader`
- `conv2/` — `conv2_engine` + `conv2_fsm` + `kcol_accumulator` + `krow_ic_adder_tree` + `weight_loader` (throughput bottleneck)
- `maxpool/` — `maxpool_engine` + `maxpool_fsm` + `max_compare_tree`
- `fc/` — `fc_engine` + `fc_fsm` + `fc_pe_array` + `fc_adder_tree` + `fc_accumulator` + `fc_argmax`
- `rtl_pingpong/` — `c2pool_pingpong_buffer.v`
- `control_status_register/` — CSR AXI4-Lite slave (`csr_axi.v`, `csr_axi_slave_lite_v1_0_csr.v`, `axi_inner_ref.v`)
- ※ 모듈별 설계/타이밍/버그픽스 노트(.md)가 해당 폴더 안에 함께 있음 (`conv1/conv1_design.md`, `conv2/conv2_design.md`, `conv2/conv2_timing.md`, `conv2/conv2_adder_drain_bug_fix.md`).

## TB/ — Verilog 테스트벤치 (Vivado 없이 iverilog 로컬 시뮬 가능)
- `models/` — 합성 불가 시뮬 모델: `bmg_sim_models.v`(BMG/BRAM), `dsp48e1_model.v`
- `single_img/` — 단일 이미지 단위 TB (`tb_conv1_engine`, `tb_fc_engine`, …)
- `multi_img/` — 다중 이미지 통합 TB (`tb_cnn_accelerator_multi`=전체, `tb_system_axi_multi`=AXI 포함)

## scripts/ — 골든/입력 데이터 생성 (Python). 산출물은 `data/` 로
- `golden_sim/` — PyTorch bit-exact 레퍼런스 모델 (`reference_core.py`, `0_reference.py`)
- `single_img/gen_single_img_hex.py` → `data/single_img/`
- `multi_img/gen_multi_img_hex.py` → `data/multi_img/`
- `weights/weight_simd_pack.py` → `data/weights_simd/` (DSP SIMD packing)

## data/ — 생성된 검증/입력 데이터 (scripts/ 산출물, TB/·vitis/ 가 소비)
- `_base_npy/` — 원본 PyTorch npy (weight/input/output)
- `single_img/` — 레이어별 골든 hex (`conv1_input`, `*_c1c2`, `*_c2pool`, `maxpool`, `fc`)
- `multi_img/` — 다중 이미지 골든 hex (`all_*.hex`)
- `weights_simd/` — SIMD packed weight (`.hex`=TB용, `.h`=vitis용)

## docs/ — 문서
- `*.md` — 알고리즘/타이밍/버그픽스 (`DSP48E1_signed8x8_SIMD_Packing`, `project_overview`, `conv1_timing`, `handshake_counter_nba_race`, `axi_lite_write_hang_fix`, `block_design_manual`, `cowork_guide`)
- `ip_spec/` — Block Memory Generator IP **실제 생성 스펙 + 스크린샷**. data-path BRAM(`bram_input`, `bram_c1_to_c2`, `bram_c2_to_pool`, `bram_pool_to_fc`) / weight BRAM(`conv1_weight_bram`, `conv2_weight_bram`, `fc_weight_bram`) 별 폴더 + `block_memory_generator.md`
- `timing/` — 타이밍 스크린샷
- `pdfs/` — 과제 명세/참고자료 (`AS2_announcement`, `CNN Accelerator 구현 계획`, `Winograd`)

## vitis/ — PS(MicroBlaze) 펌웨어 (C)
- `main.c`, `test_images.h`, `uart_test.c`

## archive/ — 이전 과제(AS1 Sobel) 베이스라인 (참고용)