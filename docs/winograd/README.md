# Winograd Conv2 + Conv1 Rebalance — 작업 폴더 (index)

200MHz HW(108.9ms → Vitis feed-overlap 후 **98ms**) 이후의 **다음 latency 레버 = 알고리즘**.
클럭은 MMCM 한계로 200MHz가 max → conv2 의 곱셈을 **복소수 Winograd F(4,3)** 로 줄인다.
**이 폴더에서 모든 Winograd 관련 작업을 이어간다. 기존 `RTL/conv1`, `RTL/conv2` 는 건드리지 않는다(원본 보존).**

---

## 왜 2-파트인가 (conv2 Winograd + conv1 2×)

conv2 만 Winograd 하면 **conv1(1634 cyc)이 새 bottleneck** 이 되어 이득이 절반만 난다.
→ conv2 Winograd 로 비는 DSP 를 conv1 에 줘서(2-round→1-round, **DSP 2배 18→36**) conv1 을 ~837 로 내리면, conv2-Winograd(~1324)가 bottleneck 이 되어 전체 효과가 난다. **둘은 한 세트.**

| 구성 | Conv1 | Conv2 | FC | DSP Total | bottleneck | @200MHz floor* |
|---|---|---|---|---|---|---|
| 현재 (measured) | 18 | 192 | 18 | 228/240 | conv2 1798 | ~90ms (측정 98ms) |
| conv2 Winograd 만 | 18 | **184** | 18 | 220/240 | **conv1 1634** | ~82ms |
| **+ conv1 2×** | **36** | 184 | 18 | **238/240** | **conv2-wino ~1324** | **~66ms** |

\* compute-only floor (10000장 @200MHz). 실측엔 feed/pipeline overhead(현재 ~8ms) 가 더해짐.

---

## 폴더/파일 맵

| 경로 | 내용 | 상태 |
|---|---|---|
| `RTL/conv2_winograd/` | Winograd conv2 engine (184 DSP). conv2 와 **동일 외부 인터페이스**(drop-in) + **다른 weight BMG/loader** | RTL 착수 전 |
| `RTL/conv1_2x/` | conv1 DSP 2배(18→36, 1-round) rebalance. conv2-wino bottleneck 매칭용 | phase 2 (conv2 후) |
| `docs/winograd/algorithm_complex_f43.md` | 알고리즘 도출·검증·행렬(§9.1 정정판)·§8 HW 아키텍처 | ✅ 완성 |
| `docs/winograd/conv2_winograd_design.md` | **RTL 구현 설계서**(모듈 분해/인터페이스/dataflow/DSP 매핑/cycle/검증) | 작성중 |
| `docs/winograd/conv1_2x_design.md` | conv1 rebalance 설계 | phase 2 |
| `scripts/golden_sim/1_complex_winograd_f(4,3).py` | **bit-exact golden** (전체 10000장 검증 완료). RTL 검증 기준 | ✅ 완성 |
| `scripts/weights/` (예정) | U=G·g·Gᵀ pre-pack 스크립트 (weight → INT12 complex, 18KB) | 예정 |

---

## 불변 원칙 (설계 제약)

1. **원본 보존**: `RTL/conv1`, `RTL/conv2`, 기존 BMG/firmware 인터페이스를 깨지 않는다. Winograd conv2 는 `cnn_accelerator.v` 에서 conv2 자리에 **drop-in** (동일 c1c2 입력 / c2pool 출력 / handshake prior_wdone·rdone·succ_rdone·wdone). → 주변 파이프라인(conv1, maxpool, FSM) 무변경.
2. **weight 경로만 변경**: direct SIMD-packed → **U(6×6 complex INT12)** pre-pack. 새 weight BMG + loader. firmware 는 새 헤더 direct write.
3. **golden = 유일 검증 기준**: `1_complex_winograd_f(4,3).py` 가 RTL 의 bit-exact 정답. iverilog 로 f1→winograd conv2 결과 == golden f2_w 확인 (overclock 때처럼 sim-first).
4. **bit-exact 유지**: U/V/transform 전부 정수, 출력 `>>14`+saturate → direct conv 과 동일값. (실수 F(4,3)의 1/24 분수 문제를 복소수 {0,±1,±i,±4}로 회피 — 이게 이 변환을 쓰는 이유.)

---

## 빌드 순서 (제안)

**Phase 1 — conv2 Winograd**
1. weight pre-pack 스크립트 (U_re/U_im INT12, 새 헤더 + `.hex`).
2. 변환 모듈 RTL: input transform(Bᵀ·d·B) + output transform(Aᵀ·M·A) — **곱셈기 0개**(shift/부호/i-swap/×4 adder network). golden 으로 단위검증.
3. element-wise mul array: 184 DSP (IC=4 parallel, Gauss-trick 복소수 mult, 2-cycle IC 누적).
4. 6×6 tile line buffer + FSM (36 tile × 32 cyc).
5. engine 통합 + iverilog bit-exact (golden) → `cnn_accelerator.v` drop-in → Vivado.

**Phase 2 — conv1 2×** (conv2 Winograd 동작 확인 후)
6. conv1 2-round→1-round, DSP 18→36. iverilog bit-exact → 통합.

상세는 `conv2_winograd_design.md`.
