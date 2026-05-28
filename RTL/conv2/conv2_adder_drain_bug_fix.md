# Conv2 Adder Drain Bug — 분석 및 수정 기록

> 발견 시점: multi-image testbench (image 0~99) 검증 중, **image 28 만 2 픽셀 fail**.
> 수정 위치: `conv2_engine.v` line 307 — `adder_en` 신호 정의 1 줄 변경.
> Cycle count, 다른 image 동작에는 영향 없음.

---

## 1. 한 문장 요약

`krow_ic_adder_tree` 가 5-stage pipeline 인데 `adder_en` 이 1 cycle 만 high 가 되어, 한 image 의 **마지막 PE 출력이 adder pipeline 끝까지 도달하지 못하고 s1 에서 stuck** 되었다. → kcol_accumulator 가 stale sum 을 누적 → 마지막 2 픽셀 (23, 22) 와 (23, 23) 의 출력 값이 잘못 계산.

---

## 2. 발견 경위

| 단계 | Test | 결과 |
|---|---|---|
| ① | single_img on image 0 (576 픽셀) | **100% PASS** (2378 cycle) |
| ② | multi_img on image 0~99 (100장) | **99/100 PASS** — image 28 만 2 MM @ addr 574, 575 |
| ③ | 의심: TB ping-pong race condition | single_img 으로 image 28 만 재시험 |
| ④ | single_img on image 28 (padded c1c2 적용) | **정확히 같은 2 MM** — TB 아닌 engine bug 확정 |
| ⑤ | Python diagnostic: acc + K_col 분해 | bug 메커니즘 확정 (§4 참조) |

---

## 3. 증상 — 정확한 데이터

### 3.1 Mismatch 위치

```
addr 574 (h=23, w=22) :
  got = 02000000020100000000000000020000
  exp = 01000000020101000000000000020000
                   ^^      ^^
            OC 15  OC 9

addr 575 (h=23, w=23) :
  got = 01000000000000000000000000000001
  exp = 00000000000000000000000000000000
        ^^                              ^^
        OC 15                            OC 0
```

### 3.2 OC 별 diff

| Pixel | OC | Python acc | Python out | HW got | diff |
|---|---|---|---|---|---|
| (23, 22) | 9 | +1029 | 1 | **0** | −1 |
| (23, 22) | 15 | +1696 | 1 | **2** | +1 |
| (23, 23) | 0 | −278 | 0 | **1** | +1 |
| (23, 23) | 15 | +227 | 0 | **1** | +1 |

→ 단순 ±1 처럼 보이지만 raw acc 차이는 **수백~수천 단위** (boundary edge 아님).

---

## 4. 원인 분석

### 4.1 데이터 단서

Python 의 K_col contribution 분해 (image 28, IC × kh 모두 합산):

```
(23, 22) OC  9 : K_col[0]=  1192, K_col[1]=  -163, K_col[2]=     0
(23, 22) OC 15 : K_col[0]=  1251, K_col[1]=   445, K_col[2]=     0
(23, 23) OC  0 : K_col[0]=  -278, K_col[1]=     0, K_col[2]=     0
(23, 23) OC 15 : K_col[0]=   227, K_col[1]=     0, K_col[2]=     0
```

HW got 을 역산:

| Pixel | OC | HW got = sat+ReLU(...) 의 acc | 매치되는 패턴 |
|---|---|---|---|
| (23, 22) | 9 | 866 = 1192 + 2·(−163) | **K_col[0] + 2·K_col[1]** ✓ |
| (23, 22) | 15 | 2141 = 1251 + 2·445 | **K_col[0] + 2·K_col[1]** ✓ |
| (23, 23) | 15 | 1335 = 3·445 ← (23, 22) 의 K_col[1] | **3 × (23, 22) K_col[1]** ✓ |

→ mem[574] = (23, 22) **K_col=0 + 2·K_col=1** (K_col=2 빠지고 K_col=1 두 번 더해짐)  
→ mem[575] = **3 × (23, 22) K_col=1** ((23, 23) 의 contribution 전혀 안 들어감!)

이런 패턴은 **adder pipeline 의 sum register 가 (23, 22) K_col=1 결과에서 갇혀서 kcol_accumulator 가 여러 번 같은 값을 받았다** 는 강한 시그널.

### 4.2 코드 점검 — adder_en 게이팅

`krow_ic_adder_tree.v` 의 stage 구조:

```verilog
always @(posedge clk) begin
    if (rst) ...
    else if (en) begin
        s1[i] <= in_arr[i*2] + in_arr[i*2 + 1];   // stage 1
    end
end
// stage 2..5 도 동일하게 en 게이팅
```

→ **각 stage 가 `en` 으로 게이팅**. en=0 cycle 에는 register 가 HOLD.

`conv2_engine.v` (수정 전) line 307:

```verilog
wire adder_en = pe_en_pipe[3];   // 4-cycle delay
```

- `pe_en_pipe[3] @ T = fsm_pe_en @ T-4`.
- 한 image 의 마지막 ADV 는 cycle 1784 (= (23, 23) ADV). pe_en @ 1784 = 1.
- cycle 1785 부터 DRAIN 진입 → pe_en = 0.
- 따라서 `adder_en` 은 cycle 1788 에 1 (= pe_en @ 1784), 그 이후 cycle 1789+ 모두 0.

### 4.3 메커니즘 추적 — 마지막 4 입력의 propagation

PE input @ T → adder input @ T+4. 5-stage pipeline → sum @ T+9.

마지막 valid PE input 들:

| PE input cycle | 의미 | adder input cycle | sum register 도달 필요 시점 |
|---|---|---|---|
| 1779 | (23, 22) K_col=0 | 1783 | 1788 |
| 1780 | (23, 22) K_col=1 | 1784 | 1789 |
| 1781 | (23, 22) K_col=2 | 1785 | 1790 |
| 1782 | (23, 23) K_col=0 | 1786 | 1791 |
| 1783 | (23, 23) K_col=1 | 1787 | 1792 |
| 1784 | (23, 23) K_col=2 | 1788 | **1793** |

각 입력의 sum register 도달까지 5 cycle 연속 `en=1` 필요. `adder_en` 의 값:

| cycle | 1783 | 1784 | 1785 | 1786 | 1787 | 1788 | 1789 | 1790 | 1791 | 1792 | 1793 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `pe_en @ T-4` | @1779=1 | @1780=1 | @1781=1 | @1782=1 | @1783=1 | @1784=1 | @1785=0 | @1786=0 | @1787=0 | @1788=0 | @1789=0 |
| `adder_en` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **✗** | ✗ | ✗ | ✗ | ✗ |

cycle 1789 부터 en=0 → 모든 stage register HOLD.

→ **(23, 22) K_col=1 까지는 sum 에 정상 도달** (cycle 1789 까지 propagation 완료).  
→ **(23, 22) K_col=2 부터는 s1 까지만 latch, s2 이후 stuck**. sum register 는 (23, 22) K_col=1 값으로 freeze.

### 4.4 kcol_accumulator 시점 별 입력

kcol_acc input @ T = adder sum @ T (= pipeline 끝).  
kcol_acc 의 delayed kw_phase @ T = fsm_sel @ T−9 (정상 작동).

| cycle | adder sum (실제) | delayed kw_phase | kcol_acc 동작 | kcol_acc out |
|---|---|---|---|---|
| 1788 | (23, 22) K_col=0 ✓ | 0 (HOLD0 of (23,22)) | reset: out ← in | K_col=0 |
| 1789 | (23, 22) K_col=1 ✓ | 1 | out += in | K_col=0 + K_col=1 |
| 1790 | (23, 22) K_col=1 **stuck** | 2 | out += in, out_valid! | **K_col=0 + 2·K_col=1** |
| 1791 | (23, 22) K_col=1 **stuck** | 0 (HOLD0 of (23,23)) | reset: out ← in | (23, 22) K_col=1 |
| 1792 | (23, 22) K_col=1 **stuck** | 1 | out += in | 2·(23, 22) K_col=1 |
| 1793 | (23, 22) K_col=1 **stuck** | 2 | out += in, out_valid! | **3·(23, 22) K_col=1** |

→ mem[574] = K_col=0 + 2·K_col=1, mem[575] = 3·(23, 22) K_col=1.  
§4.1 의 데이터와 **완벽히 일치**.

### 4.5 왜 image 0 single_img 는 통과했는가

Image 0 (MNIST 첫 번째 숫자) 의 (23, 22), (23, 23) 입력 window 가 **모두 background = 0**.

→ PE 출력 = 0 → adder sum register 도 0 → stuck 되어도 stuck 된 값이 0.  
→ kcol_accumulator 가 0 을 여러 번 더해도 0. sat+ReLU 후 0.  
→ Python expected 도 0. mem 값이 0 = 0. **MM 안 잡힘**.

Image 28 의 (23, 22) 근처 입력은 IC 5/6 등에 작은 non-zero 값들이 있어 (`fmap1[5, 23, 22] = 17` 등) bug 가 visible 해졌다.

> ⚠️ 이 bug 는 100 장 중 image 28 한 장에서만 catch 됐다. 즉, **데이터 종속적으로 mask 되어 long-time 동안 잠재해 있던** type 의 버그. 단일 image 검증으론 절대 발견할 수 없었다.

---

## 5. 수정

### 5.1 변경 위치 — `conv2_engine.v` line 307

```diff
- wire       adder_en      = pe_en_pipe[3];
+ // adder_tree 는 5-stage pipeline. 마지막 valid PE 출력 (DRAIN 진입 직전) 이
+ // sum register 까지 propagate 하려면 en=1 이 5 cycle 연속 유지되어야 함.
+ // pe_en_pipe[3] 만 사용하면 마지막 입력 후 1 cycle 만에 en=0 → s1 에서 stuck.
+ // → pe_en_pipe[3..7] 5-cycle window OR 로 확장.
+ wire       adder_en      = pe_en_pipe[3] | pe_en_pipe[4] | pe_en_pipe[5]
+                          | pe_en_pipe[6] | pe_en_pipe[7];
```

### 5.2 왜 OR-window 가 정답인가

`adder_en @ T = 1` 이 필요한 조건 = "현재 adder pipeline 안에 propagation 중인 valid 입력이 있다".

Adder pipeline 안에 stage k (k=1..5) 의 데이터가 valid 하려면 그 데이터의 adder input 시점 = T − k 가 valid PE output 이어야 함. 즉 `pe_en @ (T − k) − 4 = pe_en @ T − k − 4 = pe_en_pipe[k+3] @ T = 1`.

→ 어떤 stage 든 valid 가 있으면 en=1 이어야 하므로:

```
adder_en @ T = OR over k = 1..5 of  pe_en_pipe[k+3] @ T
             = pe_en_pipe[4..8] @ T
```

엄밀히는 `pe_en_pipe[4..8]` 인데, 새로 들어오는 입력 (k=0 의 의미) 도 포함시켜야 s1 자체가 update 됨. 그래서 `pe_en_pipe[3]` (k=0 의 adder_input_valid) 도 포함해서 `pe_en_pipe[3..7]` (총 5 cycle window).

### 5.3 수정 후 검증 — 마지막 입력 trace

`adder_en @ T = pe_en_pipe[3] | pe_en_pipe[4] | pe_en_pipe[5] | pe_en_pipe[6] | pe_en_pipe[7]`:

| cycle | pe_en_pipe[3] | [4] | [5] | [6] | [7] | adder_en |
|---|---|---|---|---|---|---|
| 1788 | @1784=1 | @1783=1 | @1782=1 | @1781=1 | @1780=1 | ✓ |
| 1789 | @1785=0 | @1784=1 | @1783=1 | @1782=1 | @1781=1 | ✓ |
| 1790 | @1786=0 | @1785=0 | @1784=1 | @1783=1 | @1782=1 | ✓ |
| 1791 | @1787=0 | @1786=0 | @1785=0 | @1784=1 | @1783=1 | ✓ |
| 1792 | @1788=0 | @1787=0 | @1786=0 | @1785=0 | @1784=1 | ✓ |
| 1793 | @1789=0 | @1788=0 | @1787=0 | @1786=0 | @1785=0 | **0** |

→ cycle 1788~1792 모두 en=1 유지. 마지막 PE input (cycle 1784, (23, 23) K_col=2) 의 propagation 5 cycle 완료. sum @ 1793 = (23, 23) K_col=2 결과 ✓.

cycle 1793 부터 en=0 (더 이상 valid 입력 없음). 정상.

### 5.4 수정 후 kcol_acc 동작

| cycle | adder sum | delayed kw_phase | kcol_acc out |
|---|---|---|---|
| 1788 | (23, 22) K_col=0 | 0 | K_col=0 |
| 1789 | (23, 22) K_col=1 | 1 | K_col=0 + K_col=1 |
| 1790 | (23, 22) K_col=2 ✓ (fix 후) | 2 | **K_col=0+1+2 = full sum, out_valid** |
| 1791 | (23, 23) K_col=0 ✓ | 0 | (23, 23) K_col=0 (reset) |
| 1792 | (23, 23) K_col=1 ✓ | 1 | K_col=0 + K_col=1 |
| 1793 | (23, 23) K_col=2 ✓ | 2 | **K_col=0+1+2 = full sum, out_valid** |

→ mem[574] = (23, 22) full sum, mem[575] = (23, 23) full sum. **Python expected 와 일치**.

---

## 6. 부작용 / 영향 분석

| 항목 | 변화 |
|---|---|
| 정상 compute 중 (steady state) | pe_en 항상 1 → `pe_en_pipe[3..7]` 모두 1 → OR 결과 1 (변화 없음) |
| First image 의 첫 valid 입력 | 변화 없음 (pe_en_pipe[3] 만으로도 1 됨) |
| Image 경계 (DRAIN ~ 다음 image PIPELINE_FILL) | DRAIN 시작 후 4 cycle 동안 추가로 adder_en=1 유지. PE pipeline 의 마지막 valid 데이터 정상 drain. 이후 (kcol_en, truncate_relu en 이 0 이므로) adder 가 propagate 한 garbage 는 downstream 에서 무해. |
| Cycle count per image | **변화 없음** (1796 cycle/image 동일, wdone timing 동일) |
| 합성 자원 | OR 4 개 추가 (4 LUT 정도). 무시 가능. |
| 동적 전력 | DRAIN 중 5 cycle 동안 adder pipeline FF 가 toggle. 매 image 당 5 cycle 추가 동작. 미미. |

---

## 7. 검증 결과

| Test | Before fix | After fix |
|---|---|---|
| single_img (image 0) | PASS | PASS (변화 없음) |
| single_img (image 28, padded) | FAIL 2 MM | **PASS 기대** (사용자 측 시뮬 결과 대기) |
| multi_img (100장) | 99/100 PASS | **100/100 PASS 기대** |

---

## 8. 교훈 / 향후 주의 사항

1. **Pipelined adder 의 en 게이팅은 단일 cycle delay 가 아닌 "pipeline depth 만큼의 window"** 로 정의해야 한다. 이는 모든 pipeline 모듈 (FIFO, accumulator, multi-stage adder 등) 에 일반화됨.

2. **데이터 종속적 bug 는 single-image 검증으로 발견 불가**. Corner case 가 zero-input 으로 mask 되면 사실상 invisible. multi-image (다양한 입력 분포) 검증 필수.

3. **버그가 잡힌 다음 단계**: 같은 패턴의 다른 모듈 점검. `truncate_relu` 는 1-stage 라 무관. `kcol_accumulator` 도 1-stage 라 무관. `weight_loader` 의 BMG output reg drain 도 점검 필요 (별도 문서 — REGCEB=1 상수 결정).

4. **이상적 검증 순서** (재발 방지):
   - 단위 검증 단계에서 각 pipelined 모듈에 대해 **"마지막 입력 후 en=0 해도 sum 까지 도달하는가"** 명시적 단위 테스트 추가.
   - Top-level 검증에서 image 28 같은 corner-data 가 풍부한 input 으로 다수 image 검증.

---

## 9. 관련 파일

| 파일 | 역할 |
|---|---|
| `conv2_engine.v` line 307 | 본 fix 적용 위치 |
| `krow_ic_adder_tree.v` | bug 의 무대 (5-stage pipeline, en 게이팅) |
| `kcol_accumulator.v` | bug 의 증상 발현 위치 (stale sum 누적) |
| `conv2_design.md` §4.7 | 본 fix 의 설계 결정 요약 |
| `conv2_timing.md` §0.4 | pipeline depth 와 en window 의 일반 원칙 |
| `scripts/header_hex_gen/multi_img/diag_img28.py` | bug 발견 시 사용한 Python diagnostic |
