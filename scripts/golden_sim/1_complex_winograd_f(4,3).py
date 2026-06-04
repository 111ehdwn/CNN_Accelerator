"""
1_complex_winograd_f(4,3).py
============================

시나리오 #2: **복소수 Winograd F(4×4, 3×3)** 로 Conv2 를 계산하는 golden reference.
설계 배경: `docs/winograd/algorithm_complex_f43.md` (점집합 {0,±1,±i,∞}, Gaussian-integer 변환).

──────────────────────────────────────────────────────────────────────────────
★ 문서 행렬 정정 (이 golden 으로 발견, 2026-06-04)
──────────────────────────────────────────────────────────────────────────────
문서 §4 의 A'ᵀ/Bᵀ 는 **다항식 곱(product) 구성** (Vandermonde Bᵀ + Lagrange A'ᵀ) 인데,
CNN 의 correlation `y_n = Σ_k g_k·d_{n+k}` 은 **convolution(transpose) 구성** 이 필요하다.
문서 행렬 그대로는 direct conv 과 45~54% 만 일치(bit-exact 실패) — 이 스크립트가 검출.

정정(수치 유도 + 검증, err 5e-16, 모든 trial bit-exact):
  · G  (필터, 6×3)  : 평가 Vandermonde {0,±1,±i}      ← 문서와 동일
  · Bᵀ (입력, 6×6) : ×4 보간 {0,±1,±i,±4}             ← ¼ 스케일이 여기(입력)에 있음
  · Aᵀ (출력, 4×6) : 평가 Vandermonde {0,±1,±i}        ← ×4 없음 (문서는 반대로 배치했음)
즉 문서가 A 와 B 의 역할(스케일 위치)을 뒤바꿔 놓았다. 곱셈수 46·shift >>14 결론은 동일.

알고리즘 (정정판):
  U   = G·g·Gᵀ        (6×6 complex 정수, weight 사전계산; G 정수 → 반올림 없음)
  V   = Bᵀ·d·B        (6×6 complex 정수; Bᵀ=4·(true) → V = 16·V_true)
  M   = Σ_IC U ⊙ V    (6×6 complex)
  Y16 = Aᵀ·M·A        (4×4; = 16·Y_true, imag 은 정확히 0)
  out = saturate(Y16 >> 14) = saturate(16·Y >> 14) = saturate(Y >> 10)  ← direct 와 동일값

검증 항목: (A) Winograd==Direct conv2 bit-exact, (B) 전체 logit==output.npy,
          (C) Y16 ÷16 & imag==0 자기검증, (D) 곱셈 46 vs 144(3.13×).
정수 정확도: 복소수를 (re,im) int64 쌍으로 직접 연산(float 미사용) → 비트 단위 명확.

실행: `python "1_complex_winograd_f(4,3).py"`            (전체 10000)
      `WINO_N=500 python "1_complex_winograd_f(4,3).py"`  (앞 500, 빠른 검증)
"""

from __future__ import annotations

import os
import sys
import time
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reference_core as rc


# =============================================================================
# 0.  변환 행렬 (Gaussian integer, real/imag int64 쌍) — ★정정판
# =============================================================================
#  점집합 {0, 1, -1, i, -i, ∞}. 복소수 = (re, im) 두 int64 배열 → 정수 연산 bit-exact.

# G (6×3) : 필터 평가 Vandermonde.  G[k,j] = p_k^j.  원소 {0, ±1, ±i}
G_RE = np.array([[1, 0, 0],
                 [1, 1, 1],
                 [1,-1, 1],
                 [1, 0,-1],
                 [1, 0,-1],
                 [0, 0, 1]], dtype=np.int64)
G_IM = np.array([[0, 0, 0],
                 [0, 0, 0],
                 [0, 0, 0],
                 [0, 1, 0],
                 [0,-1, 0],
                 [0, 0, 0]], dtype=np.int64)

# Bᵀ (6×6) : 입력 변환(보간) ×4.  원소 {0, ±1, ±i, ±4}  (¼ 스케일 흡수 → V=16·V_true)
BT_RE = np.array([[ 4, 0, 0, 0,-4, 0],
                  [ 0, 1, 1, 1, 1, 0],
                  [ 0,-1, 1,-1, 1, 0],
                  [ 0, 0,-1, 0, 1, 0],
                  [ 0, 0,-1, 0, 1, 0],
                  [ 0,-4, 0, 0, 0, 4]], dtype=np.int64)
BT_IM = np.array([[ 0, 0, 0, 0, 0, 0],
                  [ 0, 0, 0, 0, 0, 0],
                  [ 0, 0, 0, 0, 0, 0],
                  [ 0,-1, 0, 1, 0, 0],
                  [ 0, 1, 0,-1, 0, 0],
                  [ 0, 0, 0, 0, 0, 0]], dtype=np.int64)

# Aᵀ (4×6) : 출력 평가 Vandermonde.  Aᵀ[i,k] = p_k^i.  원소 {0, ±1, ±i}  (스케일 없음)
AT_RE = np.array([[1, 1, 1, 1, 1, 0],
                  [0, 1,-1, 0, 0, 0],
                  [0, 1, 1,-1,-1, 0],
                  [0, 1,-1, 0, 0, 1]], dtype=np.int64)
AT_IM = np.array([[0, 0, 0, 0, 0, 0],
                  [0, 0, 0, 1,-1, 0],
                  [0, 0, 0, 0, 0, 0],
                  [0, 0, 0,-1, 1, 0]], dtype=np.int64)

# 우측 곱 행렬 (transpose).  Gᵀ(3×6), B=(Bᵀ)ᵀ(6×6), A=(Aᵀ)ᵀ(6×4).
GT_RE, GT_IM = G_RE.T.copy(),  G_IM.T.copy()
B_RE,  B_IM  = BT_RE.T.copy(), BT_IM.T.copy()
A_RE,  A_IM  = AT_RE.T.copy(), AT_IM.T.copy()

M_TILE, R_KERNEL = 4, 3                  # F(4,3)
TILE_IN = M_TILE + R_KERNEL - 1          # 6
WINO_EXTRA_SHIFT = 4                     # V=16·V_true → Y16=16·Y → >>4 (layer>>10 과 합쳐 >>14)


def cmatmul(Lr, Li, Rr, Ri):
    """복소수 행렬곱 (마지막 두 축, numpy broadcasting). 전부 int64 → bit-exact."""
    return (Lr @ Rr - Li @ Ri, Lr @ Ri + Li @ Rr)


# =============================================================================
# 1.  Conv2D — 복소수 Winograd F(4,3)  (정정판 행렬)
# =============================================================================

class Conv2D_WinogradComplexF43(rc.Conv2D_Spec):
    """
    3×3 stride-1 no-pad conv 을 복소수 Winograd F(4,3) 로. 명세 saturation 유지.
      _prepare_weight: U = G·g·Gᵀ 사전계산 → (U_re,U_im) int64 (OC,IC,6,6).
      forward: 6×6 tile(stride 4)마다 V=BᵀdB, M=Σ_IC U⊙V, Y16=AᵀMA, out=sat(Y16>>(shift+4)).
    """

    def __init__(self, weight, *, shift=10):
        super().__init__(weight, shift=shift)        # self.weight=(U_re,U_im)
        self._out_shift = shift + WINO_EXTRA_SHIFT    # >>14
        self.mul_per_ic_oc_tile = 46

    def _prepare_weight(self, w):
        assert w.shape[2:] == (3, 3), f"expected 3×3 kernel, got {w.shape}"
        g = w.astype(np.int64)
        z = np.zeros_like(g)
        s_re, s_im = cmatmul(G_RE, G_IM, g, z)            # G(6×3)@g → (OC,IC,6,3)
        U_re, U_im = cmatmul(s_re, s_im, GT_RE, GT_IM)    # @Gᵀ(3×6) → (OC,IC,6,6)
        return (U_re, U_im)

    def forward(self, x):
        assert x.dtype.kind == 'i'
        N, Cin, H, W = x.shape
        Ho, Wo = H - 2, W - 2
        assert Ho % M_TILE == 0 and Wo % M_TILE == 0, \
            f"output {Ho}×{Wo} must tile by {M_TILE} (F(4,3))"
        U_re, U_im = self.weight
        Cout = U_re.shape[0]
        out = np.empty((N, Cout, Ho, Wo), dtype=np.int8)
        x64 = x.astype(np.int64)

        for ty in range(Ho // M_TILE):
            for tx in range(Wo // M_TILE):
                r0, c0 = ty * M_TILE, tx * M_TILE
                d = x64[:, :, r0:r0 + TILE_IN, c0:c0 + TILE_IN]    # (N,Cin,6,6)
                dz = np.zeros_like(d)
                # V = Bᵀ d B
                t_re, t_im = cmatmul(BT_RE, BT_IM, d, dz)          # (N,Cin,6,6)
                V_re, V_im = cmatmul(t_re, t_im, B_RE, B_IM)       # (N,Cin,6,6)
                # M = Σ_IC U ⊙ V  (einsum 으로 IC 누적, 5D 미생성)
                M_re = (np.einsum('oipq,nipq->nopq', U_re, V_re)
                        - np.einsum('oipq,nipq->nopq', U_im, V_im))
                M_im = (np.einsum('oipq,nipq->nopq', U_re, V_im)
                        + np.einsum('oipq,nipq->nopq', U_im, V_re))
                # Y16 = Aᵀ M A  (= 16·Y)
                y_re, y_im = cmatmul(AT_RE, AT_IM, M_re, M_im)     # (N,OC,4,6)
                Y16_re, Y16_im = cmatmul(y_re, y_im, A_RE, A_IM)   # (N,OC,4,4)
                assert (Y16_im == 0).all(), \
                    f"tile({ty},{tx}): imag != 0 (변환행렬 오류)"
                assert (Y16_re % 16 == 0).all(), \
                    f"tile({ty},{tx}): Y16 not divisible by 16 (스케일 오류)"
                shifted = Y16_re >> self._out_shift                # arithmetic
                out[:, :, r0:r0 + M_TILE, c0:c0 + M_TILE] = \
                    np.clip(shifted, -128, 127).astype(np.int8)
        return out


# =============================================================================
# 2.  메인 — bit-exact 검증
# =============================================================================

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    data_dir = os.path.normpath(os.path.join(here, '..', '..', 'data', '_base_npy'))
    N_LIMIT = int(os.environ.get('WINO_N', '0')) or None

    print("=" * 66)
    print("Scenario #2: 복소수 Winograd F(4×4, 3×3) — Conv2 golden (정정판)")
    print("=" * 66)

    data = rc.load_assignment_data(data_dir=data_dir)
    images, expected = data['input'], data['output']
    w1, w2, wfc = data['w1'], data['w2'], data['wfc']
    if N_LIMIT:
        images, expected = images[:N_LIMIT], expected[:N_LIMIT]
    print(f"  data_dir = {data_dir}")
    print(f"  images={images.shape} {images.dtype}  w2={w2.shape}  N={images.shape[0]}")

    conv1        = rc.Conv2D_Spec(w1, shift=10)
    conv2_direct = rc.Conv2D_Spec(w2, shift=10)
    conv2_wino   = Conv2D_WinogradComplexF43(w2, shift=10)
    relu, pool, flat = rc.ReLU(), rc.MaxPool2x2(), rc.FlattenCHW()
    fc           = rc.FC_Spec(wfc, shift=10)

    f1 = relu(conv1(images)).astype(np.int8)                # (N,8,26,26)

    # (A) Winograd vs Direct Conv2 — bit-exact 핵심
    print("\n[A] Winograd Conv2 vs Direct Conv2 (bit-exact)")
    f2_d = conv2_direct(f1)
    t0 = time.time(); f2_w = conv2_wino(f1); dt = time.time() - t0
    match = (f2_w == f2_d); rate = float(match.mean())
    print(f"  bit-exact vs direct: {rate*100:.4f}%  "
          f"{'PASS ✅' if rate == 1.0 else 'FAIL'}  ({dt:.1f}s, {f2_w.shape})")
    if rate < 1.0:
        for b in np.argwhere(~match)[:5]:
            n, oc, r, c = b
            print(f"    mm (n={n},oc={oc},r={r},c={c}): wino={f2_w[n,oc,r,c]} direct={f2_d[n,oc,r,c]}")

    # (B) 전체 pipeline logit == output.npy
    print("\n[B] 전체 pipeline (Winograd Conv2) logit vs output.npy")
    logit = fc(flat(pool(relu(f2_w).astype(np.int8))))
    m = rc.bit_exact_match(logit, expected)
    print(f"  per-element match: {m['total_match_rate']*100:.4f}%  (target 100)")
    print(f"  per-image  match : {m['image_match_rate']*100:.4f}%  (target 100)")

    # (C) 곱셈 수 절감
    print("\n[C] 곱셈 수 (per image, Conv2)")
    n_tiles = (24 // M_TILE) ** 2
    wino_mul, direct_mul = n_tiles * 46 * 8 * 16, 24 * 24 * 9 * 8 * 16
    print(f"  direct  : {direct_mul:,} mul")
    print(f"  winograd: {wino_mul:,} mul   ({direct_mul / wino_mul:.2f}× 절감)")
    print("=" * 66)


if __name__ == "__main__":
    main()
