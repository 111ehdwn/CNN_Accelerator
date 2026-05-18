# MNIST CNN 가속기 구현 메모

**보드**: Arty-A7 100T (DSP48E1 240, BRAM 135, LUT 63K)
**CNN**: Conv1(1→8, 3×3) → ReLU → Conv2(8→16, 3×3) → ReLU → MaxPool(2×2) → FC(2304→10)
**제공**: signed INT8 가중치, 입력 이미지 10K, 기대 logit (`.npy` 5개)
**제출**: INT8 기본 가속기 + (선택) lower-bit 가속기 별도. 둘 다 검증 필수.
**마감**: 작업 6/5까지, 보고서 6/19
**원칙**: 단계별 동작 베이스라인 확보 후 다음으로

## 병목 분석

Conv1: 1→8 ch, 26×26 output → 8 × 26² × 9 = **48,672 MAC/image**
Conv2: 8→16 ch, 24×24 output → 16 × 8 × 24² × 9 = **663,552 MAC/image** ← **병목**
FC: 2304 → 10 → **23,040 MAC/image**

**Conv2가 전체 MAC의 약 90%**. Winograd는 Conv2에만 적용해도 큰 효과.

## 알고리즘 진행 경로

Output Stationary Direct + SIMD (전체) → 시스템 최적화 + 오버클럭 → Conv2를 복소수 F(4,3)으로 교체 → 복소수 F(4,3) + 오버클럭

F(2,3)은 복소수 F(4,3) 대비 throughput 우위가 크지 않고, 중간 검증 단계로의 가치가 작아 생략.

## 양자화 원칙

- **기본 트랙**: 가중치/activation 모두 signed INT8 (과제 명세대로, LSB 10bit 버림 + saturation)
- **Lower-bit 트랙** (추가 점수, 별도 IP): **전 레이어 균일하게** weight 추가 양자화 (INT7~INT4, Log2). Activation은 INT8 유지 (calibration 위험).
- Winograd는 Conv2에만 적용 (병목 집중). Conv1, FC는 Direct.

---

## 0단계 — Python 정확도 검증 (~5/19)

**목적**: 각 변형 (Winograd 도메인 양자화, weight 재양자화)을 실제 CNN inference에 적용했을 때 MNIST 10K 정확도 측정. **정확도만**. 자원/사이클 추정은 Verilog 합성 후 측정.

### SIMD packing 한도 (참고)

DSP48E1: $2N + M \leq 25$ (N = A측 packing 비트, M = B측 단일 비트)
- Direct + INT8 weight + INT8 activation: 24 ≤ 25 ✓
- 복소수 F(4,3) 변환 후 (input m, weight n bit): V = m+6, U = n+4 → INT8 input/weight면 2(8+4)+(8+6)=38, SIMD 불가
- → Winograd에서 SIMD 적용하려면 변환 도메인 양자화 필요. 양자화 없으면 1 DSP/mul.

### Winograd 양자화 모드 (Conv2용)

- **옵션 A**: 원본 INT8 → 변환 → U/V 그대로 큰 비트. SIMD 불가, 1 DSP/mul. 무손실.
- **옵션 B**: U만 변환 후 양자화 + V saturation. SIMD 가능.
- **옵션 C**: U+V 둘 다 변환 후 양자화. SIMD 한도 안.
- **옵션 D**: 변환 전 weight 양자화. U 자동 작아짐.

### 측정 방법

- 과제 `.npy` 5개 로드 (input, output, layer1_0_weight, layer2_0_weight, fc1_weight)
- numpy로 **실제 CNN 전체 추론** (Conv1 → ReLU → Conv2 → ReLU → MaxPool → FC) 10K 이미지
- 명세대로 INT8 saturation (LSB 10bit 버림 + saturation)
- INT8 Direct가 reference, 기대 logit과 비트 매칭 필수

### 측정 시나리오

baseline:
1. INT8 Direct (전 레이어, reference, 비트 매칭 검증)

속도 트랙 (Conv2만 복소수 F(4,3), 나머지 Direct INT8):
2. 복소수 F(4,3) + INT8 weight + U/V 큰 비트 (옵션 A)
3. 복소수 F(4,3) + U → INT8 + V → INT9 양자화 (2×8+9=25, SIMD ✓)
4. 복소수 F(4,3) + U → INT9 + V → INT7 (2×9+7=25, SIMD ✓)
5. 복소수 F(4,3) + U → INT8 + V → INT8 (2×8+8=24, SIMD 여유)
6. 복소수 F(4,3) + INT4 weight 사전 양자화 (옵션 D)

자원 트랙 (Direct, 전 레이어 균일 weight 양자화):
7. Direct + INT7 weight
8. Direct + INT6 weight
9. Direct + INT5 weight
10. Direct + INT4 weight
11. Direct + signed Log2 4-bit weight
12. Direct + signed Log2 3-bit weight (시간 되면)

각 시나리오 두 측정:
- 절대 정확도: argmax(logit) == true_label 비율
- Reference 일치율: argmax(my_logit) == argmax(expected_logit) 비율
- INT8 baseline은 reference 100% 일치 필수 (비트 매칭으로 명세 준수 검증)

양자화는 layer별 scale 재조정 후 round-to-nearest.

**검증**: INT8 명세 reference가 기대 logit과 비트 매칭
**산출**: 시나리오 12개 정확도 비교표. 두 결정:
- 속도 트랙: 어떤 Winograd 양자화 옵션이 정확도 OK인가 (Verilog 알고리즘 선택)
- 자원 트랙: 어떤 lower-bit 양자화가 정확도 OK인가 (별도 IP 진입 여부)

---

## 1단계 — Verilog Baseline: Output Stationary Direct + SIMD (~5/24)

목표: 안정 동작 가속기. Design review 시연용. 명세상 기본 INT8 가속기.

- TA1 골격 재활용 (CSR, AXI BRAM Ctrlr, top_memory_ctrlr)
- BRAM 배치 (IMEM ping-pong, WMEM, FMAP1, FMAP2, POOL_OUT, RESULT)
- DSP48E1 SIMD INT8 dual-MAC 모듈 단독 검증 후 사용
- **Output Stationary PE** (a × w 누적 형태로 추상화 → 후속 단계에서 재활용)
- Conv1, Conv2 Direct + SIMD (output channel pair 공통 activation)
- MaxPool, FC, ReLU, INT8 saturation (LSB 10bit 버림)
- PL timer (CSR_TIMER_START 트리거, 첫 weight write ~ 마지막 output read)
- Vitis 드라이버 (가중치 → 10K 이미지 루프 → 결과)
- 클럭 100MHz

**검증**: 보드 결과가 0단계 Python INT8 sim 및 기대 logit과 비트 일치
**산출**: 동작하는 INT8 가속기. 5/20·22 design review OK. 명세상 기본 제출물.

---

## 2단계 — 시스템 최적화 + 오버클럭 (~5/31)

목표: 1단계 위에 시스템 효율 극대화. 알고리즘 변경 없이 latency 감소.

- IMEM/RESULT ping-pong 완성 (PS-PL overlap)
- Conv2 → Pool 또는 Pool → FC streaming fusion (가능하면)
- **균일 클럭 향상** (100 → 150 → 200MHz 단계적)
  - DSP48E1 -1 grade 최대 464MHz, BRAM 388MHz가 한도. 현실 design은 critical path가 결정
  - 기법: DSP 풀 파이프라인 (A_REG, B_REG, M_REG, P_REG), BRAM output register, critical path register 분할
  - Multi-pumping은 CDC 부담으로 배제, 균일 오버클럭이 단순함과 효과의 균형

**검증**: 1단계 결과와 비트 일치, Vivado Fmax 확인
**산출**: 오버클럭된 Direct+SIMD 가속기. **여기까지가 안전 baseline**.

---

## 3단계 — Conv2를 복소수 F(4,3)으로 교체 (오버클럭 없이) (~6/3)

목표: Conv2 병목에 알고리즘 교체. 곱셈 수 절감 (Direct 72 → 복소수 F(4,3) Naive 20 mul/output pixel). 클럭은 100MHz로 보수적, 알고리즘 변경에만 집중.

- 점 집합 `{0, ±1, ±i, ∞}` 복소수 F(4,3)
- 입력 변환 B^T d B (가산기 트리, 곱셈 0, 변환 후 V 위치별 8~13 bit)
- 가중치 변환 G g G^T (사전 계산 또는 PL 초기화)
- Element-wise mul: Naive 복소수 곱 (실/허부 분리, 켤레쌍으로 절반)
  - 0단계 결과에 따라 옵션 A (큰 비트, 1 DSP/mul) 또는 옵션 B-D (양자화 + SIMD) 선택
- 출력 변환 A^T M A (가산기 트리, ¼ 흡수)
- Output Stationary PE 재활용 (1단계와 동일 구조, 데이터 공급만 변경)
- Conv1, FC는 1단계 그대로 (Direct + SIMD)
- 클럭 100MHz 고정

**왜 오버클럭 분리**: 복소수 데이터패스 (실/허 분리, 켤레 컨트롤, 변환 가산기 트리) 자체가 큰 변경. 동시에 오버클럭 시도하면 디버깅 지옥. 분리 검증.

**검증**: 0단계 복소수 F(4,3) Python sim과 비트 일치
**산출**: 복소수 알고리즘 동작 가속기.

---

## 4단계 — 복소수 F(4,3) + 오버클럭 (~6/5)

목표: 3단계 + 2단계의 오버클럭 기법 결합. 최종 가속기.

- 3단계 복소수 회로에 pipeline stage 추가
- Critical path 재분석 (복소수 변환 가산기 트리가 새 bottleneck 가능성)
- 150 → 200MHz 단계적 목표

**검증**: 3단계 결과와 비트 일치 + Fmax 확인
**산출**: 최종 가속기. 6/5 final presentation 시연.

---

## Lower-bit 양자화 IP (추가 점수, 병행 가능)

조건: 0단계에서 정확도 OK 확인 + 시간 여유

- 0-A 자원 트랙 결과에 따라 INT4-7 또는 Log2 weight 선택
- **전 레이어 균일 양자화** (Conv1, Conv2, FC 모두)
- Direct 가속기 별도 IP로 (1단계 구조 재활용, MAC 비트 폭만 축소)
- INT4 SIMD: A에 INT4 packing 더 많이 가능 (DSP 효율 ↑)
- Log2 weight: 곱셈 → 시프트, DSP 사용 감소

**명세 요구**: 추가 점수 받으려면 INT8 가속기 **및** lower-bit 가속기 둘 다 제출 + 검증. 시간 없으면 1순위 (메인 가속기) 완성에 집중.

---

## 보고서 (6/5 ~ 6/19)

- Theory: 2D conv, Winograd 유도, **복소수 F(4,3) 유도** (영구 노트)
- Architecture: 시스템 다이어그램, Output Stationary 데이터플로우
- Implementation: RTL, CSR, Vitis, 변환 회로
- Results: 단계별 latency (보드 실측), 자원, 정확도
- Discussion: 알고리즘 trade-off, **Gauss vs Naive SIMD 호환성**, 변환 후 비트 폭 분석, 오버클럭 vs Multi-pumping, Polar/사원수/NTT Future Work
- 제출: `TAS2_T#.zip` (코드), `TAS2_T#_이름_학번.pdf` (개인 보고서)

---

## Fallback

| 단계 실패 시 | 차선책 |
|---|---|
| 0단계 | 이론 분석만으로 진행 (정확도 데이터 없이 위험 감수) |
| 1단계 | TA1 sobel_ip 구조 최대 재활용. 명세상 기본 INT8 가속기는 무조건 동작해야 함 |
| 2단계 (오버클럭 실패) | 100MHz 그대로 제출, 복소수로 진행 |
| 3단계 (복소수 실패) | 2단계 (Direct+SIMD 오버클럭) 그대로 제출 |
| 4단계 (복소수+오버클럭 실패) | 3단계 (복소수 100MHz) 그대로 제출 |
| Lower-bit IP | 시간 부족 시 skip. 메인 가속기 완성 우선 |

각 단계 끝에서 다음 진입 결정. 위험 시 이전 단계 결과로 제출.

**핵심**: 1단계 (INT8 Direct+SIMD)는 명세 만족 위해 필수. 2단계는 안전 baseline. 3, 4단계는 GOAT 도전.

---

## 일정 요약

| 날짜 | 단계 |
|---|---|
| ~5/19 | 0단계 Python 정확도 측정 |
| 5/20·22 | Design review (1단계 진행 상황 발표) |
| ~5/24 | 1단계 Direct+SIMD @100MHz |
| ~5/31 | 2단계 시스템 최적화 + 오버클럭 |
| ~6/3 | 3단계 Conv2 복소수 F(4,3) @100MHz |
| ~6/5 | 4단계 복소수 F(4,3) + 오버클럭 |
| 6/5 | Final presentation |
| ~6/19 | 보고서 제출 |

---

## 자산

- `Winograd_Convolution_Notes.md`: 이론 (복소수 F(4,3) 유도, 비트 폭 분석, SIMD 호환성)
- 과제 `.npy` 5개: `input.npy`, `output.npy`, `layer1_0_weight.npy`, `layer2_0_weight.npy`, `fc1_weight.npy`
- TA1 코드: `sobel_ip.v`, `top_memory_ctrlr.v`, `csr_slave_axi_inner.v`
- 참고: UG479 (DSP48E1), WP486 (INT8 packing), DS181 (Artix-7)