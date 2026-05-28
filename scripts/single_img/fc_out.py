import numpy as np

# -------------------------------------------------------
# 파일 경로 설정 (프로젝트 루트에서 실행한다고 가정)
# -------------------------------------------------------
INPUT_FILE   = "../../data/_base_npy/input.npy"
WEIGHT1_FILE = "../../data/_base_npy/layer1_0_weight.npy"
WEIGHT2_FILE = "../../data/_base_npy/layer2_0_weight.npy"
FC1_FILE     = "../../data/_base_npy/fc1_weight.npy"
OUTPUT_HEX   = "../../data/single_img/fc_output.hex"

# -------------------------------------------------------
# 파일 로드
# -------------------------------------------------------
inp     = np.load(INPUT_FILE)    # (N, 1, 28, 28), int8
weight1 = np.load(WEIGHT1_FILE)  # (8, 1, 3, 3),   int8
weight2 = np.load(WEIGHT2_FILE)  # (16, 8, 3, 3),  int8
fc1_w   = np.load(FC1_FILE)      # (10, 2304),      int8

print(f"[Load] input shape   : {inp.shape},       dtype={inp.dtype}")
print(f"[Load] weight1 shape : {weight1.shape},   dtype={weight1.dtype}")
print(f"[Load] weight2 shape : {weight2.shape},   dtype={weight2.dtype}")
print(f"[Load] fc1_w   shape : {fc1_w.shape},     dtype={fc1_w.dtype}")

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
# ========== MaxPool2D (2x2, stride=2) ==========
# -------------------------------------------------------
pC, pH, pW = relu2.shape       # (16, 24, 24)
pH_out = pH // 2               # 12
pW_out = pW // 2               # 12

pooled = np.zeros((pC, pH_out, pW_out), dtype=np.int8)
for c in range(pC):
    for i in range(pH_out):
        for j in range(pW_out):
            patch = relu2[c, i*2:i*2+2, j*2:j*2+2].astype(np.int32)
            pooled[c, i, j] = np.max(patch)

print(f"\n[MaxPool2D]   shape={pooled.shape}  min={pooled.min()}  max={pooled.max()}")

# -------------------------------------------------------
# ========== Flatten ==========
# -------------------------------------------------------
flat = pooled.flatten().astype(np.int32)   # (2304,)
print(f"\n[Flatten]     shape={flat.shape}  min={flat.min()}  max={flat.max()}")

# -------------------------------------------------------
# ========== FC1 (Linear: 2304 → 10) ==========
# -------------------------------------------------------
# fc1_w: (10, 2304) int8
fc1_out = fc1_w.astype(np.int32) @ flat   # (10,), int32
print(f"\n[FC1 raw]     shape={fc1_out.shape}  min={fc1_out.min()}  max={fc1_out.max()}")

# Step: >> 10
fc1_shifted = fc1_out >> 10
print(f"[>> 10]       min={fc1_shifted.min()}  max={fc1_shifted.max()}")

# Step: Saturation → int8
fc1_sat = np.clip(fc1_shifted, -128, 127).astype(np.int8)
print(f"[Saturation]  min={fc1_sat.min()}  max={fc1_sat.max()}")

# -------------------------------------------------------
# 예측 클래스 출력
# -------------------------------------------------------
pred_class = int(np.argmax(fc1_sat))
print(f"\n[Result] predicted class = {pred_class}")
print(f"[Result] fc1_sat values  = {fc1_sat}")

# -------------------------------------------------------
# 결과 hex 파일 출력 (1바이트씩, 2자리 hex, unsigned 표현)
# -------------------------------------------------------
with open(OUTPUT_HEX, "w") as f:
    for b in fc1_sat.flatten().tobytes():
        f.write(f"{b:02X}\n")

print(f"\n출력 완료 → {OUTPUT_HEX}  ({fc1_sat.size} entries, shape={fc1_sat.shape})")