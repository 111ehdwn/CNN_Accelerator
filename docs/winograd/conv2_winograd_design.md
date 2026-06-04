# Conv2 Winograd F(4,3) — RTL 구현 설계서

알고리즘·행렬·곱셈수 도출은 `algorithm_complex_f43.md`(§9.1 정정판), bit-exact 정답은 golden `scripts/golden_sim/1_complex_winograd_f(4,3).py`. 본 문서는 **그 golden 을 그대로 RTL 로 옮기기 위한 하드웨어 설계 청사진**.

> 원칙: 기존 `RTL/conv2` 무변경. 본 엔진은 `RTL/conv2_winograd/` 에 새로, `cnn_accelerator.v` 에서 conv2 자리에 **drop-in**(동일 c1c2 입력·c2pool 출력·handshake). weight 경로만 교체.

---

## 0. 한 줄 요약

8 IC×26×26 INT8 → 16 OC×24×24 INT8 conv (3×3 stride1 no-pad) 을, **6×6 tile(stride4)** 단위로
`V=Bᵀ·d·B`(입력변환, 곱셈기0) → `M=Σ_IC U⊙V`(184 DSP) → `Y16=Aᵀ·M·A`(출력변환, 곱셈기0) → `sat(Y16>>14)+ReLU` 로 계산. 곱셈 144→46(3.13×), conv2 1798→~1324 cyc(1.36×), DSP 192→184.

---

## 1. 외부 인터페이스 (drop-in — conv2_engine 미러)

`conv2_engine` 과 **동일**(주변 파이프라인 무변경):

| 포트 | 방향 | 비고 |
|---|---|---|
| `clk, rst, start` | in | 동일 |
| `c1c2_re, c1c2_addr[10:0], c1c2_dout[63:0]` | in 읽기 | **동일** (8 IC × 8b/word, {bank,row[4:0],col[4:0]}) |
| `c2pool_we, c2pool_addr[10:0], c2pool_din[127:0]` | out 쓰기 | **동일** (16 OC × 8b) |
| `prior_wdone, rdone, succ_rdone, wdone` | handshake | **동일** (분산 FSM in-flight) |

**바뀌는 것 = weight 경로만**:

| 포트 | conv2 (현재) | conv2_winograd |
|---|---|---|
| weight Port A | `c2w_ena/wea[3:0]/addra[9:0]/dina[31:0]` (576×32b SIMD) | `uw_ena/wea/addra/dina` — **U weight BMG** (아래 §2) |
| 내부 weight 로딩 | `weight_loader` → pe broadcast | **U 직접 read** (pre-pack, broadcast 불필요 — §4) |

→ `cnn_accelerator.v` 에서 conv2 인스턴스를 conv2_winograd 로 교체 + weight BMG(conv2_weight_bram→u_weight_bram) 교체. 나머지 배선 동일.

---

## 2. Weight 포맷 — U 사전계산 (pre-pack)

`U = G·g·Gᵀ` 는 g 고정·G 정수라 **오프라인 정수 사전계산**(반올림 없음). golden `_prepare_weight` 와 동일.

```
for OC in 0..15, IC in 0..7:
    g = w2[OC,IC]                 # 3×3 INT8
    U = G @ g @ G.T              # 6×6 complex int (G 스케일 안 함)
    U_re[OC,IC] = U.real         # 6×6, |·| ≤ 9·127 ≈ 1143 → INT12 signed
    U_im[OC,IC] = U.imag         # 6×6, INT12 signed
```

- 저장: 16 OC × 8 IC × 36 × 2(re,im) × 12-bit ≈ **18 KB** (BRAM 1개).
- **U sparsity**: G_IM 이 i,−i 행에만 → U 의 많은 (p,q) 가 **real-only**(im=0). 이게 46<72(36×2) 곱셈의 근거(§5).
- 산출물: `scripts/weights/winograd_u_pack.py` → `data/weights_winograd/u_weights.hex`(TB) + `.h`(vitis). **bit-layout 은 golden U 와 1:1**.
- firmware: 새 헤더 direct write (SIMD 변환 없음, conv1/fc 와 동일 패턴).

> ★ 결정 포인트: U 를 어떤 word 폭으로 packing 할지(예: real/imag 12b 쌍 → 24b/element, 36 element/(OC,IC)). DSP array 가 cycle 당 IC=4×46 mul 을 쓰므로 weight read 대역과 정렬 필요(§4.3). pre-pack 스크립트가 RTL read 순서에 맞춰 배열.

---

## 3. 데이터패스 + 비트폭

```
c1c2 (8 IC byte stream, INT8)
   │
[Line buffer ×5~6, 26-col]  → 6×6 tile (8 IC 동시)            §6
   │  d: 6×6 INT8
[Input transform  V = Bᵀ·d·B]  (곱셈기 0, adder/shift/i-swap)  §3.1
   │  V_re,V_im: 6×6 INT12  (|V|≤9·127, V=16·V_true 라 실제 더 큼 → §3.1 비트폭)
[Element-wise  M = Σ_IC U⊙V]  (184 DSP, Gauss, IC=4 par, 2-cyc 누적)  §4
   │  M_re,M_im: 6×6  ~ INT12(U)·INT12(V)=24b + Σ8IC = ~27b signed
[Output transform Y16 = Aᵀ·M·A]  (곱셈기 0, adder/shift/×4)    §3.2
   │  Y16: 4×4  ~ 27 + log2(46) + 2(×4) ≈ 33b signed  (imag=0 보장)
[Truncate  sat(Y16 >> 14) + ReLU]                              §3.3
   │  8b INT8
[c2pool write]  (16 OC × 8b)
```

비트폭(golden §7.2 기준): d INT8 → V INT12(re/im) → U⊙V 24b → Σ_IC ~27b → Aᵀ··A ~33b → >>14 → INT8.

### 3.1 Input transform `V = Bᵀ·d·B` (곱셈기 0)
- Bᵀ(6×6) 원소 `{0,±1,±i,±4}`. d 는 real INT8. `t = Bᵀ·d`(6×6 complex), `V = t·B`(6×6 complex).
- 연산: **add / subtract / negate / ×4(=<<2) / i-swap**(복소수 ×i = (re,im)→(−im,re)). 곱셈기 없음.
- ×4 행(Bᵀ 1·6행, 1·6열)이 V=16·V_true 의 16배 스케일 일부를 만듦(나머지는 출력 Aᵀ 가 아니라 — ★정정판은 ¼이 **입력**에 있음, 즉 Bᵀ=4·true).
- RTL: golden 의 Bᵀ 행렬을 그대로 전개한 adder tree. 각 V[p][q] = Σ_k Σ_l BT[p][k]·d[k][l]·BT[q][l] 의 nonzero 항만. **첫 RTL 작업** — golden 으로 element 단위 검증.

### 3.2 Output transform `Y16 = Aᵀ·M·A` (곱셈기 0)
- Aᵀ(4×6) 원소 `{0,±1,±i}`. `y = Aᵀ·M`(4×6), `Y16 = y·A`(4×4). imag 은 수학적으로 정확히 0(golden assert) → real 만 RTL 로.
- 연산: add/sub/negate/i-swap. 곱셈기 없음. (정정판은 Aᵀ 에 ×4 없음.)

### 3.3 Truncate
- `out = saturate(Y16 >> 14)` arithmetic shift + clip(−128,127), 그다음 ReLU(maxpool 전이라 conv2 출력은 ReLU 적용 — 기존 `truncate_relu` 재사용 가능, shift 만 10→14). 16Y>>14 = Y>>10 = direct 와 동일.

---

## 4. Element-wise mul array — 184 DSP (핵심)

`M = Σ_IC (U ⊙ V)`. (OC,tile) 하나당 36 position 의 complex mult, 8 IC 누적.

### 4.1 분배 (algorithm §8.3 채택)
- **46-unit, (IC=4, OC=1, Tile=1), 184 DSP, util 100%.**
- 1 cycle: 4 IC × 46 real-mul = 184 DSP (한 (OC,tile)의 4 IC).
- (OC,tile): 8 IC / 4 = **2 cycle**(cross-IC 누적). tile(16 OC): 2×16=32 cyc. 36 tile: 1152 cyc(compute).

### 4.2 46 real-mul 구성 (golden §5.2)
position 36개를 U/V 의 real/complex 여부로 분류 → real-mul 수:
- (real α, real β) 16개: U,V real → **각 1 mul** = 16.
- (real,complex)·(complex,real)·(complex,complex)의 unique 켤레쌍: complex×complex → **Gauss 3 mul**. 4+4+2 unique × 3 = 30.
- 합 16+30 = **46 real-mul** / (IC,OC,tile).
- **Gauss trick**(복소수 1회 = 3 real-mul): `k1=a(c+d), k2=c(b−a), k3=d(a+b)` → `Re=k1−k3, Im=k1+k2`. 켤레 position(−i)은 계산 안 함(conj 로 무료).

### 4.3 DSP 매핑
- **SIMD packing 불가**(golden §7.3: V/U 12b → 곱 24b > Aport 25b 한계). **1 DSP = 1 real-mul** (12b×12b→24b).
- 184 DSP = 4 IC × 46. 각 IC 의 46-mul 유닛은 동일 구조(46 DSP) 복제.
- weight(U)·activation(V) broadcast: **conv2 의 192-PE broadcast 와 달리 46×4=184 로 군집 작음** → fanout 부담 적음. 단 200MHz route 주의(overclock 교훈: max_fanout 복제 패턴 적용).
- IC 누적: 2 cycle 에 걸쳐 4 IC + 4 IC = 8 IC. cross-IC 4-input adder(+ 2-cycle 누적 레지스터).

> ★ 설계 디테일(첫 RTL 시 확정): 46 position 각각이 어느 DSP·어떤 (a,b,c,d) 입력을 받는지의 **매핑표**. golden 의 U/V index → Gauss 입력 매핑을 스크립트로 생성해 RTL param 으로 박는 게 안전(conv2 weight_loader accumulator 처럼 사람이 안 푸는 방식).

---

## 5. FSM + cycle budget

tile 기반(36 tile × 32 cyc). 기존 conv2 FSM(LOAD→FILL→COMPUTE→DRAIN)과 유사하나 **tile 단위 streaming**.

| 항목 | cycle | 비고 |
|---|---|---|
| Line fill (6 row × 26 col) | ~156 | 첫 tile row 준비 |
| Compute (46-unit, 184 DSP) | 1152 | 36 tile × 32 |
| Transform fill/drain | ~4 | input/output transform pipe |
| DRAIN | ~12 | |
| **추정 total** | **~1324** | conv2 1798 대비 1.36× |

handshake(prior_wdone/rdone/succ_rdone/wdone)·bank toggle 은 conv2 와 동일 의미(분산 FSM in-flight) → maxpool/conv1 무변경.

---

## 6. Tile line buffer (6×6, stride4 overlap2)

- 6×6 tile, stride 4 → 인접 tile 이 2 col overlap. (algorithm §8.4: **6 line buffer × 26 col 권장**.)
- 6 row 채우면 한 tile-row(6 tile) 추출, 이후 4 row 마다 다음 tile-row. 8 IC 동시.
- 기존 `line_buffer.v` 재사용 가능(WIDTH=8, DEPTH 조정) 또는 winograd 전용 신규. tile 추출 = 6×6 window register.

---

## 7. 검증 (golden = bit-exact gate)

overclock 때처럼 **iverilog sim-first**:
1. **단위**: input transform RTL out == golden `V=BᵀdB` (element 단위). output transform == golden `Y16`. (X-prop·비트폭 확인.)
2. **엔진**: TB 가 f1(=relu(conv1)) 을 c1c2 에 주입 → conv2_winograd → c2pool == golden `f2_w`(=conv2_wino(f1)). 10000장(또는 샘플) bit-exact.
3. **e2e**: `tb_cnn_accelerator_multi` 의 conv2 를 winograd 로 바꾼 변형 → logit bit-exact.
4. golden 자체가 direct==winograd==output.npy 검증 완료 → RTL 만 golden 에 맞추면 끝.
- BMG sim model: U weight BMG 용 behavioral 추가(`bmg_sim_models.v` 패턴). DSP 는 기존 `dsp48e1_model.v`(initial 없음 → X-prop 유효).

---

## 8. 모듈 목록 (RTL/conv2_winograd/) + 빌드 순서

| 모듈 | 역할 | 의존 |
|---|---|---|
| `wino_input_transform.v` | Bᵀ·d·B (6×6 INT8 → 6×6 complex), 곱셈기0 | — |
| `wino_pe_mul.v` | 복소수 mult 유닛(Gauss 3-mul, DSP) | dsp48e1 |
| `wino_mul_array.v` | 46-unit × IC=4 = 184 DSP + IC 누적 | wino_pe_mul |
| `wino_output_transform.v` | Aᵀ·M·A (6×6 complex → 4×4 real), 곱셈기0 | — |
| `wino_tile_buffer.v` | 6×6 tile line buffer/window | line_buffer |
| `conv2_winograd_fsm.v` | tile FSM + handshake | — |
| `conv2_winograd_engine.v` | top 통합 (drop-in) | 전부 + U BMG |

**순서**: ① pre-pack 스크립트+U 헤더 → ② input/output transform(+golden 단위검증) → ③ mul array → ④ tile buffer+FSM → ⑤ engine 통합+golden e2e → ⑥ cnn_accelerator drop-in → Vivado.

---

## 9. 열린 질문 / 리스크

1. **transform adder 비용**: algorithm §8.5 추정 ~10–15K LUT(baseline adder tree 보다 큼). LUT 여유 확인 필요(현재 점유율).
2. **200MHz route**: 184 DSP + transform 의 배선. conv2 overclock 에서 배운 max_fanout 복제·register 파이프 패턴 선제 적용.
3. **U weight BMG 폭/깊이**: 18KB 를 어떤 word 로 (read 대역 = cycle 당 4 IC × 46 U-element). pre-pack 이 RTL read 순서에 정렬.
4. **46-position → DSP 매핑표**: 손으로 풀지 말고 스크립트 생성 param.
5. **conv1 bottleneck**: 본 엔진만으론 conv1(1634)이 bottleneck → `conv1_2x` (phase 2) 필수. (README 참조.)
6. **tile 경계 saturation/ReLU**: 기존 `truncate_relu`(shift 14) 재사용 검토.
