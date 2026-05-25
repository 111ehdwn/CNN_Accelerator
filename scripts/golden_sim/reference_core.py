"""
reference_core.py
=================

시나리오 스크립트 (0_reference.py, 1_quantize.py, 3_complex_winograd_f(4,3).py 등)가
공통으로 import해서 쓰는 모듈.

두 가지 종류의 컨텐츠가 들어있다 (코드 안에서 큰 헤더로 시각 분리):

  1. **데이터 / 검증 utility**: .npy 로드, MNIST 라벨 로드, bit-exact 비교.
  2. **CNN 레이어 클래스 정의**: 명세 saturation 규칙을 갖는 Conv/FC base 클래스
     (`Conv2D_Spec`, `FC_Spec`) + dtype-agnostic 보조 레이어 (`ReLU`, `MaxPool2x2`,
     `FlattenCHW`). 각 시나리오는 base를 상속해 `_prepare_weight` (weight 양자화) 또는
     `_multiply_accumulate` (Winograd MAC 등)만 override → 자기 `_forward()`에서 조립.

네이밍 원칙
----------
- `_Spec` 접미사: 명세 saturation (LSB-shift + clip[-128,127])을 갖는 레이어.
  Conv/FC가 해당. INT8/INT4/Winograd 등 어떤 시나리오에서도 saturation 규칙은
  명세에 고정되어 있으므로 base 이름에 `Spec`을 박아둠.
- saturation을 안 거치는 dtype-무관 연산 (ReLU, MaxPool, Flatten)은 접미사 없음.

설계 원칙
--------
- numpy만 사용 (PyTorch X). int32 누적, 명시적 shift/saturate.
- 각 레이어는 __call__ = forward 형태로 호출 가능 (PyTorch nn.Module과 유사하지만
  의존성 없는 순수 Python 클래스).
- Override 단위는 두 층:
    (a) 메서드: _prepare_weight, _multiply_accumulate 등 — 부분 변경
    (b) 클래스 전체: Conv2D_WinogradComplexF43 같이 새 클래스 — 큰 변경
- 시나리오별 클래스는 base를 상속해 **시나리오 스크립트 파일 안에 직접 정의**한다.
  (reference_core.py에는 base만, 특화는 시나리오 파일에)
"""

from __future__ import annotations

import os
import numpy as np


# =============================================================================
# ##                                                                         ##
# ##              SECTION 1.  데이터 / 검증 UTILITY                             ##
# ##                                                                         ##
# =============================================================================

def load_assignment_data(data_dir: str = "../data") -> dict:
    """
    과제 .npy 5개 일괄 로드.

    Returns
    -------
    dict with keys:
        'input'  : (10000, 1, 28, 28) int8 — 입력 이미지
        'output' : (10000, 10)        int8 — 기대 logit (reference 비교용)
        'w1'     : (8, 1, 3, 3)       int8 — Conv1 weight
        'w2'     : (16, 8, 3, 3)      int8 — Conv2 weight
        'wfc'    : (10, 2304)         int8 — FC weight
    """
    d = lambda f: os.path.join(data_dir, f)
    return {
        'input':  np.load(d('input.npy')),
        'output': np.load(d('output.npy')),
        'w1':     np.load(d('layer1_0_weight.npy')),
        'w2':     np.load(d('layer2_0_weight.npy')),
        'wfc':    np.load(d('fc1_weight.npy')),
    }


def load_mnist_train_labels_first_10k(cache_dir: str) -> np.ndarray:
    """
    MNIST train split의 앞 10000장 라벨을 torchvision으로 로드.

    Why train, not test
    -------------------
    input.npy의 첫 5장이 (5, 0, 4, 1, 9)로 MNIST **train split** 첫 5장과 일치.
    조교 배포 데이터는 train split 앞 10000장으로 추정. test split이 아님.

    Parameters
    ----------
    cache_dir : torchvision MNIST 다운로드 캐시 디렉토리. 첫 호출 시 인터넷 필요.

    Returns
    -------
    labels : (10000,) int64 — 0~9
    """
    try:
        from torchvision.datasets import MNIST
    except ImportError as e:
        raise ImportError(
            "torchvision이 필요합니다. `pip install torchvision` 후 재실행."
        ) from e

    os.makedirs(cache_dir, exist_ok=True)
    ds = MNIST(root=cache_dir, train=True, download=True)
    labels_full = ds.targets.numpy().astype(np.int64)
    assert labels_full.shape == (60000,), f"unexpected MNIST train shape: {labels_full.shape}"
    return labels_full[:10000]


def bit_exact_match(my_logit: np.ndarray, expected_logit: np.ndarray) -> dict:
    """
    명세 reference와의 비트 일치 검증.

    Returns
    -------
    dict {
        'per_image_match'  : (N,) bool   — 이미지별 10개 logit 모두 일치하는지
        'total_match_rate' : float        — 모든 logit 원소 기준 일치 비율
        'image_match_rate' : float        — 이미지 단위 일치 비율
    }
    """
    assert my_logit.shape == expected_logit.shape
    elem_match = (my_logit == expected_logit)
    per_image = elem_match.all(axis=1)
    return {
        'per_image_match': per_image,
        'total_match_rate': float(elem_match.mean()),
        'image_match_rate': float(per_image.mean()),
    }


# =============================================================================
# ##                                                                         ##
# ##              SECTION 2.  CNN 레이어 클래스 정의                             ##
# ##                                                                         ##
# ##  각 레이어는 __call__ → forward로 호출.                                      ##
# ##  Conv2D_Spec, FC_Spec은 시나리오 override 포인트 (_prepare_weight,           ##
# ##  _multiply_accumulate) 제공.                                              ##
# ##                                                                         ##
# =============================================================================

# -----------------------------------------------------------------------------
# 2.0  공통 base
# -----------------------------------------------------------------------------

class _Layer:
    """
    모든 레이어의 베이스. __call__(x) → forward(x) 패턴.

    PyTorch nn.Module과 유사하지만 의존성 없는 순수 Python 클래스.
    """
    def __call__(self, x: np.ndarray) -> np.ndarray:
        return self.forward(x)

    def forward(self, x: np.ndarray) -> np.ndarray:
        raise NotImplementedError


# -----------------------------------------------------------------------------
# 2.1  명세 saturation
# -----------------------------------------------------------------------------

class TruncateSatDown(_Layer):
    """
    명세 INT8 saturation (Fig.4):
        acc (int32)
          → shifted = acc >> shift           # LSB n비트 산술 우측 시프트
          → clipped = clip(shifted, -128, 127)
          → out     = clipped.astype(int8)   # LSB 8비트만 남김

    numpy의 `>>`는 signed dtype에서 산술 시프트 (= floor division by 2^shift).
    예: -1 >> 1 == -1. 명세의 "LSB 10bit 버림"과 동일 의미.
    """
    def __init__(self, shift: int = 10):
        self.shift = shift

    def forward(self, acc: np.ndarray) -> np.ndarray:
        assert acc.dtype.kind == 'i', f"acc must be signed int, got {acc.dtype}"
        shifted = acc >> self.shift
        clipped = np.clip(shifted, -128, 127)
        return clipped.astype(np.int8)


# -----------------------------------------------------------------------------
# 2.2  내부 헬퍼 (im2col)
# -----------------------------------------------------------------------------

def _im2col_3x3(x: np.ndarray) -> np.ndarray:
    """
    3×3 stride-1 no-pad 컨볼루션용 im2col.

    Parameters
    ----------
    x : (N, C, H, W)

    Returns
    -------
    cols : (N, H-2, W-2, C*9) contiguous, dtype=x.dtype

    구현
    ----
    stride tricks로 (N, C, oH, oW, 3, 3) view 생성, transpose 후 contiguous 복사.
    M4 Max에서 numpy stride_tricks + Accelerate BLAS matmul이 매우 빠름.
    """
    N, C, H, W = x.shape
    out_h, out_w = H - 2, W - 2
    s_n, s_c, s_h, s_w = x.strides
    shape   = (N, C, out_h, out_w, 3, 3)
    strides = (s_n, s_c, s_h, s_w, s_h, s_w)
    patches = np.lib.stride_tricks.as_strided(x, shape=shape, strides=strides, writeable=False)
    cols = patches.transpose(0, 2, 3, 1, 4, 5).reshape(N, out_h, out_w, C * 9)
    return np.ascontiguousarray(cols)


# -----------------------------------------------------------------------------
# 2.3  Conv2D (3×3 stride-1 no-pad, 명세 saturation base)
# -----------------------------------------------------------------------------

class Conv2D_Spec(_Layer):
    """
    명세 saturation을 갖는 3×3 stride-1 no-pad 컨볼루션 base 클래스.

    "Spec" 접미사: 어느 시나리오에서도 명세 saturation (LSB-shift + clip[-128,127])
    규칙은 고정이므로 base 이름에 박아둠. 시나리오별 자식 클래스 이름은
    `Conv2D_QuantWeight`, `Conv2D_WinogradComplexF43` 등으로 자연스럽게 확장.

    Pipeline (default forward, Direct 알고리즘)
    -------------------------------------------
        x (N, Cin, H, W) signed int
          → im2col       → cols (N, Ho, Wo, Cin*9) int32
          → MAC          → acc  (N, Ho, Wo, Cout)  int32   ← _multiply_accumulate
          → transpose    → acc  (N, Cout, Ho, Wo)  int32
          → saturate     → out  (N, Cout, Ho, Wo)  int8    ← self.sat

    Override 포인트
    ---------------
    (a) `_prepare_weight(raw_w) → stored_w`
            weight 양자화 등 weight 전처리. `__init__`에서 한 번 호출.
            기본은 그대로 반환.
    (b) `_multiply_accumulate(cols_int32)` → acc_int32
            MAC 본체. Direct는 lazy하게 build된 `_w_flat_int32_cache`와 matmul.
            알고리즘이 다른 자식이 이것을 override하면 default 캐시는 unused.
    (c) `forward(x)` 통째 override
            Winograd처럼 im2col-MAC-transpose 형태 자체를 벗어나는 알고리즘은
            forward 전체를 새로 작성. 이때 self.weight (변환된 형태)와 self.sat을
            그대로 활용 가능.

    유연성 노트
    ----------
    - `_prepare_weight`가 임의 shape/dtype을 반환해도 base는 강제하지 않음.
      단, default `_multiply_accumulate`는 `self.weight.shape == (Cout, Cin, KH, KW)`를
      가정한 lazy 캐시를 만들므로, Winograd 같이 (Cout, Cin, m, m) 또는 더 큰
      비트폭(int16/int32)으로 변환된 weight를 쓰려면 `_multiply_accumulate` 또는
      `forward`를 함께 override 해야 함.
    - dtype assert는 `kind == 'i'`만 검사 (int8/int16/int32 등 mixed-precision 허용).

    Parameters
    ----------
    weight : signed int ndarray — raw weight. Direct default를 쓰려면 (Cout, Cin, 3, 3).
    shift  : 명세 saturation shift (기본 10)
    """
    def __init__(self, weight: np.ndarray, *, shift: int = 10):
        assert weight.dtype.kind == 'i', f"weight must be signed int, got {weight.dtype}"
        self.weight_raw = weight
        self.weight = self._prepare_weight(weight)   # 시나리오별 override 포인트
        self.sat = TruncateSatDown(shift=shift)
        # Direct default용 lazy 캐시. _multiply_accumulate가 처음 호출될 때 build.
        # 자식이 forward나 _multiply_accumulate를 override하면 영원히 None으로 남음.
        self._w_flat_int32_cache: np.ndarray | None = None

    # ---- override 포인트들 -------------------------------------------------

    def _prepare_weight(self, w: np.ndarray) -> np.ndarray:
        """
        시나리오별 weight 전처리 (양자화, Winograd 변환 등). 기본은 그대로 반환.

        Returns
        -------
        weight : 임의 shape/dtype 가능. 단, default `_multiply_accumulate`를 그대로
                 쓰려면 (Cout, Cin, KH, KW) signed int 형식 유지. 다른 형식을
                 반환하려면 `_multiply_accumulate` 또는 `forward`를 함께 override.
        """
        return w

    def _multiply_accumulate(self, cols_int32: np.ndarray) -> np.ndarray:
        """
        MAC 본체 (default: Direct numpy matmul).

        Parameters
        ----------
        cols_int32 : (N, Ho, Wo, Cin*K*K) int32 — im2col 결과

        Returns
        -------
        acc : (N, Ho, Wo, Cout) int32

        구현
        ----
        lazy 캐시. 첫 호출 시 self.weight.reshape(Cout, -1).astype(int32) 생성.
        자식이 이 메서드를 override하면 캐시는 만들어지지 않음.
        """
        if self._w_flat_int32_cache is None:
            w = self.weight
            assert w.dtype.kind == 'i', f"weight dtype must be signed int, got {w.dtype}"
            assert w.ndim == 4, \
                f"default _multiply_accumulate expects 4D weight, got shape {w.shape}"
            Cout = w.shape[0]
            self._w_flat_int32_cache = w.reshape(Cout, -1).astype(np.int32)
        return cols_int32 @ self._w_flat_int32_cache.T

    # ---- forward -----------------------------------------------------------

    def forward(self, x: np.ndarray) -> np.ndarray:
        """
        Default Direct forward. Winograd 등 큰 변경은 자식에서 통째 override.
        """
        assert x.dtype.kind == 'i', f"input dtype must be signed int, got {x.dtype}"
        cols = _im2col_3x3(x).astype(np.int32)
        acc = self._multiply_accumulate(cols)          # (N, Ho, Wo, Cout) int32
        acc = acc.transpose(0, 3, 1, 2)                # (N, Cout, Ho, Wo)
        return self.sat(acc)


# -----------------------------------------------------------------------------
# 2.4  ReLU
# -----------------------------------------------------------------------------

class ReLU(_Layer):
    """
    ReLU. 음수 → 0. dtype-무관 (입력 dtype 그대로 반환).

    명세에서 saturation 직후 int8에 적용. saturation 이전 int32에 적용해도 결과
    동일 (clip[-128,127]은 양수 영역 1:1, ReLU는 음수만 0으로 → 가환).
    """
    def forward(self, x: np.ndarray) -> np.ndarray:
        return np.maximum(x, 0)


# -----------------------------------------------------------------------------
# 2.5  MaxPool 2×2
# -----------------------------------------------------------------------------

class MaxPool2x2(_Layer):
    """
    2×2 stride-2 max pooling. dtype-무관.

    (N, C, H, W) → (N, C, H/2, W/2)
    H, W는 짝수여야 함 (명세 입력 24×24 → 12×12).
    reshape trick으로 axis (3, 5) max.
    """
    def forward(self, x: np.ndarray) -> np.ndarray:
        N, C, H, W = x.shape
        assert H % 2 == 0 and W % 2 == 0
        return x.reshape(N, C, H // 2, 2, W // 2, 2).max(axis=(3, 5))


# -----------------------------------------------------------------------------
# 2.6  Flatten (C-order)
# -----------------------------------------------------------------------------

class FlattenCHW(_Layer):
    """
    (N, C, H, W) → (N, C*H*W) numpy C-order.

    명세 Fig.3:  idx = c * H*W + h * W + w
    한 채널의 H×W가 W 빠르게 변하며 펼쳐지고, 다음 채널 이어짐.
    """
    def forward(self, x: np.ndarray) -> np.ndarray:
        return x.reshape(x.shape[0], -1)


# -----------------------------------------------------------------------------
# 2.7  Fully Connected
# -----------------------------------------------------------------------------

class FC_Spec(_Layer):
    """
    명세 saturation을 갖는 Fully Connected base 클래스.

    Pipeline (default)
    ------------------
        x (N, In) signed int
          → matmul     → acc (N, Out) int32   ← _multiply_accumulate
          → saturate   → out (N, Out) int8    ← self.sat

    Override 포인트 (Conv2D_Spec과 동일 패턴)
    ----------------------------------------
    (a) `_prepare_weight(raw_w) → stored_w`
            weight 양자화 등. 기본은 그대로.
    (b) `_multiply_accumulate(x_int32)` → acc_int32
            MAC 본체. lazy 캐시 (self._w_int32_cache) 사용.

    Parameters
    ----------
    weight : (Out, In) signed int
    shift  : saturation shift (기본 10)
    """
    def __init__(self, weight: np.ndarray, *, shift: int = 10):
        assert weight.dtype.kind == 'i', f"weight must be signed int, got {weight.dtype}"
        assert weight.ndim == 2
        self.weight_raw = weight
        self.weight = self._prepare_weight(weight)
        self.sat = TruncateSatDown(shift=shift)
        # lazy int32 캐시. _multiply_accumulate 첫 호출 시 build.
        self._w_int32_cache: np.ndarray | None = None

    # ---- override 포인트들 -------------------------------------------------

    def _prepare_weight(self, w: np.ndarray) -> np.ndarray:
        """시나리오별 weight 전처리. 기본은 그대로."""
        return w

    def _multiply_accumulate(self, x_int32: np.ndarray) -> np.ndarray:
        """
        Parameters
        ----------
        x_int32 : (N, In) int32

        Returns
        -------
        acc : (N, Out) int32
        """
        if self._w_int32_cache is None:
            self._w_int32_cache = self.weight.astype(np.int32)
        return x_int32 @ self._w_int32_cache.T

    # ---- forward -----------------------------------------------------------

    def forward(self, x: np.ndarray) -> np.ndarray:
        assert x.dtype.kind == 'i', f"input dtype must be signed int, got {x.dtype}"
        acc = self._multiply_accumulate(x.astype(np.int32))
        return self.sat(acc)
