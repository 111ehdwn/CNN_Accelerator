import numpy as np

# -------------------------------------------------------
# 파일 경로 설정 (npy 파일과 같은 디렉토리, 또는 직접 수정)
# -------------------------------------------------------
INPUT_FILE   = "input.npy"
WEIGHT1_FILE = "layer1_0_weight.npy"
WEIGHT2_FILE = "layer2_0_weight.npy"
OUTPUT_HEX   = "conv2_output_processed.hex"

# -------------------------------------------------------
# 파일 로드
# -------------------------------------------------------
inp     = np.load(INPUT_FILE)    # (N, 1, 28, 28), int8
weight1 = np.load(WEIGHT1_FILE)  # (8, 1, 3, 3),   int8
weight2 = np.load(WEIGHT2_FILE)  # (16, 8, 3, 3),  int8

print(f"[Load] input shape   : {inp.shape},       dtype={inp.dtype}")
print(f"[Load] weight1 shape : {weight1.shape},   dtype={weight1.dtype}")
print(f"[Load] weight2 shape : {weight2.shape}, dtype={weight2.dtype}")

# -------------------------------------------------------
# 첫 번째 이미지 선택
# -------------------------------------------------------
IMAGE_IDX = 0
x = inp[IMAGE_IDX]  # (1, 28, 28)
print(f"\n[Select] image index={IMAGE_IDX}, shape={x.shape}")

# -------------------------------------------------------
# ========== Conv1 Pipeline ==========
# -------------------------------------------------------

# Step 1-1: Conv2D (padding=0, stride=1)
out_ch, in_ch, kH, kW = weight1.shape
H, W = x.shape[1], x.shape[2]
oH, oW = H - kH + 1, W - kW + 1  # 26, 26

conv1_out = np.zeros((out_ch, oH, oW), dtype=np.int32)
for oc in range(out_ch):
    for ic in range(in_ch):
        for i in range(oH):
            for j in range(oW):
                patch = x[ic, i:i+kH, j:j+kW].astype(np.int32)
                k     = weight1[oc, ic].astype(np.int32)
                conv1_out[oc, i, j] += np.sum(patch * k)

print(f"\n[Conv1]       shape={conv1_out.shape}  min={conv1_out.min()}  max={conv1_out.max()}")

# Step 1-2: >> 10
shifted1 = conv1_out >> 10
print(f"[>> 10]       min={shifted1.min()}  max={shifted1.max()}")

# Step 1-3: Saturation
saturated1 = np.clip(shifted1, -128, 127).astype(np.int8)
print(f"[Saturation]  min={saturated1.min()}  max={saturated1.max()}")

# Step 1-4: ReLU
relu1 = np.maximum(saturated1.astype(np.int32), 0).astype(np.int8)
print(f"[ReLU]        min={relu1.min()}  max={relu1.max()}")

# -------------------------------------------------------
# ========== Conv2 Pipeline ==========
# -------------------------------------------------------

# Step 2-1: Conv2D (padding=0, stride=1)
out_ch2, in_ch2, kH2, kW2 = weight2.shape
H2, W2 = relu1.shape[1], relu1.shape[2]
oH2, oW2 = H2 - kH2 + 1, W2 - kW2 + 1  # 24, 24

conv2_out = np.zeros((out_ch2, oH2, oW2), dtype=np.int32)
for oc in range(out_ch2):
    for ic in range(in_ch2):
        for i in range(oH2):
            for j in range(oW2):
                patch = relu1[ic, i:i+kH2, j:j+kW2].astype(np.int32)
                k     = weight2[oc, ic].astype(np.int32)
                conv2_out[oc, i, j] += np.sum(patch * k)

print(f"\n[Conv2]       shape={conv2_out.shape}  min={conv2_out.min()}  max={conv2_out.max()}")

# Step 2-2: >> 10
shifted2 = conv2_out >> 10
print(f"[>> 10]       min={shifted2.min()}  max={shifted2.max()}")

# Step 2-3: Saturation
saturated2 = np.clip(shifted2, -128, 127).astype(np.int8)
print(f"[Saturation]  min={saturated2.min()}  max={saturated2.max()}")

# Step 2-4: ReLU
relu2 = np.maximum(saturated2.astype(np.int32), 0).astype(np.int8)
print(f"[ReLU]        min={relu2.min()}  max={relu2.max()}")

# -------------------------------------------------------
# 결과 hex 파일 출력 (1바이트씩, 2자리 hex)
# -------------------------------------------------------
with open(OUTPUT_HEX, "w") as f:
    for b in relu2.flatten().tobytes():
        f.write(f"{b:02X}\n")

print(f"\n출력 완료 → {OUTPUT_HEX}  ({relu2.size} entries, shape={relu2.shape})")