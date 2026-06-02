"""
gen_single_img_hex.py
=====================
단일 이미지(IMAGE_IDX)의 전체 layer hex + fc golden 을 한 번의 forward 로 생성.
(기존 per_image_layer_hex.py + maxpool_out.py + fc_out.py 를 하나로 통합)

생성 (data/single_img/):
  conv1_input.hex          784  x 8-bit   (h*28+w)
  conv1_output_c1c2.hex    1024 x 64-bit  (padded h*32+w, 8 IC packed, IC0=LSB)
  conv2_output_c2pool.hex  576  x 128-bit (h*24+w, 16 OC packed, OC0=LSB)
  maxpool_output.hex       2304 x 8-bit   (channel-major flatten, fc/maxpool TB 입력)
  fc_output.hex            10   x 8-bit   (fc1_sat 최종 예측)
  + fc golden logit (24-bit raw) / pred class 를 stdout 으로 출력 (TB EXP_OC 참고용)

연산 체인 (모든 stage int8 + ReLU): Conv1 -> Conv2 -> MaxPool2x2 -> FC
  acc int32 -> >>10 -> clip[-128,127] -> ReLU  (conv 공통)

실행: python3 scripts/single_img/gen_single_img_hex.py [IMAGE_IDX]   (어디서 실행해도 동작)
"""
import os
import sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
def npy(f): return os.path.join(HERE, "../../data/_base_npy", f)
OUT = os.path.join(HERE, "../../data/single_img")

IMAGE_IDX = int(sys.argv[1]) if len(sys.argv) > 1 else 0

# ---------------------------------------------------------------------------
# Conv (numpy 벡터화, single image)
# ---------------------------------------------------------------------------
def im2col_3x3(x):                              # (C,H,W) -> (oH,oW,C*9)
    C, H, W = x.shape
    oH, oW = H - 2, W - 2
    sc, sh, sw = x.strides
    p = np.lib.stride_tricks.as_strided(
        x, (C, oH, oW, 3, 3), (sc, sh, sw, sh, sw), writeable=False)
    return np.ascontiguousarray(p.transpose(1, 2, 0, 3, 4).reshape(oH, oW, C * 9))

def conv2d_int8(x, w, shift=10):                # >>shift -> clip -> ReLU
    cols = im2col_3x3(x).astype(np.int32)
    acc  = cols @ w.reshape(w.shape[0], -1).astype(np.int32).T   # (oH,oW,OC)
    acc  = acc.transpose(2, 0, 1)                                # (OC,oH,oW)
    return np.maximum(np.clip(acc >> shift, -128, 127).astype(np.int8), 0).astype(np.int8)

# ---------------------------------------------------------------------------
# Load + forward
# ---------------------------------------------------------------------------
inp = np.load(npy("input.npy"))                 # (N,1,28,28) int8
w1  = np.load(npy("layer1_0_weight.npy"))       # (8,1,3,3)
w2  = np.load(npy("layer2_0_weight.npy"))       # (16,8,3,3)
fc1 = np.load(npy("fc1_weight.npy")).astype(np.int32)   # (10,2304)

x0 = inp[IMAGE_IDX]                             # (1,28,28)
print(f"=== gen_single_img_hex — IMAGE_IDX={IMAGE_IDX} ===")
fmap1  = conv2d_int8(x0,    w1)                 # (8,26,26)
fmap2  = conv2d_int8(fmap1, w2)                 # (16,24,24)
pooled = fmap2.reshape(16, 12, 2, 12, 2).max(axis=(2, 4)).astype(np.int8)  # (16,12,12)
print(f"  conv1 {fmap1.shape} [{fmap1.min()},{fmap1.max()}]  "
      f"conv2 {fmap2.shape} [{fmap2.min()},{fmap2.max()}]  "
      f"pool {pooled.shape} [{pooled.min()},{pooled.max()}]")

flat    = pooled.flatten().astype(np.int32)    # (2304,) channel-major (c*144 + h*12+w)
fc1_out = fc1 @ flat                            # (10,) raw 24-bit logit
fc1_sat = np.clip(fc1_out >> 10, -128, 127).astype(np.int8)
pred    = int(np.argmax(fc1_sat))

# ---------------------------------------------------------------------------
# Hex 출력
# ---------------------------------------------------------------------------
os.makedirs(OUT, exist_ok=True)

# 1. conv1_input.hex  — 784 x 8-bit (h*28+w)
with open(os.path.join(OUT, "conv1_input.hex"), "w") as f:
    for h in range(28):
        for w in range(28):
            f.write(f"{int(x0[0, h, w]) & 0xFF:02X}\n")

# 2. conv1_output_c1c2.hex — 1024 x 64-bit (padded h*32+w, 8 IC packed, IC0=LSB)
with open(os.path.join(OUT, "conv1_output_c1c2.hex"), "w") as f:
    for h in range(32):
        for w in range(32):
            if h < 26 and w < 26:
                word = 0
                for ic in range(8):
                    word |= (int(fmap1[ic, h, w]) & 0xFF) << (ic * 8)
                f.write(f"{word:016X}\n")
            else:
                f.write("0000000000000000\n")

# 3. conv2_output_c2pool.hex — 576 x 128-bit (h*24+w, 16 OC packed, OC0=LSB)
with open(os.path.join(OUT, "conv2_output_c2pool.hex"), "w") as f:
    for h in range(24):
        for w in range(24):
            word = 0
            for oc in range(16):
                word |= (int(fmap2[oc, h, w]) & 0xFF) << (oc * 8)
            f.write(f"{word:032X}\n")

# 4. maxpool_output.hex — 2304 x 8-bit (channel-major flatten; fc/maxpool TB 입력)
with open(os.path.join(OUT, "maxpool_output.hex"), "w") as f:
    for b in pooled.flatten().tobytes():
        f.write(f"{b:02X}\n")

# 5. fc_output.hex — 10 x 8-bit (fc1_sat 최종 예측)
with open(os.path.join(OUT, "fc_output.hex"), "w") as f:
    for b in fc1_sat.tobytes():
        f.write(f"{b:02X}\n")

print(f"[fc golden] logit(24b) = {fc1_out.tolist()}")
print(f"[fc golden] pred class = {pred}")
print(f"[done] 5 hex (+fc golden) -> {OUT}")
