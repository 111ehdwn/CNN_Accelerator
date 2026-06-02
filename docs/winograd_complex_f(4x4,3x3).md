# 복소수 Winograd F(4×4, 3×3) — 도출과 검증

**대상**: Conv2 layer (Arty A7-100T, MNIST INT8 CNN accelerator)
**목적**: 표준 실수 F(4,3)의 정밀도 문제를 해결하면서 곱셈 수를 최소화하는 변환 도출 및 검증
**핵심 결과**: 변환 행렬 원소가 Gaussian integer만으로 구성, 2D 실수 곱셈 **46회** (직접 144회 대비 **3.13× 절감**)

---

## 목차

1. [배경](#1-배경)
2. [표준 실수 F(4,3)의 한계](#2-표준-실수-f43의-한계)
3. [복소수 단위점 도입](#3-복소수-단위점-도입)
4. [변환 행렬 유도](#4-변환-행렬-유도)
5. [곱셈 수 정밀 검증](#5-곱셈-수-정밀-검증)
6. [비교표](#6-비교표)
7. [INT8 양자화 친화성](#7-int8-양자화-친화성)
8. [Hardware 구현 시 고려사항](#8-hardware-구현-시-고려사항)
9. [부록: 행렬 요약](#9-부록-행렬-요약)

---

## 1. 배경

### 1.1 Winograd 기본 형태

````
1D: y = A^T [(G·g) ⊙ (B^T·d)]
2D: Y = A^T [(G·g·G^T) ⊙ (B^T·d·B)] A

⊙ : element-wise 곱 (실제 곱셈 발생 위치)
````

3×3 컨볼루션의 직접 계산 곱셈 수 vs Winograd 비교:

| 변환 | 1D 곱셈 | 2D 곱셈 | 2D 절감 |
|---|---|---|---|
| 직접 (F(4×4) 기준) | 12 | 144 | 1.00× |
| 실수 F(2×2, 3×3) | 4 | 16 | 9.00× |
| 실수 F(4×4, 3×3) | 6 | 36 | 4.00× |
| **복소수 F(4×4, 3×3)** | **7** | **46** | **3.13×** |

복소수 F(4,3)이 실수 F(4,3)보다 곱셈 수는 약간 많지만, INT8 환경에서 무손실 변환이 가능해 양자화된 CNN에 적합.

### 1.2 핵심 차별화

- **INT8 양자화 bit-exact**: G, B, A'ᵀ 변환 행렬 원소가 모두 Gaussian integer {0, ±1, ±i(, ±4)} — 1/16 스케일은 weight 가 아니라 출력 shift(>>4)로 흡수 → direct conv 과 bit-exact
- **곱셈 수 감소**: 직접 144 → 46 (3.13×)
- **변환 행렬 sparse**: 0과 ±1, ±i 가 대부분 → 시프트와 부호 반전으로 처리

---

## 2. 표준 실수 F(4,3)의 한계

### 2.1 표준 행렬

표준 점 집합 `{0, ±1, ±2, ∞}` 사용 시 G 행렬:

````
G = (1/24) × [
   24    0    0
  -16  -16  -16
  -16   16  -16
    4    8   16
    4   -8   16
    0    0   24
]
````

원소: `{0, ±1/24, ±1/12, ±1/6, ±1/4}` ← **분수 등장**

### 2.2 INT8 양자화 시 문제

| 정밀도 | F(2,3) | 실수 F(4,3) | 복소수 F(4,3) |
|---|---|---|---|
| FP32 | ✅ 무손실 | ✅ 무손실 | ✅ 무손실 |
| FP16 | ✅ | ⚠️ 약간 손실 | ✅ |
| INT16 | ✅ | ⚠️ 측정 가능 | ✅ |
| **INT8** | ✅ | ❌ **심각** | ✅ **무손실** |

**이유**: `1/24` 등이 양자화 그리드에 떨어지지 않음. 누적 오차 발생.

→ **INT8 양자화된 CNN에서는 표준 실수 F(4,3) 부적합**.

---

## 3. 복소수 단위점 도입

### 3.1 동기

라그랑주 보간의 분모 = ∏(αₖ - αⱼ).

실수 점 `{0, ±1, ±2, ∞}`은 점 사이 거리가 균일하지 않음 (1, 2, 3, 4) → 분모에 분수 발생.

**관찰**: 4차 단위근 `{1, i, -1, -i}` 는 서로 거리가 모두 √2로 균일.

### 3.2 점 집합 선택

````
{0, 1, -1, i, -i, ∞}   (6점)
````

- 4차 단위근 (1, -1, i, -i) + 0 + ∞
- F(4,3)에 필요한 6점 (m + r - 1 = 4 + 3 - 1)
- ∞는 "최고차 계수만 본다"는 의미 (g(∞) = g₂, d(∞) = d₅)

### 3.3 켤레 대칭 활용

실수 입력/필터를 복소수 점에서 평가하면:

````
g(i) = (g₀ - g₂) + i·g₁
g(-i) = conjugate(g(i))
d(-i) = conjugate(d(i))
⇒ s(-i) = conjugate(s(i))
````

→ `i` 점에서만 계산하면 `-i` 점은 켤레로 자동 획득 (공짜).

---

## 4. 변환 행렬 유도

### 4.1 G 행렬 (필터 평가)

`g(x) = g₀ + g₁x + g₂x²` 평가:

| 점 α | g(α) | G의 행 |
|---|---|---|
| 0 | g₀ | [1, 0, 0] |
| 1 | g₀ + g₁ + g₂ | [1, 1, 1] |
| -1 | g₀ - g₁ + g₂ | [1, -1, 1] |
| i | (g₀ - g₂) + i·g₁ | [1, i, -1] |
| -i | (g₀ - g₂) - i·g₁ | [1, -i, -1] |
| ∞ | g₂ | [0, 0, 1] |

````
G = [
   1    0    0
   1    1    1
   1   -1    1
   1    i   -1
   1   -i   -1
   0    0    1
]
````

**원소**: `{0, ±1, ±i}` — Gaussian integer만! ✅

### 4.2 B^T 행렬 (입력 평가)

`d(x) = d₀ + d₁x + d₂x² + d₃x³ + d₄x⁴ + d₅x⁵` 평가:

| 점 α | d(α) |
|---|---|
| 0 | d₀ |
| 1 | d₀ + d₁ + d₂ + d₃ + d₄ + d₅ |
| -1 | d₀ - d₁ + d₂ - d₃ + d₄ - d₅ |
| i | (d₀ - d₂ + d₄) + i(d₁ - d₃ + d₅) |
| -i | (d₀ - d₂ + d₄) - i(d₁ - d₃ + d₅) |
| ∞ | d₅ |

````
B^T = [
  1    0    0    0    0    0
  1    1    1    1    1    1
  1   -1    1   -1    1   -1
  1    i   -1   -i    1    i
  1   -i   -1    i    1   -i
  0    0    0    0    0    1
]
````

**원소**: `{0, ±1, ±i}` ✅

### 4.3 A^T 행렬 (라그랑주 보간)

각 점 αₖ에 대한 라그랑주 기저 다항식 `Lₖ(x)`를 구하고, `s(x)`의 x², x³, x⁴, x⁵ 계수 추출.

#### 분모 계산

| αₖ | 분모 | 결과 |
|---|---|---|
| 0 | (0-1)(0+1)(0-i)(0+i) | -1 |
| 1 | (1)(2)(1-i)(1+i) | 4 |
| -1 | (-1)(-2)(-1-i)(-1+i) | 4 |
| i | i(i-1)(i+1)(2i) | 4 |
| -i | 켤레 | 4 |
| ∞ | (특별 처리) | 1 |

**핵심**: 모든 분모가 `{1, 4}` — 깔끔한 2의 거듭제곱.

#### 라그랑주 기저 다항식

````
L₀(x) = 1 - x⁴
L₁(x) = (x⁴ + x³ + x² + x) / 4
L₂(x) = (x⁴ - x³ + x² - x) / 4
L₃(x) = (x⁴ + ix³ - x² - ix) / 4
L₄(x) = (x⁴ - ix³ - x² + ix) / 4
L₅(x) = x⁵ - x
````

**검증** (L₃ + L₄는 실수):
````
L₃ + L₄ = (2x⁴ - 2x²) / 4 = (x⁴ - x²) / 2 ✓
````

#### A^T 행렬 (x², x³, x⁴, x⁵ 계수)

````
A^T = [
   0    1/4    1/4   -1/4   -1/4    0
   0    1/4   -1/4    i/4   -i/4    0
  -1    1/4    1/4    1/4    1/4    0
   0    0      0      0      0      1
]
````

**원소**: `{0, ±1, ±¼, ±i/4}` — ¼ 한 종류만 등장.

### 4.4 ¼ 처리 — 출력 shift 로 흡수 (bit-exact)

A^T 의 ¼ 을 **가중치로 흡수하면 안 된다**: `G'=(1/4)G` 로 두면 사전계산 weight `U'=G·g·Gᵀ/16` 가
분수가 되어 INT 저장 시 **반올림 → 손실**. 대신 **A^T 만 정수화하고, 그 스케일을 출력 shift 로 되돌린다**:

````
A'^T = 4 · A^T          (정수화, 런타임 변환)
U    = G · g · G^T      (가중치 변환 — G 스케일 안 함, 정수 그대로)
````

A'^T (정수):

````
A'^T = [
   0    1    1   -1   -1    0
   0    1   -1    i   -i    0
  -4    1    1    1    1    0
   0    0    0    0    0    4
]
````

**원소**: `{0, ±1, ±i, ±4}` — 시프트+부호만, 곱셈기 0개 ✅

**스케일 회수 (2D)**: `A'^T = 4·A^T` 를 양쪽에 쓰면 `A'^T · M · A' = 16·Y` (Y = 참 conv 출력, 정수).
출력에서 `>>4` 로 16 을 제거 → layer truncate `>>10` 과 합쳐 **`>>14` + saturate** 한 번에:

````
result = saturate( (A'^T · M · A') >> 14 )
       = saturate( 16Y >> 14 ) = saturate( Y >> 10 )    ← direct conv 과 완전 동일값
````

⭐ U, V, A'^T, B^T 전부 정수 + 곱·누적 정수 + 출력 shift 정확 → **direct conv 과 bit-exact**
(sim 에서 골든과 1:1 검증 가능). `G'=G/4` 흡수(분수 weight 반올림) 대비 이 점이 갈린다.

---

## 5. 곱셈 수 정밀 검증

### 5.1 1D F(4,3): 7 mul

6개 점에서 `s(αₖ) = g(αₖ) · d(αₖ)` 계산:

#### 실수 점 4개: 4 real mul

| 점 | s(α) |
|---|---|
| 0 | g₀ · d₀ |
| 1 | (g₀+g₁+g₂) · (d₀+d₁+d₂+d₃+d₄+d₅) |
| -1 | (g₀-g₁+g₂) · (d₀-d₁+d₂-d₃+d₄-d₅) |
| ∞ | g₂ · d₅ |

→ **4 real multiplications**

#### 복소수 켤레쌍 {i, -i}: 3 real mul

`s(-i) = conj(s(i))` → `i`에서만 계산:

````
g(i) = a + bi   where a = g₀-g₂, b = g₁
d(i) = c + di'  where c = d₀-d₂+d₄, d = d₁-d₃+d₅

(a+bi)(c+di') = (ac - bd) + (ad + bc)i
````

**Naive**: 4 real mul (ac, bd, ad, bc)

**Gauss trick**: 3 real mul

````
k₁ = a · (c + d)
k₂ = c · (b - a)
k₃ = d · (a + b)

Real part = k₁ - k₃
Imag part = k₁ + k₂
````

**검증**:
````
k₁ - k₃ = a(c+d) - d(a+b) = ac + ad - ad - bd = ac - bd ✓
k₁ + k₂ = a(c+d) + c(b-a) = ac + ad + bc - ac = ad + bc ✓
````

→ **3 real multiplications** (Gauss + 켤레)

#### 1D 합계

````
4 (real points) + 3 (conjugate pair, Gauss) = 7 real mul
````

직접 1D F(4,3) = 12 mul → **12/7 ≈ 1.71× 절감**.

### 5.2 2D F(4×4, 3×3): 46 mul

2D 점: `(αᵢ, βⱼ)` where `αᵢ, βⱼ ∈ {0, 1, -1, i, -i, ∞}`. 총 6×6 = 36 점.

#### 핵심 통찰: β = i 차원에서도 i 도입

`(α, β)` 점에서 U, V 값이 실수인지 복소수인지:

````
U(α, β) = G(α) · g · G(β)^T
        = Σ gᵢⱼ · α^i · β^j

β = i 이면 β^1 = i 항 등장 → U(α, i) 자체가 복소수
(α가 실수이더라도)
````

⭐ **(real α, complex β) 점에서도 U, V 모두 복소수**.

#### 점 분류 (36개)

| 그룹 | 조합 | 개수 |
|---|---|---|
| (real, real) | 4×4 | 16 |
| (real, complex) | 4×2 | 8 (4 켤레쌍) |
| (complex, real) | 2×4 | 8 (4 켤레쌍) |
| (complex, complex) | 2×2 | 4 (2 켤레쌍) |

#### 켤레 대칭 관계

실수 g, d 입력에서:
````
M(α, -i) = conj(M(α, i))   ← α 실수
M(-i, β) = conj(M(i, β))   ← β 실수
M(-i, -i) = conj(M(i, i))
M(-i, i) = conj(M(i, -i))
````

#### 그룹별 곱셈 수

**그룹 1: (real, real) - 16개**

U, V 모두 실수 → 각 1 real mul.

````
16 × 1 = 16 real mul
````

**그룹 2: (real, complex) - 4 unique pair × 3 mul**

α 실수, β = i: `U(α, i) = u_r + u_i·i`, `V(α, i) = v_r + v_i·i` (둘 다 복소수).

복소수 × 복소수 = Gauss로 3 real mul.

`(α, -i)`는 `(α, i)`의 켤레라 한 번만 계산.

````
4 unique (α ∈ {0,1,-1,∞}, β = i) × 3 mul = 12 real mul
````

**그룹 3: (complex, real) - 4 unique pair × 3 mul**

대칭 (β = real, α = i): 동일.

````
4 unique × 3 mul = 12 real mul
````

**그룹 4: (complex, complex) - 2 unique pair × 3 mul**

`{i, -i} × {i, -i}` 4개:
- `(i, i)`와 `(-i, -i)` 켤레쌍 → 1 unique
- `(i, -i)`와 `(-i, i)` 켤레쌍 → 1 unique

````
2 unique × 3 mul (Gauss) = 6 real mul
````

#### 2D 합계

````
Group 1: 16
Group 2: 12
Group 3: 12
Group 4:  6
────────────
Total:   46 real mul
````

⭐ **2D F(4×4, 3×3) = 46 real mul 검증 완료**.

직접 2D F(4×4, 3×3) = 144 mul → **144/46 ≈ 3.13× 절감**.

### 5.3 한 이미지 전체 검증

````
Conv2: IC=8, OC=16, output 24×24, kernel 3×3

Tile 수: (24/4) × (24/4) = 6 × 6 = 36 tile

Per (IC, OC) per tile: 46 mul
Per image: 36 tile × 46 mul × 8 IC × 16 OC = 211,968 real mul

vs 직접:
  24×24 output × 9 mul × 8 IC × 16 OC = 663,552 real mul
  
절감률: 663,552 / 211,968 = 3.13× ✓
````

---

## 6. 비교표

### 6.1 변환 행렬 원소

| | F(2×2, 3×3) | 실수 F(4×4, 3×3) | **복소수 F(4×4, 3×3)** |
|---|---|---|---|
| 점 집합 | {0, ±1, ∞} | {0, ±1, ±2, ∞} | **{0, ±1, ±i, ∞}** |
| 점 개수 | 4 | 6 | **6** |
| G 원소 | {0, ±1, ±½} | {0, ±1/24, ±1/12, ±1/6, ±1/4} | **{0, ±1, ±i}** (정수, 1/16은 출력 shift) |
| B^T 원소 | {0, ±1} | {0, ±1, ±2, ±4, ±5} | **{0, ±1, ±i}** |
| A^T 원소 | {0, ±1} | {0, ±1, ±2, ±4, ±8} | **{0, ±1, ±i, ±4}** (¼ 흡수 후) |
| 분수 | ½ 1개 (G) | 1/24까지 (G) | **없음** (1/16은 출력 >>4 shift) |

### 6.2 곱셈 수 비교

| | 1D 직접 | 1D Winograd | 2D 직접 | 2D Winograd | 2D 절감 |
|---|---|---|---|---|---|
| F(2×2, 3×3) | 6 | 4 | 36 | 16 | 2.25× |
| 실수 F(4×4, 3×3) | 12 | 6 | 144 | 36 | 4.00× |
| **복소수 F(4×4, 3×3)** | **12** | **7** | **144** | **46** | **3.13×** |

### 6.3 종합 점수

| 기준 | F(2,3) | 실수 F(4,3) | **복소수 F(4,3)** |
|---|---|---|---|
| 곱셈 절감 | ⭐⭐ | ⭐⭐⭐⭐ | **⭐⭐⭐⭐** |
| 변환 단순성 | ⭐⭐⭐ | ⭐⭐ | **⭐⭐⭐** |
| INT8 양자화 친화성 | ⭐⭐⭐ | ⭐ | **⭐⭐⭐** |
| 라인버퍼/메모리 | ⭐⭐⭐ | ⭐⭐ | **⭐⭐** |
| 구현 난이도 | ⭐⭐⭐ | ⭐⭐ | **⭐⭐** |

---

## 7. INT8 양자화 친화성

### 7.1 표준 vs 복소수 변환 비교

**표준 실수 F(4,3)**:
````
G의 ±1/24 → 양자화 그리드에 못 떨어짐
INT8 환경에서 ×(1/24) 후 ×24가 정확히 복원되지 않음
누적 오차 발생
```` 

**복소수 F(4,3)**:
````
G, B^T, A'^T 모두 Gaussian integer ({0,±1,±i,±4})
U=G·g·G^T 정수, V=B^T·d·B 정수
변환 = 덧셈 + 부호 반전 + i 곱 (swap+negate) + ×4 (shift)
1/16 스케일은 weight 가 아니라 출력 >>4 (layer >>10 과 합쳐 >>14)
모든 연산이 비트 단위로 정확 → direct conv 과 bit-exact ✅ (sim 검증 가능)
````

### 7.2 비트 폭 분석

````
입력 d: INT8 (-128 ~ 127)

V = B^T · d · B (변환된 입력):
  각 element = ±1, ±i 계수로 d의 9개 element 선형 결합
  Max |element| = 9 × 128 ≈ 1152
  → 12-bit signed (real, imag 각각)

g도 INT8, U = G · g · G^T (G 스케일 안 함, 정수):
  Max |element| ≈ 9 × 128 = 1152 → 12-bit signed (real, imag 각각)
  사전 계산하여 INT12 로 저장 — G 정수라 U 정수, 반올림 없음

Element-wise mul (U ⊙ V):
  12-bit × 12-bit = 24-bit signed

Output transform (A'^T · M · A'):
  A'^T 원소 {0, ±1, ±i, ±4}, 양쪽 ×4 → 결과 = 16 × 참출력
  46 element 누적 + ×4 (shift)
  → 24 + log₂(46) + 2 ≈ 33-bit signed

최종 truncate: >>14 (Winograd 1/16 + layer 1/1024) 후 saturate ±127 → 8-bit signed
  = saturate(16Y >> 14) = saturate(Y >> 10) → direct conv 과 동일값
````

### 7.3 SIMD Packing 불가

표준 DSP48E1 SIMD packing (8-bit × 8-bit, Aport 25-bit):

````
Aport에 W₁ × 2^k + W₀ packing 시도:
  W (변환 후): ~12-bit signed
  X (변환 후): ~12-bit signed
  
  W₀ · X = 12-bit × 12-bit = 24-bit
  k ≥ 24
  Aport = W₁ × 2^24 + W₀ → 12 + 24 = 36-bit
  > 25-bit (Aport 한계) ❌
````

**결론**: 복소수 변환은 변환 후 비트 폭 증가로 인해 SIMD packing 불가능. 한 DSP에 하나의 곱셈.

---

## 8. Hardware 구현 시 고려사항

### 8.1 변환 모듈 위치

````
[입력 BRAM (c1c2)] 
    ↓ (8 IC byte stream)
[Line buffer 5개]
    ↓ (6×6 tile 형성)
[Input transform: V = B^T · d · B]    ← 새 모듈
    ↓ (6×6 complex elements)
[Element-wise mul: M = U ⊙ V]         ← DSP array
    ↓ (6×6 complex, 16 OC, sum over 8 IC)
[Output transform: Y = A'^T · M · A']  ← 새 모듈
    ↓ (4×4 real output, 16 OC)
[Truncate + ReLU]
    ↓
[c2pool BRAM]
````

### 8.2 변환된 가중치 사전 계산

````
U = G · g · G^T 는 사전 계산 가능 (g는 고정, G 정수라 U 도 정수 → 무손실):
  Python pre-pack 스크립트:
    for OC in 0..15:
      for IC in 0..7:
        g = weights[OC, IC]      # 3×3 INT8
        U = G @ g @ G.T          # 6×6 complex INT (G 스케일 안 함)
        U_real[OC, IC] = U.real  # 6×6 INT12 (정수, 반올림 없음)
        U_imag[OC, IC] = U.imag  # 6×6 INT12
  ※ ¼(2D는 1/16)은 weight 가 아니라 출력 >>4 로 처리(§4.4) → U 분수화/반올림 없음

저장: 16 OC × 8 IC × 6×6 × 2 (real, imag) × 12-bit
    = 18,432 bytes ≈ 18 KB
    (BRAM 1개 충분)
````

### 8.3 DSP 분배 (확정: 46-unit, 184 DSP)

DSP 한도 204 (Conv1 18 + FC 18 + Maxpool 0 = 36 고정 제외, 240 - 36) 내에서, effective mul/cycle을 최대화하는 분배를 탐색.

분배 공식:
````
DSP = (cycle당 mul slot) × IC_par × OC_par × Tile_par ≤ 204
Cycle/image = (cycle per (IC,OC,tile)) × (8/IC_par) × (16/OC_par) × (36/Tile_par)
````

unit 후보 (cycle당 mul 처리 단위): 9 (행 단위), 16 (3-cycle schedule), 46 (전체 element).

| Unit | 분배 (IC, OC, Tile) | DSP | Cycle/image | Util |
|---|---|---|---|---|
| 16 | (8, 1, 1) | 128 | 1,728 | 95.8% |
| 9 | (8, 2, 1) | 144 | 1,728 | 85% |
| **46** | **(4, 1, 1)** | **184** | **1,152** | **100%** |
| 46 | (2, 2, 1) | 184 | 1,152 | 100% |

**채택: 46-unit, (IC=4, OC=1, Tile=1), 184 DSP**

````
한 cycle: 4 IC × 46 element mul = 184 mul (한 (OC, tile)의 4 IC 처리)
한 (OC, tile): 8 IC / 4 = 2 cycle (cross-IC accumulation)
한 tile (16 OC): 2 × 16 = 32 cycle
전체 (36 tile): 32 × 36 = 1,152 cycle (compute only)
````

선택 이유:
- 46-unit이 utilization 100% (16/9 unit은 dummy DSP 발생)
- (IC=4) 분배가 OC sequential → weight broadcast 단순, cross-IC adder 4-input
- 184 DSP로 204 한도 내, 곱셈 work를 cycle당 최대로 채움

### 8.4 6×6 Tile 형성 (Line Buffer)

Winograd F(4,3)은 6×6 input tile 필요. tile은 stride 4, overlap 2 (인접 tile이 2 col 공유).

| 옵션 | 설명 | 평가 |
|---|---|---|
| 26-deep 2 line buffer (baseline) | tile 형성 시 raster 비효율 | ✗ |
| 5~6 line buffer × 26 col | row group 형성 후 6 tile 추출, BRAM ↑ | ✅ 권장 |
| Random access input BRAM | tile당 36 read, port 압박 | ✗ |

권장: 6 line buffer × 26 col. 6 row 채워지면 한 tile row (6 tile) 추출, 이후 4 row마다 다음 tile row.

### 8.5 변환 모듈 LUT 비용 추정

````
Input transform (B^T · d · B):
  B^T 원소 {0, ±1, ±i} → 덧셈 + 부호 반전 + swap
  곱셈기 0개
  덧셈기 ~수십~수백 (정확한 수는 구현 시)

Output transform (A'^T · M · A'):
  유사 구조, 곱셈기 0개
  덧셈기 + shift (×4)

추정: 변환 모듈 합 ~10~15K LUT (baseline adder tree보다 큼)
````

### 8.6 성능 비교 (모듈별 cycle)

각 layer per-image cycle 집계. Conv2 baseline은 testbench 측정값, 나머지는 명세/설계 문서 기반 계산.

#### Baseline 각 모듈

| Layer | DSP | Cycle/image | 출처 |
|---|---|---|---|
| Conv1 | 18 | 1,634 | 설계 문서 (2-round) |
| Conv2 | 192 | 1,798 | testbench 측정 |
| Maxpool | 0 | ~590 | 계산 (24×24 raster) |
| FC | 18 | ~640 | 계산 (23,040 MAC / 36) |

````
Baseline bottleneck: Conv2 1,798 cycle/image
````

#### Conv2 Winograd 적용 (compute + 변환 overhead)

| 항목 | Cycle |
|---|---|
| Line buffer fill (6 row × 26 col) | ~156 |
| Compute (46-unit, 184 DSP) | 1,152 |
| Input/output transform (첫·마지막 tile) | ~4 |
| DRAIN | ~12 |
| **추정 total** | **~1,324** |

````
Conv2 단독: 1,798 → ~1,324 (1.36× 빠름), DSP 192 → 184
````

#### Bottleneck 변화

| 구성 | Conv1 | Conv2 | Maxpool | FC | Bottleneck |
|---|---|---|---|---|---|
| Baseline | 1,634 | 1,798 | ~590 | ~640 | **Conv2 1,798** |
| Conv2 Winograd만 | 1,634 | ~1,324 | ~590 | ~640 | **Conv1 1,634** |
| + Conv1 재분배 | ~837 | ~1,324 | ~590 | ~640 | **Conv2 ~1,324** |

- Conv2만 Winograd 적용 시 Conv1(1,634)이 새 bottleneck → Conv2 절감분 일부만 반영
- Conv1(DSP 36, 1-round) 재분배 시 Conv2 Winograd가 bottleneck, 전체 효과 발휘
- FC(~640)는 baseline에서 이미 충분히 빠름 → 재분배 불필요

#### 전체 latency (10K image, compute only)

| 구성 | Bottleneck | @ 180 MHz | @ 200 MHz |
|---|---|---|---|
| Baseline | 1,798 | ~99.9 ms | ~89.9 ms |
| Conv2 Winograd만 | 1,634 | ~90.8 ms | ~81.7 ms |
| + Conv1 재분배 | ~1,324 | ~73.6 ms | ~66.2 ms |

#### DSP 사용량

| 구성 | Conv1 | Conv2 | FC | Total |
|---|---|---|---|---|
| Baseline | 18 | 192 | 18 | 228 / 240 |
| Conv2 Winograd만 | 18 | 184 | 18 | 220 / 240 |
| + Conv1 재분배 | 36 | 184 | 18 | 238 / 240 |

---

## 9. 부록: 행렬 요약

### 9.1 핵심 행렬

````
G (가중치 변환, 6×3):
[
   1    0    0
   1    1    1
   1   -1    1
   1    i   -1
   1   -i   -1
   0    0    1
]

U = G · g · G^T  (정수, 사전 계산) — G 스케일 안 함. 1/16 은 출력 >>4 (A'^T=4A^T 양쪽 → layer >>10 과 합쳐 >>14)

B^T (입력 변환, 6×6):
[
  1    0    0    0    0    0
  1    1    1    1    1    1
  1   -1    1   -1    1   -1
  1    i   -1   -i    1    i
  1   -i   -1    i    1   -i
  0    0    0    0    0    1
]

A'^T (출력 변환, 4×6, ¼ 흡수 후):
[
   0    1    1   -1   -1    0
   0    1   -1    i   -i    0
  -4    1    1    1    1    0
   0    0    0    0    0    4
]
````

### 9.2 곱셈 수 공식

````
1D F(m, r): m + r - 1
2D F(m×m, r×r): (m + r - 1)²

복소수 F(4, 3): 1D 7, 2D 46 (켤레 + Gauss)
````

### 9.3 핵심 수식 (2D)

````
U = G' · g · G'^T         (6×6 complex, 사전 계산)
V = B^T · d · B           (6×6 complex)
M = U ⊙ V                 (6×6 complex, element-wise)
Y = A'^T · M · A'         (4×4 real)
````

---

## 보고서/발표용 한 문장 요약

> MNIST와 같이 작은 정수 입력에 대한 CNN 가속을 위해, 점 집합 `{0, ±1, ±i, ∞}`을 사용하는 복소수 Winograd F(4×4, 3×3) 변환을 도입한다. 표준 실수 변환의 G 행렬이 `1/12`, `1/24`와 같은 정밀도 손실을 야기하는 분수를 포함하는 반면, 복소수 변환은 G, B, A'ᵀ 모두 Gaussian integer `{0, ±1, ±i, ±4}` 로 구성되고 1/16 스케일은 출력 shift(>>4)로 흡수되어, INT8 환경에서 direct conv 과 **bit-exact** 변환이 가능하다 (sim 검증 가능). 켤레 대칭과 Gauss 트릭을 활용한 실제 곱셈 수는 46회로, 직접 컨볼루션 144회 대비 **3.13× 감소**한다.

---

## 참고

- Winograd, S. (1980). *Arithmetic Complexity of Computations*. SIAM.
- Lavin, A. & Gray, S. (2016). *Fast Algorithms for Convolutional Neural Networks*. CVPR.
- Toom–Cook multiplication: <https://en.wikipedia.org/wiki/Toom%E2%80%93Cook_multiplication>