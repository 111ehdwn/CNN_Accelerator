"""
gen_test_images_only.py
=======================
vitis/test_images.h (N images) **만** 생성 — HW latency baseline (예: N=10000) 용.

gen_multi_img_hex.py 는 TB용 거대 all_*.hex (10000장이면 ~수백MB·수분) 까지 쓰므로,
실보드 run 에 필요한 test_images.h (pre-packed uint32 + argmax label) 만 빠르게 뽑는 헬퍼.
forward 는 배치(메모리 절약), input packing 은 벡터화(little-endian uint8→uint32 view).

데이터/포맷은 gen_multi_img_hex.py 의 write_test_images_header 와 동일:
  test_images[N*196] uint32 : word k = b[4k] | b[4k+1]<<8 | b[4k+2]<<16 | b[4k+3]<<24
  test_labels[N]     uint8  : argmax(raw FC logit) = HW fc_argmax 기대 class

사용:
  cd scripts/multi_img
  python3 gen_test_images_only.py [N]        # default N=10000
"""
import os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
D    = os.path.join(HERE, "../../data/_base_npy")
INP  = os.path.join(D, "input.npy")
W1F  = os.path.join(D, "layer1_0_weight.npy")
W2F  = os.path.join(D, "layer2_0_weight.npy")
FC1F = os.path.join(D, "fc1_weight.npy")
OUT  = os.path.join(HERE, "../../vitis/test_images.h")

N     = int(sys.argv[1]) if len(sys.argv) > 1 else 10000
BATCH = 1000


def im2col_3x3(x):
    n, C, H, W = x.shape
    oH, oW = H - 2, W - 2
    sn, sc, sh, sw = x.strides
    p = np.lib.stride_tricks.as_strided(
        x, (n, C, oH, oW, 3, 3), (sn, sc, sh, sw, sh, sw), writeable=False)
    return np.ascontiguousarray(p.transpose(0, 2, 3, 1, 4, 5).reshape(n, oH, oW, C * 9))


def conv(x, w, shift=10):
    cols = im2col_3x3(x).astype(np.int32)
    wf   = w.reshape(w.shape[0], -1).astype(np.int32)
    acc  = (cols @ wf.T).transpose(0, 3, 1, 2)
    return np.maximum(np.clip(acc >> shift, -128, 127).astype(np.int8), 0).astype(np.int8)


def maxpool_2x2(x):
    n, C, H, W = x.shape
    return x.reshape(n, C, H // 2, 2, W // 2, 2).max(axis=(3, 5)).astype(np.int8)


# ---- load ----
inp = np.load(INP)
w1, w2 = np.load(W1F), np.load(W2F)
fc1 = np.load(FC1F).astype(np.int32)
print(f"[load] input {inp.shape} {inp.dtype}, N={N}")
assert inp.shape[0] >= N and inp.shape[1:] == (1, 28, 28), f"input shape {inp.shape}"
assert w1.shape == (8, 1, 3, 3) and w2.shape == (16, 8, 3, 3) and fc1.shape == (10, 2304)

# ---- labels: batched forward (conv1→conv2→maxpool→fc → argmax raw logit) ----
labels = np.empty(N, np.int64)
for s in range(0, N, BATCH):
    e  = min(s + BATCH, N)
    f3 = maxpool_2x2(conv(conv(inp[s:e], w1), w2))                 # (b,16,12,12)
    logit = f3.reshape(e - s, 16 * 144).astype(np.int32) @ fc1.T   # (b,10) col=c*144+h*12+w
    labels[s:e] = np.argmax(logit, axis=1)
    print(f"  forward {e}/{N}")

# ---- test_images: vectorized little-endian pack (N,784)uint8 → (N,196)uint32 ----
words = np.ascontiguousarray(inp[:N, 0].reshape(N, 784).astype(np.uint8)).view(np.uint32)
assert words.shape == (N, 196)

# ---- write header ----
print("[write] building test_images.h ...")
flat = words.reshape(-1).tolist()          # python ints → fast formatting
lab  = labels.tolist()
out = ["#ifndef TEST_IMAGES_H", "#define TEST_IMAGES_H", "", "#include <stdint.h>", "",
       f"// auto-generated (N={N}, HW-baseline header-only) by gen_test_images_only.py",
       f"#define TEST_N_IMAGES {N}",
       "#define TEST_IMG_WORDS 196   /* 784 byte / 4 */", "",
       "static const uint32_t test_images[TEST_N_IMAGES * TEST_IMG_WORDS] = {"]
out += ["    " + "".join(f"0x{v:08X}u," for v in flat[off:off + 16])
        for off in range(0, len(flat), 16)]
out += ["};", "", "static const uint8_t test_labels[TEST_N_IMAGES] = {"]
out += ["    " + "".join(f"{v}," for v in lab[off:off + 40]) for off in range(0, N, 40)]
out += ["};", "", "#endif /* TEST_IMAGES_H */"]

with open(OUT, "w") as f:
    f.write("\n".join(out) + "\n")
print(f"[done] {OUT}  N={N}  size={os.path.getsize(OUT)//1024}KB  labels[:10]={lab[:10]}")
