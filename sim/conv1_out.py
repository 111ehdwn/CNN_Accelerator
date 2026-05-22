import numpy as np
import os

# -------------------------------------------------------
# 파일 경로 설정 (npy 파일과 같은 디렉토리, 또는 직접 수정)
# -------------------------------------------------------
INPUT_FILE  = "input.npy"
WEIGHT_FILE = "layer1_0_weight.npy"
OUTPUT_HEX  = "conv1_output_processed.hex"

# -------------------------------------------------------
# 파일 로드
# -------------------------------------------------------
inp    = np.load(INPUT_FILE)   # (N, 1, 28, 28), int8
weight = np.load(WEIGHT_FILE)  # (8, 1, 3, 3),   int8

print(f"[Load] input shape  : {inp.shape},    dtype={inp.dtype}")
print(f"[Load] weight shape : {weight.shape}, dtype={weight.dtype}")

# -------------------------------------------------------
# 첫 번째 이미지 선택
# -------------------------------------------------------
IMAGE_IDX = 0
x = inp[IMAGE_IDX]  # (1, 28, 28)
print(f"[Select] image index={IMAGE_IDX}, shape={x.shape}")

# -------------------------------------------------------
# Step 1: Conv2D  (padding=0, stride=1)
# -------------------------------------------------------
out_ch, in_ch, kH, kW = weight.shape
H, W = x.shape[1], x.shape[2]
oH = H - kH + 1
oW = W - kW + 1

conv_out = np.zeros((out_ch, oH, oW), dtype=np.int32)
for oc in range(out_ch):
    for ic in range(in_ch):
        for i in range(oH):
            for j in range(oW):
                patch = x[ic, i:i+kH, j:j+kW].astype(np.int32)
                k     = weight[oc, ic].astype(np.int32)
                conv_out[oc, i, j] += np.sum(patch * k)

print(f"[Conv]        shape={conv_out.shape}  min={conv_out.min()}  max={conv_out.max()}")

# -------------------------------------------------------
# Step 2: LSB 10bit 제거 (arithmetic right shift by 10)
# -------------------------------------------------------
shifted = conv_out >> 10
print(f"[>> 10]       min={shifted.min()}  max={shifted.max()}")

# -------------------------------------------------------
# Step 3: Saturation → int8 (-128 ~ 127)
# -------------------------------------------------------
saturated = np.clip(shifted, -128, 127).astype(np.int8)
print(f"[Saturation]  min={saturated.min()}  max={saturated.max()}")

# -------------------------------------------------------
# Step 4: ReLU
# -------------------------------------------------------
relu_out = np.maximum(saturated.astype(np.int32), 0).astype(np.int8)
print(f"[ReLU]        min={relu_out.min()}  max={relu_out.max()}")

# -------------------------------------------------------
# 결과 hex 파일 출력 (1바이트씩, 2자리 hex)
# -------------------------------------------------------
with open(OUTPUT_HEX, "w") as f:
    for b in relu_out.flatten().tobytes():
        f.write(f"{b:02X}\n")

print(f"\n출력 완료 → {OUTPUT_HEX}  ({relu_out.size} entries, shape={relu_out.shape})")