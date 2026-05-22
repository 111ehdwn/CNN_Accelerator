"""
0_reference.py
==============

시나리오 #1: INT8 Direct 컨볼루션 (명세 그대로) reference.

설계 노트
--------
- **self-contained**: CNN inference 함수들 (truncate, conv, relu, pool, fc, forward)을
  이 파일에 직접 정의. 다른 시나리오 스크립트와 코드가 갈라져도 한 파일만 보면
  그 시나리오 흐름이 명확히 보임. reference_core.py는 데이터 로드/검증 같은
  공통 utility만 import.
- 시나리오 #1은 **기준점**. 명세 LSB-10bit-shift + clip[-128,127] saturation을 비트
  단위로 정확히 시뮬레이트하여 expected output.npy와 100% 일치해야 함.

목적
----
1. .npy 5개 로드 → INT8 Direct forward.
2. expected output.npy와 비트 일치 검증 (목표 100%). 이게 통과해야 명세 해석 OK.
3. MNIST train split 앞 10K 라벨로 절대 정확도 측정.

명세 saturation 규칙 (Fig.4)
---------------------------
    acc (int32, bit-extended 누적)
      → shifted = acc >> 10           # LSB 10bit 산술 우측 시프트
      → clipped = clip(shifted, -128, 127)
      → out    = clipped.astype(int8) # LSB 8bit만 남김

이 규칙을 모든 Conv 출력 + FC 출력에 동일 적용.
"""

from __future__ import annotations

import os
import sys
import time
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reference_core as rc


# =============================================================================
# CNN 빌딩 블록 (이 시나리오 전용 — self-contained)
# =============================================================================

def _truncate_satdown(acc: np.ndarray, shift: int = 10) -> np.ndarray:
    """
    명세 INT8 saturation: acc (int32) → (>>shift) → clip[-128,127] → int8.

    numpy의 `>>`는 signed dtype에서 산술 시프트 (= floor division by 2^shift).
    예: -1 >> 1 == -1. 명세의 "LSB 10bit 버림"과 동일 의미.
    """
    assert acc.dtype.kind == 'i'
    shifted = acc >> shift
    clipped = np.clip(shifted, -128, 127)
    return clipped.astype(np.int8)


def _im2col_3x3(x: np.ndarray) -> np.ndarray:
    """
    3×3 stride-1 no-pad 컨볼루션용 im2col.

    Parameters
    ----------
    x : (N, C, H, W)

    Returns
    -------
    cols : (N, H-2, W-2, C*9) contiguous, dtype=x.dtype
    """
    N, C, H, W = x.shape
    out_h, out_w = H - 2, W - 2
    s_n, s_c, s_h, s_w = x.strides
    shape   = (N, C, out_h, out_w, 3, 3)
    strides = (s_n, s_c, s_h, s_w, s_h, s_w)
    patches = np.lib.stride_tricks.as_strided(x, shape=shape, strides=strides, writeable=False)
    # (N, C, oH, oW, 3, 3) → (N, oH, oW, C, 3, 3) → (N, oH, oW, C*9)
    cols = patches.transpose(0, 2, 3, 1, 4, 5).reshape(N, out_h, out_w, C * 9)
    return np.ascontiguousarray(cols)


def _conv2d_int8(x_int8: np.ndarray, w_int8: np.ndarray, *, shift: int = 10) -> np.ndarray:
    """
    3×3 stride-1 no-pad 컨볼루션 + 명세 saturation.

    im2col + np.matmul (Accelerate BLAS) 백엔드. int32 누적.

    Parameters
    ----------
    x_int8 : (N, Cin, H, W)   int8
    w_int8 : (Cout, Cin, 3, 3) int8

    Returns
    -------
    (N, Cout, H-2, W-2) int8
    """
    assert x_int8.dtype == np.int8 and w_int8.dtype == np.int8
    N, Cin, H, W = x_int8.shape
    Cout, Cin_w, KH, KW = w_int8.shape
    assert Cin == Cin_w and KH == 3 and KW == 3

    cols = _im2col_3x3(x_int8).astype(np.int32)               # (N, Ho, Wo, Cin*9)
    w_flat = w_int8.reshape(Cout, Cin * 9).astype(np.int32)   # (Cout, Cin*9)
    acc = cols @ w_flat.T                                      # (N, Ho, Wo, Cout) int32
    acc = acc.transpose(0, 3, 1, 2)                            # (N, Cout, Ho, Wo)
    return _truncate_satdown(acc, shift=shift)


def _relu_int8(x: np.ndarray) -> np.ndarray:
    """음수 → 0. saturation 직후 int8에 적용 (순서는 결과에 영향 없음)."""
    return np.maximum(x, 0).astype(np.int8)


def _maxpool2x2_int8(x: np.ndarray) -> np.ndarray:
    """
    2×2 stride-2 max pooling.

    (N, C, H, W) → (N, C, H/2, W/2). reshape trick으로 axis 3, 5 max.
    """
    N, C, H, W = x.shape
    assert H % 2 == 0 and W % 2 == 0
    pooled = x.reshape(N, C, H // 2, 2, W // 2, 2).max(axis=(3, 5))
    return pooled.astype(np.int8)


def _fc_int8(x_int8: np.ndarray, w_int8: np.ndarray, *, shift: int = 10) -> np.ndarray:
    """
    Fully Connected + 명세 saturation.

    Parameters
    ----------
    x_int8 : (N, In)   int8
    w_int8 : (Out, In) int8

    Returns
    -------
    (N, Out) int8
    """
    assert x_int8.dtype == np.int8 and w_int8.dtype == np.int8
    acc = x_int8.astype(np.int32) @ w_int8.astype(np.int32).T
    return _truncate_satdown(acc, shift=shift)


def _forward(images_int8: np.ndarray,
             w1_int8: np.ndarray,
             w2_int8: np.ndarray,
             wfc_int8: np.ndarray,
             *,
             shift: int = 10) -> np.ndarray:
    """
    명세 CNN: Conv1 → ReLU → Conv2 → ReLU → MaxPool → Flatten(C-order) → FC.

    Flatten은 (N, 16, 12, 12) → (N, 2304) C-order로 idx = c*144 + h*12 + w.

    Returns
    -------
    logit_int8 : (N, 10) int8
    """
    fmap1 = _conv2d_int8(images_int8, w1_int8, shift=shift)  # (N, 8, 26, 26)
    fmap1 = _relu_int8(fmap1)
    fmap2 = _conv2d_int8(fmap1, w2_int8, shift=shift)        # (N, 16, 24, 24)
    fmap2 = _relu_int8(fmap2)
    fmap3 = _maxpool2x2_int8(fmap2)                          # (N, 16, 12, 12)
    flat  = fmap3.reshape(fmap3.shape[0], -1)                # (N, 2304) C-order
    logit = _fc_int8(flat, wfc_int8, shift=shift)            # (N, 10)
    return logit


# =============================================================================
# 메인
# =============================================================================

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    data_dir    = os.path.normpath(os.path.join(here, '..', 'data'))
    mnist_cache = os.path.join(data_dir, 'mnist_cache')

    print("=" * 60)
    print("Scenario #1: INT8 Direct (reference)")
    print("=" * 60)

    # --- 데이터 로드 ---
    print(f"[load] assignment .npy from {data_dir}")
    data = rc.load_assignment_data(data_dir=data_dir)
    images   = data['input']
    expected = data['output']
    w1, w2, wfc = data['w1'], data['w2'], data['wfc']

    print(f"  input   : shape={images.shape}, dtype={images.dtype},"
          f" range=[{images.min()}, {images.max()}]")
    print(f"  output  : shape={expected.shape}, dtype={expected.dtype},"
          f" range=[{expected.min()}, {expected.max()}]")
    print(f"  w1/w2/wfc: {w1.shape}, {w2.shape}, {wfc.shape}")

    print(f"[load] MNIST train labels (first 10K) from torchvision")
    true_labels = rc.load_mnist_train_labels_first_10k(mnist_cache)
    print(f"  labels: shape={true_labels.shape}")

    # --- Forward ---
    print("\n[forward] INT8 Direct on 10K images ...")
    t0 = time.time()
    my_logit = _forward(images, w1, w2, wfc)
    dt = time.time() - t0
    print(f"  done in {dt:.2f}s ({10000/dt:.0f} img/s)")
    print(f"  my_logit: shape={my_logit.shape}, range=[{my_logit.min()}, {my_logit.max()}]")

    # --- 검증 1: bit-exact ---
    print("\n[verify] bit-exact match vs expected output.npy")
    m = rc.bit_exact_match(my_logit, expected)
    print(f"  per-element match : {m['total_match_rate']*100:.4f}%  (target 100.0000%)")
    print(f"  per-image  match  : {m['image_match_rate']*100:.4f}%  (target 100.0000%)")

    if m['image_match_rate'] < 1.0:
        mm = np.where(~m['per_image_match'])[0]
        print(f"  MISMATCH: {len(mm)} images differ. first 5: {mm[:5].tolist()}")
        for idx in mm[:3]:
            diff = my_logit[idx].astype(np.int32) - expected[idx].astype(np.int32)
            print(f"    img {idx}: my ={my_logit[idx].tolist()}")
            print(f"           ref={expected[idx].tolist()}")
            print(f"           diff={diff.tolist()}")
    else:
        print("  OK: 100% bit-exact match.")

    # --- 검증 2: 절대 정확도 ---
    print("\n[accuracy] vs MNIST true labels")
    my_pred  = my_logit.argmax(axis=1)
    ref_pred = expected.argmax(axis=1)
    abs_acc       = (my_pred == true_labels).mean()
    ref_acc       = (ref_pred == true_labels).mean()
    my_vs_ref_acc = (my_pred == ref_pred).mean()
    print(f"  absolute accuracy (my  vs true) : {abs_acc*100:.4f}%")
    print(f"  absolute accuracy (ref vs true) : {ref_acc*100:.4f}%  "
          f"# INT8 quantized network 본질적 상한")
    print(f"  reference agreement (my vs ref) : {my_vs_ref_acc*100:.4f}%  "
          f"# INT8 Direct는 100% 기대")

    print("\n" + "=" * 60)
    if m['image_match_rate'] == 1.0:
        print("PASS: INT8 Direct reference 검증 완료.")
    else:
        print("FAIL: bit-exact 불일치. 규칙 재검토 필요.")
    print("=" * 60)


if __name__ == "__main__":
    main()
