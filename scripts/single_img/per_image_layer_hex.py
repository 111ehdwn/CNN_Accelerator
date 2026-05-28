"""
per_image_layer_hex.py
======================
단일 이미지 (configurable IMAGE_IDX) 의 layer-by-layer hex 데이터 생성.
팀원들이 testbench 에서 $readmemh 로 BRAM 에 바로 init 할 수 있도록 BRAM 형식과
정확히 일치시킴.

생성 파일 (data/hex_layer_by_layer/):
  1. conv1_input.hex        (784 lines × 8-bit)
     → Conv1 입력 BRAM (1 채널 MNIST raw, 28×28)
     → addr 0..783 sequential, addr = h*28 + w (compact)
     → 1 byte per line (2 hex chars)
     → conv1_engine 의 `in_bram_addr[9:0]` / `in_bram_dout[7:0]` 와 매핑

  2. conv1_output_c1c2.hex  (1024 lines × 64-bit)
     → Conv1 출력 = Conv2 입력 BRAM (c1c2 ping-pong buffer)
     → addr = h*32 + w (padded h, w ∈ [0, 25]), 26~31 zero padding
     → 8 IC × 8b packed: IC 0 = LSB (bits [7:0])
     → 16 hex chars per line (64-bit)
     → conv2_engine 의 c1c2 BMG Port B {bank, row[4:0], col[4:0]} 와 매핑
     → 1 bank 분량 (= 1 image). 다른 bank 는 testbench 가 따로 init.

  3. conv2_output_c2pool.hex (576 lines × 128-bit)
     → Conv2 출력 BRAM (c2pool ping-pong buffer)
     → addr = h*24 + w sequential (compact, no padding — write_addr 순서)
     → 16 OC × 8b packed: OC 0 = LSB
     → 32 hex chars per line (128-bit)
     → conv2_engine 의 c2pool BMG Port A {bank, write_addr[9:0]} 와 매핑

연산 체인 (모든 stage int8 + ReLU 가정):
  MNIST 입력 (int8 [-128, 127])
    → Conv1 (3x3, stride 1, no pad)  →  acc int32  →  >>10  →  clip[-128, 127]  →  ReLU
      → fmap1 int8 [0, 127], shape (8, 26, 26)
    → Conv2 (3x3, stride 1, no pad)  →  acc int32  →  >>10  →  clip[-128, 127]  →  ReLU
      → fmap2 int8 [0, 127], shape (16, 24, 24)

실행:
  cd scripts/header_hex_gen/single_img
  python3 per_image_layer_hex.py            # IMAGE_IDX = 0 (default)
  python3 per_image_layer_hex.py 28         # IMAGE_IDX = 28
"""

import os
import sys
import numpy as np

# ---------------------------------------------------------------------------
# 설정
# ---------------------------------------------------------------------------
IMAGE_IDX = int(sys.argv[1]) if len(sys.argv) > 1 else 0

INPUT_FILE   = "../../data/_base_npy/input.npy"
WEIGHT1_FILE = "../../data/_base_npy/layer1_0_weight.npy"
WEIGHT2_FILE = "../../data/_base_npy/layer2_0_weight.npy"
OUTPUT_DIR   = "../../data/single_img"

# ---------------------------------------------------------------------------
# Conv 함수 (numpy 벡터화)
# ---------------------------------------------------------------------------
def im2col_3x3(x):
    """3x3 stride-1 no-pad im2col. x: (C, H, W) → (oH, oW, C*9)."""
    C, H, W = x.shape
    oH, oW = H - 2, W - 2
    s_c, s_h, s_w = x.strides
    patches = np.lib.stride_tricks.as_strided(
        x,
        shape   = (C, oH, oW, 3, 3),
        strides = (s_c, s_h, s_w, s_h, s_w),
        writeable = False,
    )
    return np.ascontiguousarray(patches.transpose(1, 2, 0, 3, 4).reshape(oH, oW, C * 9))


def conv2d_int8(x_int8, w_int8, shift=10):
    """Conv2d + >>shift + clip[-128, 127] + ReLU. (C, H, W) int8 → (OC, oH, oW) int8."""
    cols   = im2col_3x3(x_int8).astype(np.int32)        # (oH, oW, C*9)
    w_flat = w_int8.reshape(w_int8.shape[0], -1).astype(np.int32)
    acc    = cols @ w_flat.T                            # (oH, oW, OC)
    acc    = acc.transpose(2, 0, 1)                     # (OC, oH, oW)
    shifted = acc >> shift
    sat     = np.clip(shifted, -128, 127).astype(np.int8)
    return np.maximum(sat, 0).astype(np.int8)           # ReLU


# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------
print(f"=== per_image_layer_hex.py — IMAGE_IDX = {IMAGE_IDX} ===")
print(f"[Load] {INPUT_FILE}")
inp = np.load(INPUT_FILE)               # (10000, 1, 28, 28) int8
print(f"[Load] {WEIGHT1_FILE}")
w1 = np.load(WEIGHT1_FILE)              # (8, 1, 3, 3) int8
print(f"[Load] {WEIGHT2_FILE}")
w2 = np.load(WEIGHT2_FILE)              # (16, 8, 3, 3) int8

x0 = inp[IMAGE_IDX]                     # (1, 28, 28) int8

# ---------------------------------------------------------------------------
# Forward
# ---------------------------------------------------------------------------
print(f"\n[Forward] image {IMAGE_IDX}")
fmap1 = conv2d_int8(x0, w1)             # (8, 26, 26) int8
print(f"  Conv1 out: shape={fmap1.shape}, range=[{fmap1.min()}, {fmap1.max()}]")

fmap2 = conv2d_int8(fmap1, w2)          # (16, 24, 24) int8
print(f"  Conv2 out: shape={fmap2.shape}, range=[{fmap2.min()}, {fmap2.max()}]")

# ---------------------------------------------------------------------------
# Hex 출력
# ---------------------------------------------------------------------------
os.makedirs(OUTPUT_DIR, exist_ok=True)

# ---- 1. Conv1 input — 784 × 8-bit (compact h*28+w)
path1 = os.path.join(OUTPUT_DIR, "conv1_input.hex")
with open(path1, "w") as f:
    for h in range(28):
        for w in range(28):
            byte = int(x0[0, h, w]) & 0xFF
            f.write(f"{byte:02X}\n")
print(f"\n[Write] {path1}")
print(f"        784 lines × 8-bit (compact h*28+w)")

# ---- 2. Conv1 output = Conv2 input — 1024 × 64-bit (padded h*32+w, BMG bank format)
path2 = os.path.join(OUTPUT_DIR, "conv1_output_c1c2.hex")
with open(path2, "w") as f:
    for h in range(32):              # padded row (0..31)
        for w in range(32):          # padded col (0..31)
            if h < 26 and w < 26:
                word = 0
                for ic in range(8):
                    byte = int(fmap1[ic, h, w]) & 0xFF
                    word |= (byte << (ic * 8))
                f.write(f"{word:016X}\n")
            else:
                f.write("0000000000000000\n")   # padding
print(f"[Write] {path2}")
print(f"        1024 lines × 64-bit (padded h*32+w, BMG bank format)")
print(f"        8 IC packed; IC 0 = LSB")

# ---- 3. Conv2 output — 576 × 128-bit (compact h*24+w, write_addr 순)
path3 = os.path.join(OUTPUT_DIR, "conv2_output_c2pool.hex")
with open(path3, "w") as f:
    for h in range(24):
        for w in range(24):
            word = 0
            for oc in range(16):
                byte = int(fmap2[oc, h, w]) & 0xFF
                word |= (byte << (oc * 8))
            f.write(f"{word:032X}\n")
print(f"[Write] {path3}")
print(f"        576 lines × 128-bit (compact h*24+w, c2pool write_addr 순)")
print(f"        16 OC packed; OC 0 = LSB")

print(f"\n[Done] image {IMAGE_IDX} 의 3 hex 파일 생성 완료.")
