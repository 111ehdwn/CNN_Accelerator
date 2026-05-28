"""
gen_multi_img_hex.py
====================
Multi-image hex 데이터 생성 — Conv2 engine 의 multi-image / single-image testbench 용.

MNIST input 0..N-1 (default 100 image) 에 대해 Conv1 + Conv2 forward 를 거쳐:
  - imgXXX_c1c2.hex   : Conv2 입력 데이터 (= Conv1 output), **1024 lines × 64-bit (padded)**
  - imgXXX_c2pool.hex : Conv2 expected output, 576 lines × 128-bit
  - all_c1c2.hex      : 100 × 1024 = 102,400 lines (concatenated)
  - all_c2pool.hex    : 100 × 576  = 57,600  lines (concatenated)

per-image file (Option B). Testbench 가 file 단위로 image index 별 load.

Hex 포맷:
  c1c2 (64-bit, 16 hex chars/line, **padded h*32+w**):
    line[h*32 + w] = packed 8 IC bytes for input spatial (h, w),  h, w ∈ [0, 25]
                   IC 0 = LSB (lowest 8 bits)
    line[h*32 + w] = 0 for w ∈ [26, 31] or h ∈ [26, 31]   ← padding
    → 1 bank = 32 row × 32 col = 1024 entry. BMG depth 2048 = 2 bank × 1024.
    → BMG addr = {bank_sel, h[4:0], w[4:0]} = bank*1024 + h*32 + w  와 직접 매핑.
    → single_img / multi_img TB 어디서나 같은 hex 파일 그대로 사용 가능.

  c2pool (128-bit, 32 hex chars/line, compact h*24+w):
    line[h*24 + w] = packed 16 OC bytes for output spatial (h, w)
                   OC 0 = LSB
    → 1 bank = 576 entry, BMG depth 2048 = 2 bank × 1024 (576 만 사용).
    → BMG addr = {bank_sel, write_addr[9:0]} (write_addr = 0..575, sequential)

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

# c1c2 padded format
C1C2_BANK_DEPTH = 1024     # 32 row × 32 col
C1C2_ROW_STRIDE = 32       # padded col stride (5-bit col field)

# ---------------------------------------------------------------------------
# Conv 함수 (numpy 벡터화)
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
    acc    = cols @ w_flat.T                  # (N, oH, oW, OC)
    acc    = acc.transpose(0, 3, 1, 2)        # (N, OC, oH, oW)
    shifted = acc >> shift
    sat     = np.clip(shifted, -128, 127).astype(np.int8)
    return np.maximum(sat, 0).astype(np.int8)  # ReLU


# ---------------------------------------------------------------------------
# Packing helpers
# ---------------------------------------------------------------------------
def pack_8ic(fmap, img_idx, h, w):
    """fmap[img_idx, ic, h, w] for ic=0..7 → packed 64-bit (IC 0 = LSB)."""
    word = 0
    for ic in range(8):
        byte = int(fmap[img_idx, ic, h, w]) & 0xFF
        word |= (byte << (ic * 8))
    return word


def pack_16oc(fmap, img_idx, h, w):
    """fmap[img_idx, oc, h, w] for oc=0..15 → packed 128-bit (OC 0 = LSB)."""
    word = 0
    for oc in range(16):
        byte = int(fmap[img_idx, oc, h, w]) & 0xFF
        word |= (byte << (oc * 8))
    return word


def build_c1c2_padded(fmap1, img_idx):
    """1024 entries × 64-bit, h*32+w 순서. (h, w) ∈ [0, 25] valid, 나머지 0."""
    padded = [0] * C1C2_BANK_DEPTH
    for h in range(26):
        for w in range(26):
            padded[h * C1C2_ROW_STRIDE + w] = pack_8ic(fmap1, img_idx, h, w)
    return padded


def build_c2pool_compact(fmap2, img_idx):
    """576 entries × 128-bit, h*24+w 순서 (write_addr = pixel sequential index)."""
    compact = [0] * 576
    for h in range(24):
        for w in range(24):
            compact[h * 24 + w] = pack_16oc(fmap2, img_idx, h, w)
    return compact


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
# Forward (N_IMAGES 일괄)
# ---------------------------------------------------------------------------
images = inp[:N_IMAGES]              # (N, 1, 28, 28)
print(f"\n[Forward] {N_IMAGES} image: Conv1 + ReLU → Conv2 + ReLU")

fmap1 = conv2d_int8(images, w1)     # (N, 8, 26, 26)
print(f"  fmap1 (Conv1 output): shape={fmap1.shape}, range=[{fmap1.min()}, {fmap1.max()}]")

fmap2 = conv2d_int8(fmap1, w2)      # (N, 16, 24, 24)
print(f"  fmap2 (Conv2 output): shape={fmap2.shape}, range=[{fmap2.min()}, {fmap2.max()}]")

# ---------------------------------------------------------------------------
# Per-image hex 출력
# ---------------------------------------------------------------------------
os.makedirs(OUTPUT_DIR, exist_ok=True)
print(f"\n[Write] per-image hex → {OUTPUT_DIR}/img{{idx:03d}}_{{c1c2,c2pool}}.hex")
print(f"        c1c2  : {C1C2_BANK_DEPTH} lines × 64-bit (padded h*32+w, BMG bank format)")
print(f"        c2pool: 576 lines × 128-bit (compact h*24+w)")

for img_idx in range(N_IMAGES):
    c1c2 = build_c1c2_padded(fmap1, img_idx)
    with open(os.path.join(OUTPUT_DIR, f"img{img_idx:03d}_c1c2.hex"), "w") as f:
        for word in c1c2:
            f.write(f"{word:016X}\n")

    c2pool = build_c2pool_compact(fmap2, img_idx)
    with open(os.path.join(OUTPUT_DIR, f"img{img_idx:03d}_c2pool.hex"), "w") as f:
        for word in c2pool:
            f.write(f"{word:032X}\n")

    if (img_idx + 1) % 20 == 0:
        print(f"  ... {img_idx + 1} / {N_IMAGES}")

print(f"  {N_IMAGES * 2} per-image files done")

# ---------------------------------------------------------------------------
# Concatenated big files (multi_img TB 의 $readmemh 용, V2001 호환)
#   all_c1c2.hex   : N × 1024 = 102,400 lines × 64-bit
#   all_c2pool.hex : N × 576  =  57,600 lines × 128-bit
# ---------------------------------------------------------------------------
print(f"\n[Write] concatenated big-files (V2001-compatible $readmemh)")

all_c1c2_path = os.path.join(OUTPUT_DIR, "all_c1c2.hex")
with open(all_c1c2_path, "w") as f:
    for img_idx in range(N_IMAGES):
        for word in build_c1c2_padded(fmap1, img_idx):
            f.write(f"{word:016X}\n")
print(f"  {all_c1c2_path}  ({N_IMAGES * C1C2_BANK_DEPTH} lines, 64-bit)")

all_c2pool_path = os.path.join(OUTPUT_DIR, "all_c2pool.hex")
with open(all_c2pool_path, "w") as f:
    for img_idx in range(N_IMAGES):
        for word in build_c2pool_compact(fmap2, img_idx):
            f.write(f"{word:032X}\n")
print(f"  {all_c2pool_path}  ({N_IMAGES * 576} lines, 128-bit)")

print(f"\n[Done]")
