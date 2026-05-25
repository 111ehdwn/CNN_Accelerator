# DSP48E1 Signed 8×8 SIMD Packing 알고리즘 (Weight Packing)

## 0. 표기 규약 (Convention)

문서 전체에서 다음 규약을 엄격히 따른다.

**정수값과 비트 패턴의 구분**

| 표기 | 의미 |
|:--|:--|
| $W_0, W_1, X, A_{port}, P$ 등 일반 기호 | **정수값** (10진수, 부호 포함). 비트 폭은 별도로 명시 |
| $\operatorname{repr}_n(v) := v \bmod 2^n$ | 정수 $v$ 를 $n$-bit 2의 보수 **비트 패턴**으로 인코딩한 unsigned 값 |
| $\operatorname{sint}_n(u) := u$ if $u < 2^{n-1}$, else $u - 2^n$ | $n$-bit 비트 패턴 $u$ 를 signed 정수값으로 디코딩 |
| $V[i:j]$ | 정수 $V$ 를 비트 패턴으로 인코딩한 후의 비트 슬라이스 (unsigned) |

**등호의 의미**

문서의 모든 등호 (=) 는 **정수 등식**이다. 비트 패턴 차원의 등식은 항상 $\operatorname{repr}_n(\cdot)$ 또는 슬라이스 표기로 명시한다.

**라운드트립 성질**: $|v| \le 2^{n-1}$ 이면 $\operatorname{sint}_n(\operatorname{repr}_n(v)) = v$. 즉 $n$-bit signed 범위 내에서 정수↔비트패턴 변환은 가역.

---

## 1. 문제 정의

DSP48E1 의 단일 25×18 signed multiplier 로 두 개의 signed 8×8 곱셈을 동시에 수행한다.

**입력 정수값**: $W_0, W_1, X \in [-128, 127]$ (signed 8-bit 정수, INT8 양자화 결과)
- $W_0, W_1$: 서로 다른 두 weight
- $X$: 공유되는 input activation

**출력 정수값**: 
- $P_0 = W_0 \cdot X$
- $P_1 = W_1 \cdot X$

각각 $|P_i| \le 128 \cdot 128 = 2^{14}$ 이므로 16-bit signed 범위 내.

**제약**: 모든 $2^{24}$ 개 입력 조합 (-128 포함) 에서 정확.

---

## 2. Packing 정의

### 2.1 정수값 차원

DSP 의 두 곱셈 입력 정수값을 다음과 같이 정의:

$$A_{port} := W_1 \cdot 2^{17} + W_0 \quad \text{(정수)}$$
$$B_{port} := X \quad \text{(정수)}$$

$A_{port}$ 는 두 weight 를 $2^{17}$ 의 자리에 분리해 묶은 단일 정수. $B_{port}$ 는 입력 activation 그대로.

이 정수들의 곱은 분배법칙에 의해:

$$A_{port} \cdot B_{port} = (W_1 \cdot 2^{17} + W_0) \cdot X = (W_1 X) \cdot 2^{17} + (W_0 X)$$

이 등식은 정수 산술상 항등식이며 $W_0, W_1, X$ 의 부호와 무관하게 성립한다.

### 2.2 비트 패턴 차원

DSP 가 실제로 받는 것은 정수값이 아니라 비트 패턴이다:

$$\text{A 포트 입력 비트 패턴} := \operatorname{repr}_{25}(A_{port})$$
$$\text{B 포트 입력 비트 패턴} := \operatorname{repr}_{18}(B_{port})$$

비트 패턴을 구체적으로 분해하면 (3.2 절에서 검증):

| 비트 영역 | 값 |
|:--|:--|
| $\operatorname{repr}_{25}(A_{port})[7:0]$ | $\operatorname{repr}_8(W_0)$ |
| $\operatorname{repr}_{25}(A_{port})[16:8]$ | 9비트 모두 $W_0$ 의 부호비트 (즉 $W_0 < 0$ 이면 1, 아니면 0) |
| $\operatorname{repr}_{25}(A_{port})[24:17]$ | $\operatorname{repr}_8(W_1 - [W_0 < 0])$ |

**핵심 주의**: 위 비트 분해는 단순 concatenation $\{W_1, W_0\}$ 이 아니다. $W_0 < 0$ 일 때 sign-extension 비트 (비트 [16:8]) 가 정수값에 $2^{17} - 2^8$ 만큼 기여하므로, 이를 상쇄하기 위해 상위 바이트에서 1 을 빼야 한다 (자세한 도출은 3.2 절).

### 2.3 예시: $W_1 = -100, W_0 = -14$ 일 때 $A_{port}$ 의 비트 패턴 생성

**목표**: $A_{port} = W_1 \cdot 2^{17} + W_0 = -100 \cdot 131072 + (-14) = -13{,}107{,}214$ 의 25-bit 2의 보수 비트 패턴.

**입력 비트 패턴**:
- $\operatorname{repr}_8(W_1) = \operatorname{repr}_8(-100) = \texttt{1001\_1100}$
- $\operatorname{repr}_8(W_0) = \operatorname{repr}_8(-14) = \texttt{1111\_0010}$

**단계 1**: $W_1 \cdot 2^{17}$ 의 25-bit 패턴 — $W_1$ 의 8-bit 패턴 뒤에 0 17개:
$$\texttt{1001_1100_0_0000_0000_0000_0000}$$

**단계 2**: $W_0$ 의 25-bit sign-extension — $W_0 < 0$ 이므로 비트 [24:8] 을 모두 1 로 채움:
$$\texttt{1_1111_1111_1111_1111_1111_0010}$$

**단계 3**: 두 값을 25-bit unsigned 덧셈 (overflow 무시):

```
W1 << 17        : 1001_1100_0_0000_0000_0000_0000
W0 sign-ext 25  : 1_1111_1111_1111_1111_1111_0010
                  ─────────────────────────────────
A_port (25-bit) : 1001_1011_1_1111_1111_1111_0010
```

**검증**: 결과의 상위 8비트는 $\texttt{1001\_1011} = \operatorname{repr}_8(-101) = \operatorname{repr}_8(W_1 - 1)$. 즉 $W_0 < 0$ 일 때 carry chain 이 자동으로 $W_1 \to W_1 - 1$ 보정을 처리.

이 비트 패턴을 $\operatorname{sint}_{25}$ 로 해석하면 $-13{,}107{,}214 = A_{port}$. ✓

### 2.4 DSP 곱셈의 동작

DSP48E1 의 25×18 signed multiplier 는 비트 패턴을 받아 다음을 계산:

$$P_{int} = \operatorname{sint}_{25}\!\left(\text{A 포트 비트 패턴}\right) \cdot \operatorname{sint}_{18}\!\left(\text{B 포트 비트 패턴}\right)$$

$P_{int}$ 는 43-bit signed 정수.

이상적으로는 $\operatorname{sint}_{25}(\operatorname{repr}_{25}(A_{port})) = A_{port}$ 이지만, **$A_{port}$ 가 25-bit signed 범위를 벗어나면 이 라운드트립이 깨진다** (3절).

---

## 3. 25-bit 범위와 오버플로우

### 3.1 $A_{port}$ 의 정수 범위

$A_{port} = W_1 \cdot 2^{17} + W_0$, $W_0, W_1 \in [-128, 127]$ 에서:

$$\min A_{port} = -128 \cdot 2^{17} + (-128) = -16{,}777{,}344$$
$$\max A_{port} = 127 \cdot 2^{17} + 127 = 16{,}646{,}271$$

25-bit signed 범위는 $[-2^{24}, 2^{24}-1] = [-16{,}777{,}216, 16{,}777{,}215]$.

| 조건 | $A_{port}$ 상태 |
|:--|:--:|
| $W_1 > -128$ | 항상 25-bit signed 범위 내 |
| $W_1 = -128, W_0 \ge 0$ | $A_{port} \in [-2^{24}, -2^{24}+127]$, 범위 내 |
| $W_1 = -128, W_0 < 0$ | $A_{port} \in [-2^{24}-128, -2^{24}-1]$, **범위 밖** (128 케이스) |

오버플로우는 음수 극단에서만 발생.

### 3.2 비트 패턴 분해의 도출

2.2 절의 비트 분해를 정수 등식으로 검증한다. $\operatorname{repr}_{25}(A_{port})$ 의 비트 슬라이스를 정수로 환산한 합:

$$\operatorname{repr}_{25}(A_{port}) = A_{port}[24:17] \cdot 2^{17} + A_{port}[16:8] \cdot 2^8 + A_{port}[7:0]$$

(좌변은 unsigned 정수, 우변도 unsigned 정수)

**$W_0 \ge 0$ 인 경우**:
- $A_{port}[7:0] = W_0$ (이미 unsigned 8-bit)
- $A_{port}[16:8] = 0$ (sign-ext 비트가 0)
- $A_{port}[24:17] = \operatorname{repr}_8(W_1)$

합: $\operatorname{repr}_8(W_1) \cdot 2^{17} + 0 + W_0$. $W_1 \ge 0$ 이면 $\operatorname{repr}_8(W_1) = W_1$, $\operatorname{sint}_{25}$ 적용 시 $W_1 \cdot 2^{17} + W_0 = A_{port}$. $W_1 < 0$ 이면 $\operatorname{repr}_8(W_1) = W_1 + 256$, 합은 $(W_1+256) \cdot 2^{17} + W_0$ 인데 $\operatorname{sint}_{25}$ 적용 시 $-2^{25}$ 만큼 빼지므로 $W_1 \cdot 2^{17} + W_0 = A_{port}$. 일관됨.

**$W_0 < 0$ 인 경우**:
- $A_{port}[7:0] = \operatorname{repr}_8(W_0) = W_0 + 256$
- $A_{port}[16:8] = \texttt{1\_1111\_1111}$ (9비트 모두 1) $= 2^9 - 1 = 511$
- $A_{port}[24:17] = ?$ (이 값을 찾는 게 목표)

$A_{port}$ 정의에 의해:

$$W_1 \cdot 2^{17} + W_0 = A_{port}[24:17] \cdot 2^{17} + 511 \cdot 2^8 + (W_0 + 256) \pmod{2^{25}}$$

(좌변을 $\operatorname{repr}_{25}$ 로 인코딩한 게 우변)

$511 \cdot 2^8 = 2^{17} - 2^8$ 이므로 우변의 중간/하위 항 합:
$$2^{17} - 2^8 + W_0 + 256 = 2^{17} + W_0$$

따라서:
$$W_1 \cdot 2^{17} + W_0 \equiv A_{port}[24:17] \cdot 2^{17} + 2^{17} + W_0 \pmod{2^{25}}$$
$$W_1 \cdot 2^{17} \equiv A_{port}[24:17] \cdot 2^{17} + 2^{17} \pmod{2^{25}}$$
$$A_{port}[24:17] \equiv W_1 - 1 \pmod{2^8}$$

즉 $A_{port}[24:17] = \operatorname{repr}_8(W_1 - 1)$. $W_0 < 0$ 일 때 상위 바이트에 -1 보정 필요.

두 경우 통합:
$$A_{port}[24:17] = \operatorname{repr}_8(W_1 - [W_0 < 0])$$

이것이 2.2 절 비트 분해의 도출. **이 -1 보정은 비트 표현 차원에서 sign-extension 의 정수 기여 ($2^{17} - 2^8$) 를 상쇄하는 것이지, 알고리즘의 핵심 보정 ($-256X$) 과는 다른 층위**다.

---

## 4. 핵심 통찰

오버플로우 시 ($W_1 = -128, W_0 < 0$) 라운드트립이 깨진다:

$$\operatorname{sint}_{25}(\operatorname{repr}_{25}(A_{port})) = A_{port} + 2^{25}$$

따라서 DSP 가 계산하는 정수값:

$$P_{int} = (A_{port} + 2^{25}) \cdot X = A_{port} \cdot X + 2^{25} X$$

오차항 $2^{25} X$ 가 추가된다.

**관찰 1**: $2^{25} X$ 는 $2^{17}$ 의 배수. 따라서 $P_{int} \bmod 2^{17}$ 에서 사라짐 → **$W_0 X$ 슬롯 (하위 17비트) 자동 보호**.

**관찰 2**: $P_{int}$ 의 비트 17 이상에서 오차항 $2^{25} X / 2^{17} = 256 X$ 가 더해진 형태로 나옴 → **$W_1 X$ 슬롯에 $-256 X$ 산술 보정**으로 복구.

오버플로우 검출:

$$\text{ovf} := [W_1 = -128 \wedge W_0 < 0]$$

알고리즘은 분기 없이 단일 경로로 보정을 합산.

---

## 5. 알고리즘

### 5.1 입력 단계

$$A_{port} = W_1 \cdot 2^{17} + W_0 \quad \text{(정수, 25-bit 비트 패턴으로 인코딩)}$$
$$B_{port} = X \quad \text{(정수, 18-bit signed extension)}$$

비트 패턴 생성은 2.2 절 분해에 따라 처리 (구현 디테일은 8.3절).

### 5.2 오버플로우 검출

$$\text{ovf} = [W_1 = -128 \wedge W_0 < 0]$$

### 5.3 DSP 곱셈

$$P_{int} = \operatorname{sint}_{25}(\operatorname{repr}_{25}(A_{port})) \cdot \operatorname{sint}_{18}(\operatorname{repr}_{18}(B_{port}))$$

### 5.4 결과 추출 (단일 경로)

$W_0 X$ 슬롯:

$$P_0 = W_0 X = \operatorname{sint}_{17}(P_{int} \bmod 2^{17})$$

$W_1 X$ 슬롯 (단일 식, 분기 없음):

$$P_1 = W_1 X = \operatorname{sint}_{16}\!\left(\lfloor P_{int} / 2^{17} \rfloor \bmod 2^{16}\right) + [P_0 < 0] - 256 X \cdot \text{ovf}$$

세 항 (DSP 상위 출력 / carry 보정 / overflow 보정) 을 16-bit ternary adder 로 합산.

---

## 6. 정확성 증명

### 6.1 보조정리

**Lemma 1 (모듈러 곱셈 보존)**. 정수 $a, b, n$ 에 대해 $(a \bmod 2^n) \cdot b \equiv a \cdot b \pmod{2^n}$.

**Lemma 2 (DSP 동작)**. DSP48E1 의 25×18 signed multiplier 는 비트 패턴 입력 $u \in [0, 2^{25})$, $v \in [0, 2^{18})$ 에 대해 $P_{int} = \operatorname{sint}_{25}(u) \cdot \operatorname{sint}_{18}(v)$ 를 계산.

### 6.2 정상 케이스 ($\text{ovf} = 0$)

$A_{port}$ 가 25-bit signed 범위 내이므로 라운드트립 성립:
$$\operatorname{sint}_{25}(\operatorname{repr}_{25}(A_{port})) = A_{port}$$

따라서:
$$P_{int} = A_{port} \cdot X = (W_1 X) \cdot 2^{17} + (W_0 X) \quad (\star)$$

**Claim A**: $P_0 = W_0 X$.

*증명.* $(\star)$ 에서 $(W_1 X) \cdot 2^{17}$ 은 $2^{17}$ 의 배수, $P_{int} \equiv W_0 X \pmod{2^{17}}$. $|W_0 X| \le 2^{14} < 2^{16}$ 이므로 17-bit signed 범위 내. 라운드트립으로 $\operatorname{sint}_{17}(W_0 X \bmod 2^{17}) = W_0 X$. $\square$

**Claim B**: $P_1 = W_1 X$.

*증명.* $(\star)$ 의 floor division:
$$\lfloor P_{int} / 2^{17} \rfloor = W_1 X + \lfloor W_0 X / 2^{17} \rfloor$$

$|W_0 X| < 2^{17}$ 에서:
- $W_0 X \ge 0$: $\lfloor W_0 X / 2^{17} \rfloor = 0$
- $W_0 X < 0$: $\lfloor W_0 X / 2^{17} \rfloor = -1$

통합: $\lfloor P_{int}/2^{17} \rfloor = W_1 X - [W_0 X < 0]$.

$|W_1 X - [W_0 X < 0]| \le 2^{14} + 1 < 2^{15}$, 16-bit signed 범위 내. 라운드트립 후 $[P_0 < 0]$ 더하고 $\text{ovf} = 0$ 이므로 $-256 X \cdot \text{ovf} = 0$. 결과: $W_1 X$. $\square$

### 6.3 오버플로우 케이스 ($\text{ovf} = 1$, 즉 $W_1 = -128, W_0 < 0$)

$A_{port} \in [-2^{24}-128, -2^{24}-1]$, 25-bit signed 범위 밖. 라운드트립:
$$\operatorname{sint}_{25}(\operatorname{repr}_{25}(A_{port})) = A_{port} + 2^{25}$$

따라서:
$$P_{int} = (A_{port} + 2^{25}) X = (W_1 X) \cdot 2^{17} + (W_0 X) + 2^{25} X \quad (\star\star)$$

**Claim A'**: $P_0 = W_0 X$.

*증명.* $2^{25} X \equiv 0 \pmod{2^{17}}$ 이므로 $(\star\star)$ 의 $\bmod\, 2^{17}$ 결과는 $(\star)$ 와 동일. Claim A 와 같은 논증. $\square$

**Claim B'**: $P_1 = W_1 X$.

*증명.* $(\star\star)$ 의 floor division:
$$\lfloor P_{int} / 2^{17} \rfloor = W_1 X + \lfloor W_0 X / 2^{17} \rfloor + 256 X$$

오버플로우 케이스에서 $W_0 < 0$ 이므로 $X \ge 0$ 이면 $W_0 X \le 0$, $X < 0$ 이면 $W_0 X \ge 0$. 어느 쪽이든 $|W_0 X| < 2^{17}$ 이므로 floor 처리:
$$\lfloor W_0 X / 2^{17} \rfloor = -[W_0 X < 0]$$

통합: $\lfloor P_{int}/2^{17} \rfloor = W_1 X + 256 X - [W_0 X < 0]$.

$W_1 = -128$ 이므로 $W_1 X + 256 X = X \cdot (W_1 + 256) = X \cdot 128$. $|X \cdot 128 - [W_0 X < 0]| \le 128 \cdot 128 + 1 < 2^{15}$, 16-bit signed 범위 내. 라운드트립 후 $[P_0 < 0]$ 더하고 $-256 X \cdot 1$ 빼면 $W_1 X$ 복원. $\square$

### 6.4 통합

알고리즘의 식은 두 케이스 모두에서 정확. 모든 $(W_0, W_1, X) \in [-128, 127]^3$ 에 대해 $P_0 = W_0 X, P_1 = W_1 X$. $\blacksquare$

---

## 7. 정확성 검증 (수치 실험)

전체 $2^{24} = 16{,}777{,}216$ 조합 Python 시뮬레이션, 0 오류.

---

## 8. 하드웨어 구현 시 주의사항

### 8.1 자원 비용 추정

| 항목 | 비용 | 비고 |
|:--|:--:|:--|
| DSP48E1 | 1개 | 두 곱셈 packing |
| $A_{port}$ 비트 패턴 생성 (런타임 weight) | ~8 LUT | 8.3절 |
| 오버플로우 검출 (런타임 weight) | ~2 LUT | $W_1 = -128 \wedge W_0[7]$ |
| 오버플로우 검출 (pre-packed) | ~4 LUT | 8.3절 |
| 보정항 마스킹 ($-256 X \cdot \text{ovf}$) | ~8 LUT | upper 8-bit AND |
| 16-bit ternary adder | ~16–32 LUT | LUT6_2 활용 시 ~16, 일반 ~30 |
| **추출 단 총합 (pre-packed)** | **~30–45 LUT** | |

### 8.2 Critical path

단일 경로, 분기/MUX 없음:
$$\text{DSP output} \to \text{ternary adder (carry chain)} \to \text{output}$$

DSP 와 외부 logic 간 latency 정렬 불필요. Critical path 깊이는 DSP 출력 후 1-level LUT + carry chain.

### 8.3 비트 패턴 생성 및 오버플로우 검출 (Pre-packed 시나리오)

**런타임 비트 패턴 생성**: 2.2 절 비트 분해를 그대로 구현.
- $\operatorname{repr}_{25}(A_{port})[7:0] = \operatorname{repr}_8(W_0)$ (wire)
- $\operatorname{repr}_{25}(A_{port})[16:8] = \{9 \times W_0[7]\}$ (wire, sign-extension)
- $\operatorname{repr}_{25}(A_{port})[24:17] = \operatorname{repr}_8(W_1 - [W_0 < 0])$ (8-bit 조건부 가감산)

런타임 약 8 LUT.

**Pre-packed weight 시나리오 (오프라인)**: 호스트에서 $\operatorname{repr}_{25}(A_{port})$ 를 미리 계산해 25-bit 형태로 메모리에 저장. 이 경우 오버플로우 검출은 비트 패턴으로:

검증된 시그니처: $\text{ovf} = [\operatorname{repr}_{25}(A_{port})[24:17] = \texttt{0x7F}] \wedge \operatorname{repr}_{25}(A_{port})[16]$

이 시그니처는 오버플로우 케이스 128 개 ($W_1 = -128 \wedge W_0 < 0$) 와 정확히 일치하며 다른 케이스에서는 발생하지 않음. 비용 ~4 LUT.

### 8.4 보정항 $-256 X$ 의 구현

$-256 X$ 는 $X$ 의 9-bit 부호 반전 결과를 8-bit 왼쪽으로 옮긴 형태. 마스킹 후 ~8–10 LUT.

---

## 9. 학계 대비 위치

| 비교 | 본 알고리즘 | Xilinx WP486 |
|:--|:--:|:--:|
| 대상 device | Artix-7 (DSP48E1, 25-bit) | UltraScale+ (DSP48E2, 27-bit) |
| Shift 양 | 17-bit | 18-bit |
| -128 처리 방식 | 산술 보정 ($-256 X$) | 비트 폭 마진으로 회피 |
| 데이터 경로 | 단일 (분기 없음) | 단일 |
| 추가 logic (추출 단) | ~30–45 LUT | 0 |

WP486 의 SIMD packing 원리를 DSP48E1 의 좁은 비트 폭으로 확장. -128 오버플로우의 산술 보정이 본 알고리즘의 독자적 기여.

---

## 10. 핵심 통찰

1. **정수값과 비트 패턴의 분리**: $A_{port}$ 의 정수값과 그 25-bit 비트 패턴은 라운드트립으로 연결되지만 $A_{port}$ 가 범위를 벗어나면 분리됨. 이 분리가 오버플로우의 본질.

2. **모듈러 산술의 우연**: 오버플로우 오차 $2^{25} X$ 가 $2^{17}$ 의 배수. $W_0 X$ 슬롯 자동 보호.

3. **산술적 보정의 우아함**: 오버플로우 시 $W_1 X$ 슬롯에 더해지는 $256 X$ 가 정확히 알 수 있는 값이므로 분기 없이 합산 단계에서 빼면 됨. MUX 없는 단일 경로.