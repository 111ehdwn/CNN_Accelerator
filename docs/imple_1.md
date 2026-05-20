# 2. Conv2 엔진 동작을 사이클 단위로 완전 분해

## 2-1. 변수 정의

```
입력 FMAP1 (Conv1 출력):  shape (C_in=8, H_in=26, W_in=26), INT8
출력 FMAP2 (Conv2 출력):  shape (C_out=16, H_out=24, W_out=24), INT8 (saturated)
Weight Conv2:             shape (C_out=16, C_in=8, K=3, K=3), INT8
```

수학적으로 Conv2가 계산하는 것:
```
for oc in 0..15:
  for oy in 0..23:
    for ox in 0..23:
      psum = 0
      for ic in 0..7:
        for ky in 0..2:
          for kx in 0..2:
            psum += in[ic][oy+ky][ox+kx] * w[oc][ic][ky][kx]
      out[oc][oy][ox] = sat( ReLU( (psum >>> 10) ) )  // bit truncate + ReLU + saturate
```

→ 6중 루프. **각 루프를 공간(병렬)에 펼칠지, 시간(직렬)에 펼칠지가 dataflow 결정의 본질**.

## 2-2. 우리 베이스라인의 펼침 결정

| 루프 변수 | 범위 | 어디로 펼침? | 이유 |
|---|---|---|---|
| `oy` | 24 | **시간 (raster scan)** | 한 줄씩 처리. line buffer로 자연 처리 |
| `ox` | 24 | **시간 (raster scan)** | 같은 이유 |
| `oc` | 16 | **공간 8 + 시간 fold 2** | C_out 8개를 한꺼번에 (psum 레지스터 8개 stationary) |
| `ic` | 8 | **공간 2 (SIMD) + 시간 fold 4** | C_in 2-way SIMD |
| `ky` | 3 | **공간 (3 펼침)** | 3×3 모두 펼침 |
| `kx` | 3 | **공간 (3 펼침)** | 같이 펼침 |

곱셈기 수 = 공간 펼침 차원의 곱 = **oc_par × ic_par × K × K = 8 × 2 × 3 × 3 = 144 DSP** ✅

## 2-3. 사이클별 동작 (oc 그룹 = 0~7, oy=0, ox=0 의 첫 출력 8개를 만드는 4 cycle)

> 가정: line buffer 워밍업이 끝났고, window register에 (ic=0~7) × (3×3) = 72개의 픽셀이 모두 준비됨.
> → 실제로는 채널별로 line buffer가 따로 있어야 함. 이건 2-4에서 다룸.

```
[Cycle 0]  C_in 그룹 = {0, 1}
─────────────────────────────────────────────────────────────
  활성화 source: window[ic=0][3x3]  +  window[ic=1][3x3]  = 18 INT8
  weight source: W[oc=0..7, ic=0..1, 3x3]                 = 144 INT8
                 (BRAM에서 144 byte 읽기 = 36 word @ 32bit, 또는 더 wide BRAM)
  
  144개 DSP가 동시에 INT8×INT8 계산:
    각 DSP (oc, ic, ky, kx):  product = window[ic][ky][kx] * W[oc][ic][ky][kx]
  
  Adder Tree (oc별로 18개 product를 합산, 즉 ic 2개 × 3×3 = 18):
    for oc in 0..7:
      partial[oc] = Σ product[oc][ic=0,1][ky=0..2][kx=0..2]    (18-input adder tree)
  
  Accumulator (Output Stationary!):
    for oc in 0..7:
      psum_reg[oc] <= psum_reg[oc] + partial[oc]
  
  → 이 시점에서 psum_reg[oc]는 ic 그룹 1개 (= ic 0,1 합산) 만 반영됨


[Cycle 1]  C_in 그룹 = {2, 3}
─────────────────────────────────────────────────────────────
  활성화: window[ic=2][3x3]  +  window[ic=3][3x3]
  weight: W[oc=0..7, ic=2..3, 3x3]      (다음 144 byte)
  
  144 DSP 동작 동일.
  psum_reg[oc] += partial[oc]    (ic 2,3 추가 누적)


[Cycle 2]  C_in 그룹 = {4, 5}
─────────────────────────────────────────────────────────────
  동일. psum_reg[oc] += ic 4,5 의 기여


[Cycle 3]  C_in 그룹 = {6, 7}
─────────────────────────────────────────────────────────────
  동일. psum_reg[oc] += ic 6,7 의 기여
  
  → 4 cycle 끝 시점에서 psum_reg[oc=0..7]은 출력 위치 (oy=0, ox=0)의
    oc 0~7 채널 8개의 "완성된" partial sum.
  
  → 이제 quantize: q_out[oc] = sat( ReLU( psum_reg[oc] >>> 10 ) )
  → FMEM_B에 8개 INT8을 write
  → psum_reg <= 0 (다음 출력 위치를 위해 리셋)
  → (oy=0, ox=1)로 이동, 다시 4 cycle
```

→ **이게 Output Stationary 의 정확한 정의**:
- psum이 4 cycle 동안 같은 레지스터에 머무름 (= stationary)
- weight는 매 cycle 새로 broadcast (다른 ic 그룹)
- activation도 같은 위치 (oy=0, ox=0)의 다른 ic 채널 데이터를 사용

## 2-4. 그런데 "window register"가 채널 8개를 어떻게 동시에 가지고 있지?

이게 베이스라인 설계에서 **가장 까다로운 부분**이야. 신중하게 보자.

### Sobel의 단순한 경우
- C_in=1이라 line buffer가 채널 1개분 = 2개의 line buffer + 9 window FF
- 한 cycle에 BRAM에서 1 byte 읽기 → 자동으로 window가 1칸 shift

### Conv2의 경우 (C_in=8)
- 출력 1점이 ic=0..7 모두를 봐야 함
- 하지만 우리는 C_in을 **2-way SIMD + 시간 fold 4번**으로 펼침
- → 한 cycle에 동시에 필요한 activation은 **2채널분의 3×3 = 18개 픽셀**
- → 즉 cycle 0,1,2,3 각각에서 다른 ic 그룹의 18개 픽셀이 필요

**선택지 A: 8채널 모두 line buffer 가지기** (병렬 access)
- line buffer 인스턴스: 8 channel × 2 lines = **16개**
- window FF: 8 channel × 9 = **72 FF (×8bit = 576bit register)**
- BRAM 폭 넓혀서 한 cycle에 8 byte (한 위치의 8채널) 동시 읽기
- 장점: cycle 0~3 모두 같은 window register에서 ic만 골라 쓰면 됨
- 단점: BRAM 폭 8byte + line buffer 16개

**선택지 B: ic 그룹마다 fmap 재-스캔** (시간 access)
- line buffer는 ic 그룹마다 다시 채움. cycle 마다 BRAM에서 다른 ic의 데이터 읽기
- BRAM은 1 byte 폭이면 충분하지만, **출력 한 점마다 fmap을 4번 스캔해야 함**
- → 너무 느림. 베이스라인이라도 비추.

**선택지 C: 한 줄(row) 단위 처리, ic는 OS 누적** ✅
- 한 row (oy 고정, ox=0..23) 처리하는 동안 **psum buffer**를 OMEM 영역에 row 전체분 (24 × 8 = 192개) 잡아둠
- 1 pass: ic=0,1 로 row 전체의 partial sum 계산 → buffer에 저장
- 2 pass: ic=2,3 로 row 전체 += buffer
- 3 pass: ic=4,5 로 row 전체 += buffer
- 4 pass: ic=6,7 로 row 전체 += buffer → quantize → FMEM_B write
- BRAM 폭: 2 byte (ic 그룹 = 2개)
- line buffer: 2 channel × 2 lines = 4개
- → **하지만 이러면 psum이 buffer에 있고 매번 read/write 발생 → OS가 아니라 weight stationary 색채**

> **결론**: 선택지 A가 진짜 OS 베이스라인. BRAM 폭을 8byte = 64bit로 늘리는 게 핵심.

### FMEM_A (Conv1 출력 저장소) 구조 결정

→ **FMEM_A의 BRAM 폭을 64bit (8 byte = 8 channel 동시)** 로 설계해야 함.
- FMAP1: 8 × 26 × 26 = 5,408 byte = 676 × 8byte word
- BRAM 구성: width 64bit, depth 676
- 36Kb BRAM은 36864 bit / 64bit = 576 word → 부족! 2개 BRAM 묶어서 1024 word (한 BRAM은 18Kb로 분할 가능)
- 또는 width 32bit (ic 4개) × 2-bank → cycle당 ic 4개씩 → 18 DSP 그룹으로 압축
- → **2번째 안이 더 자원 효율적일 수도**. 다만 cycle 수 늘어남

이 부분은 실제 BRAM 자원 보고 결정해야 해. 일단 **개념적으로 BRAM 폭 = ic_par × C_in_per_word**.

## 2-5. 사이클 카운트 정확히 다시

```
한 출력 위치당:        4 cycle (C_in fold)
한 출력 row (24개):    24 × 4 = 96 cycle  
출력 24 row × C_out 2 fold:  24 × 96 × 2 = 4,608 cycle
+ line buffer warm-