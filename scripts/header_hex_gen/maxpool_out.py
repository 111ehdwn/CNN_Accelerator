import numpy as np

# -------------------------------------------------------
# 파일 경로 설정 (프로젝트 루트에서 실행한다고 가정)
# -------------------------------------------------------
INPUT_FILE   = "../../data/npy/input.npy"
WEIGHT1_FILE = "../../data/npy/layer1_0_weight.npy"
WEIGHT2_FILE = "../../data/npy/layer2_0_weight.npy"
OUTPUT_HEX   = "../../data/hex_layer_by_layer/maxpool_output.hex"

# -------------------------------------------------------
# 파일 로드
# -------------------------------------------------------
inp     = np.load(INPUT_FILE)    # (N, 1, 28, 28), int8
weight1 = np.load(WEIGHT1_FILE)  # (8, 1, 3, 3),   int8
weight2 = np.load(WEIGHT2_FILE)  # (16, 8, 3, 3),  int8

print(f"[Load] input shape   : {inp.shape},       dtype={inp.dtype}")
print(f"[Load] weight1 shape : {weight1.shape},   dtype={weight1.dtype}")
print(f"[Load] weight2 shape : {weight2.shape},   dtype={weight2.dtype}")

# -------------------------------------------------------
# 첫 번째 이미지 선택
# -------------------------------------------------------
IMAGE_IDX = 0
x = inp[IMAGE_IDX]  # (1, 28, 28)
print(f"\n[Select] image index={IMAGE_IDX}, shape={x.shape}")

# -------------------------------------------------------
# ========== Conv1 Pipeline ==========
# -------------------------------------------------------
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

shifted1   = conv1_out >> 10
saturated1 = np.clip(shifted1, -128, 127).astype(np.int8)
relu1      = np.maximum(saturated1.astype(np.int32), 0).astype(np.int8)
print(f"[ReLU1]       shape={relu1.shape}  min={relu1.min()}  max={relu1.max()}")

# -------------------------------------------------------
# ========== Conv2 Pipeline ==========
# -------------------------------------------------------
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

shifted2   = conv2_out >> 10
saturated2 = np.clip(shifted2, -128, 127).astype(np.int8)
relu2      = np.maximum(saturated2.astype(np.int32), 0).astype(np.int8)
print(f"[ReLU2]       shape={relu2.shape}  min={relu2.min()}  max={relu2.max()}")

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
print(f"              총 원소 수 = {pooled.size}  ({pC}ch × {pH_out} × {pW_out})")

# -------------------------------------------------------
# 결과 hex 파일 출력 (1바이트씩, 2자리 hex, unsigned 표현)
# -------------------------------------------------------
with open(OUTPUT_HEX, "w") as f:
    for b in pooled.flatten().tobytes():
        f.write(f"{b:02X}\n")

print(f"\n출력 완료 → {OUTPUT_HEX}  ({pooled.size} entries, shape={pooled.shape})")