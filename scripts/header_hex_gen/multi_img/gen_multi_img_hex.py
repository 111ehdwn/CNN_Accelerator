"""
gen_multi_img_hex.py
====================
Multi-image hex 데이터 생성 — Conv2 engine 의 multi-image testbench 용.

MNIST input 0..99 (100 image) 에 대해 Conv1 + Conv2 forward 를 거쳐:
  - imgXXX_c1c2.hex   : Conv2 입력 데이터 (= Conv1 output), 676 lines × 64-bit
  - imgXXX_c2pool.hex : Conv2 expected output, 576 lines × 128-bit

per-image file (Option B). Testbench 가 file 단위로 image index 별 load.

Hex 포맷:
  c1c2 (64-bit, 16 hex chars/line):
    line[h*26 + w] = packed 8 IC bytes for input spatial (h, w)
                   IC 0 = LSB (lowest 8 bits)
  c2pool (128-bit, 32 hex chars/line):
    line[h*24 + w] = packed 16 OC bytes for output spatial (h, w)
                   OC 0 = LSB

Testbench 측 BMG 주소 변환 (별도, TB 가 처리):
  c1c2 BMG addr = {bank_sel, h[4:0], w[4:0]} = bank_sel*1024 + h*32 + w
  c2pool BMG addr = {bank_sel, h*24 + w[9:0]} = bank_sel*1024 + h*24 + w

실행:
  cd scripts/header_hex_gen/multi_img
  python3 gen_multi_img_hex.py
"""

import os
import numpy as np

# ---------------------------------------------------------------------------
# 경로 (스크립트 디렉토리에서 실행 가정)
# ---------------------------------------------------------------------------
INPUT_FILE   = "../../../data/npy/input.npy"
WEIGHT1_FILE = "../../../data/npy/layer1_0_weight.npy"
WEIGHT2_FILE = "../../../data/npy/layer2_0_weight.npy"
OUTPUT_DIR   = "../../../data/multi_img"

N_IMAGES = 100

# ---------------------------------------------------------------------------
# Conv 함수 (numpy 벡터화, 100 image 일괄 처리)
# ---------------------------------------------------------------------------
def im2col_3x3(x):
    """3x3 stride-1 no-pad im2col. x: (N, C, H, W) → (N, oH, oW, C*9)."""
    N, C, H, W = x.shape
    oH, oW = H - 2, W - 2
    s_n, s_c, s_h, s_w = x.strides
    patches = np.lib.stride_tricks.as_strided(
        x,
        shape   = (N, C, oH, oW, 3, 3),
        strides = (s_n, s_c, s_h, s_w, s_h, s_w),
        writeable = False,
    )
    return np.ascontiguousarray(patches.transpose(0, 2, 3, 1, 4, 5).reshape(N, oH, oW, C * 9))


def conv2d_int8(x_int8, w_int8, shift=10):
    """Conv2d (stride 1, no pad) + >>shift + clip[-128, 127] + ReLU. int8 input → int8 output."""
    cols   = im2col_3x3(x_int8).astype(np.int32)
    w_flat = w_int8.reshape(w_int8.shape[0], -1).astype(np.int32)
    acc    = cols @ w_flat.T                 # (N, oH, oW, OC)
    acc    = acc.transpose(0, 3, 1, 2)        # (N, OC, oH, oW)
    shifted = acc >> shift
    sat     = np.clip(shifted, -128, 127).astype(np.int8)
    return np.maximum(sat, 0).astype(np.int8)  # ReLU


# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------
print(f"[Load] {INPUT_FILE}")
inp = np.load(INPUT_FILE)           # (10000, 1, 28, 28) int8
print(f"       shape={inp.shape}, dtype={inp.dtype}")
assert inp.shape[1:] == (1, 28, 28), f"unexpected input shape {inp.shape}"

print(f"[Load] {WEIGHT1_FILE}")
w1 = np.load(WEIGHT1_FILE)          # (8, 1, 3, 3) int8
print(f"       shape={w1.shape}")
assert w1.shape == (8, 1, 3, 3)

print(f"[Load] {WEIGHT2_FILE}")
w2 = np.load(WEIGHT2_FILE)          # (16, 8, 3, 3) int8
print(f"       shape={w2.shape}")
assert w2.shape == (16, 8, 3, 3)

# ---------------------------------------------------------------------------
# Forward (100 image 일괄)
# ---------------------------------------------------------------------------
images = inp[:N_IMAGES]              # (100, 1, 28, 28)
print(f"\n[Forward] {N_IMAGES} image: Conv1 + ReLU → Conv2 + ReLU")

fmap1 = conv2d_int8(images, w1)     # (100, 8, 26, 26)
print(f"  fmap1 (Conv1 output)  : shape={fmap1.shape}, range=[{fmap1.min()}, {fmap1.max()}]")

fmap2 = conv2d_int8(fmap1, w2)      # (100, 16, 24, 24)
print(f"  fmap2 (Conv2 output)  : shape={fmap2.shape}, range=[{fmap2.min()}, {fmap2.max()}]")

# ---------------------------------------------------------------------------
# Hex 출력 (per-image)
# ---------------------------------------------------------------------------
os.makedirs(OUTPUT_DIR, exist_ok=True)

print(f"\n[Write] per-image hex → {OUTPUT_DIR}/img{{idx:03d}}_c1c2.hex, _c2pool.hex")

for img_idx in range(N_IMAGES):
    # c1c2 : 676 lines × 64-bit (8 IC packed, IC 0 = LSB)
    c1c2_path = os.path.join(OUTPUT_DIR, f"img{img_idx:03d}_c1c2.hex")
    with open(c1c2_path, "w") as f:
        for h in range(26):
            for w in range(26):
                word = 0
                for ic in range(8):
                    byte = int(fmap1[img_idx, ic, h, w]) & 0xFF
                    word |= (byte << (ic * 8))
                f.write(f"{word:016X}\n")

    # c2pool : 576 lines × 128-bit (16 OC packed, OC 0 = LSB)
    c2pool_path = os.path.join(OUTPUT_DIR, f"img{img_idx:03d}_c2pool.hex")
    with open(c2pool_path, "w") as f:
        for h in range(24):
            for w in range(24):
                word = 0
                for oc in range(16):
                    byte = int(fmap2[img_idx, oc, h, w]) & 0xFF
                    word |= (byte << (oc * 8))
                f.write(f"{word:032X}\n")

    if (img_idx + 1) % 20 == 0:
        print(f"  ... {img_idx + 1} / {N_IMAGES}")

print(f"  {N_IMAGES * 2} per-image files done")

# ---------------------------------------------------------------------------
# 추가 출력: 전체 이미지 concatenated (testbench 의 V2001-호환 $readmemh 용)
#   all_c1c2.hex   : 100 × 676 = 67,600 lines × 64-bit
#   all_c2pool.hex : 100 × 576 = 57,600 lines × 128-bit
# ---------------------------------------------------------------------------
print(f"\n[Write] concatenated files (V2001-compatible $readmemh)")

all_c1c2_path = os.path.join(OUTPUT_DIR, "all_c1c2.hex")
with open(all_c1c2_path, "w") as f:
    for img_idx in range(N_IMAGES):
        for h in range(26):
            for w in range(26):
                word = 0
                for ic in range(8):
                    byte = int(fmap1[img_idx, ic, h, w]) & 0xFF
                    word |= (byte << (ic * 8))
                f.write(f"{word:016X}\n")
print(f"  {all_c1c2_path}  ({N_IMAGES * 676} lines, 64-bit)")

all_c2pool_path = os.path.join(OUTPUT_DIR, "all_c2pool.hex")
with open(all_c2pool_path, "w") as f:
    for img_idx in range(N_IMAGES):
        for h in range(24):
            for w in range(24):
                word = 0
                for oc in range(16):
                    byte = int(fmap2[img_idx, oc, h, w]) & 0xFF
                    word |= (byte << (oc * 8))
                f.write(f"{word:032X}\n")
print(f"  {all_c2pool_path}  ({N_IMAGES * 576} lines, 128-bit)")

print(f"\n[Done]")
