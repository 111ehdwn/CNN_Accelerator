"""
conv1_simd_pack.py
==================
Conv1 weight packing — layer1_0_weight.npy → conv1_weights_simd.{hex, h}

Conv1 의 weight loader (`conv1_weight_loader.v`) 가 기대하는 36-entry × 32-bit
BRAM 포맷으로 변환. Conv2 와 packing 식 (W1*2^17 + W0, 25-bit) 은 동일하나
**OC pairing 과 BRAM addr 매핑이 다름** (Conv1 은 1 IC, 2 round 구조).

Conv1 architecture (`conv1_engine_2.v`, `conv1_weight_loader.v`, `conv1_design.md` 참조):
  - 18 PE = 2 group (g1 PE[0..8], g2 PE[9..17]) × 9 PE each
  - 1 group 의 9 PE = 3 KH × 3 KW (PE idx i → kh=i/3, kw=i%3)
  - 각 PE: DEPTH=2 weight register
      w_regs[0] : Round 1 (sel=0) 용
      w_regs[1] : Round 2 (sel=1) 용
  - SIMD pack: 1 PE 가 (W0, W1) = 2 OC 동시 계산 (DSP48E1 한 곱셈)

OC pairing (sel × group):
  +----------+--------------+--------------+
  | round    | g1 (sum0/1)  | g2 (sum0/1)  |
  +----------+--------------+--------------+
  | sel=0    | W0=oc0, W1=oc1 | W0=oc2, W1=oc3 |
  | sel=1    | W0=oc4, W1=oc5 | W0=oc6, W1=oc7 |
  +----------+--------------+--------------+
  공식: oc_w0 = sel*4 + (group-1)*2,  oc_w1 = oc_w0 + 1

BRAM addr layout (weight_loader latch_cnt 순서):
  addr  0.. 8 : g1, sel=0 → 9 PE 각각 packed (W1=oc1, W0=oc0)
  addr  9..17 : g2, sel=0 → 9 PE 각각 packed (W1=oc3, W0=oc2)
  addr 18..26 : g1, sel=1 → 9 PE 각각 packed (W1=oc5, W0=oc4)
  addr 27..35 : g2, sel=1 → 9 PE 각각 packed (W1=oc7, W0=oc6)

Packing 식 (Conv2 와 동일):
  packed_25bit = W1 * 2^17 + W0     (W0, W1 ∈ [-127, 127] 가정, 25-bit 2's complement)
  BRAM word    = packed_25bit       (zero-extend to 32-bit, 상위 7 bit = 0)

  → DSP48E1 A_port (30-bit signed) = sign_ext(packed_25bit)
  → DSP48E1 B_port (18-bit signed) = sign_ext(X[7:0])
  → P = A * B = W1*X*2^17 + W0*X
      mul0 = P[16:0]                  → W0*X
      mul1 = P[33:17] + [P[16]<0]     → W1*X (carry 보정)

실행:
  cd scripts/weights
  python3 conv1_simd_pack.py
"""

import os
import numpy as np

# ---------------------------------------------------------------------------
# 경로
# ---------------------------------------------------------------------------
WEIGHT_FILE = "../../data/_base_npy/layer1_0_weight.npy"
OUTPUT_HEX  = "../../data/weights_simd/conv1_weights_simd.hex"
OUTPUT_H    = "../../data/weights_simd/conv1_weights_simd.h"

# ---------------------------------------------------------------------------
# Conv1 구조 상수
# ---------------------------------------------------------------------------
NUM_PE_PER_GROUP = 9      # 3 KH × 3 KW
NUM_GROUP        = 2      # g1, g2
NUM_ROUND        = 2      # sel=0, sel=1
NUM_ADDR         = NUM_PE_PER_GROUP * NUM_GROUP * NUM_ROUND   # = 36

# ---------------------------------------------------------------------------
# Helper: addr → (group, sel, pe_idx)
# ---------------------------------------------------------------------------
def decode_addr(addr):
    """latch_cnt 순서를 따른 weight_loader 의 addr 해석."""
    if   addr < 9:   return (1, 0, addr)         # g1, sel=0
    elif addr < 18:  return (2, 0, addr - 9)     # g2, sel=0
    elif addr < 27:  return (1, 1, addr - 18)    # g1, sel=1
    else:            return (2, 1, addr - 27)    # g2, sel=1


def oc_pair_for(round_sel, group):
    """sel 과 group 으로 (oc_w0, oc_w1) 결정."""
    base = round_sel * 4 + (group - 1) * 2
    return (base, base + 1)


# ---------------------------------------------------------------------------
# Weight 로드
# ---------------------------------------------------------------------------
w = np.load(WEIGHT_FILE)   # (8, 1, 3, 3) int8
assert w.shape == (8, 1, 3, 3), f"unexpected weight shape: {w.shape}"
assert w.dtype == np.int8,        f"unexpected weight dtype: {w.dtype}"
print(f"[Load] weight shape={w.shape}, dtype={w.dtype}")
print(f"       range = [{int(w.min())}, {int(w.max())}]")
print(f"       count of -128 = {int((w == -128).sum())}   (≥1 이면 SIMD overflow case)")

# ---------------------------------------------------------------------------
# Packing
# ---------------------------------------------------------------------------
MASK_25 = (1 << 25) - 1

packed   = [0] * NUM_ADDR
ovf_cnt  = 0

# 모든 (oc, kh, kw) 가 정확히 1번씩 사용되었는지 검증
usage = np.zeros((8, 3, 3), dtype=int)

for addr in range(NUM_ADDR):
    group, round_sel, pe_idx = decode_addr(addr)
    kh, kw = pe_idx // 3, pe_idx % 3
    oc_w0, oc_w1 = oc_pair_for(round_sel, group)

    W0 = int(w[oc_w0, 0, kh, kw])
    W1 = int(w[oc_w1, 0, kh, kw])

    a_port_int = W1 * (1 << 17) + W0
    pattern_25 = a_port_int & MASK_25
    packed[addr] = pattern_25

    usage[oc_w0, kh, kw] += 1
    usage[oc_w1, kh, kw] += 1

    if W1 == -128 and W0 < 0:
        ovf_cnt += 1

assert (usage == 1).all(), f"weight coverage broken: usage=\n{usage}"
print(f"[Pack] entries={NUM_ADDR}, coverage OK (8 OC × 3 KH × 3 KW = 72 weights, 모두 1회 사용)")
print(f"[Pack] SIMD overflow case (W1=-128 && W0<0): {ovf_cnt}/{NUM_ADDR}")
print(f"[Pack] sample[0..3] = {[f'0x{v:08X}' for v in packed[:4]]}")

# ---------------------------------------------------------------------------
# Hex 출력 (32-bit / line, 8 hex chars, uppercase)
# ---------------------------------------------------------------------------
os.makedirs(os.path.dirname(OUTPUT_HEX), exist_ok=True)
with open(OUTPUT_HEX, "w") as f:
    for v in packed:
        f.write(f"{v:08X}\n")
print(f"[Write] {OUTPUT_HEX}  ({NUM_ADDR} lines, {NUM_ADDR * 4} bytes)")

# ---------------------------------------------------------------------------
# C 헤더 출력
# ---------------------------------------------------------------------------
guard = "CONV1_WEIGHTS_SIMD_H"
lines = []
lines.append(f"#ifndef {guard}")
lines.append(f"#define {guard}")
lines.append("")
lines.append("#include <stdint.h>")
lines.append("")
lines.append(f"// auto-generated by scripts/weights/conv1_simd_pack.py")
lines.append(f"// source weight : layer1_0_weight.npy  shape=(8, 1, 3, 3) int8")
lines.append(f"// architecture  : 18 PE = 2 group (g1/g2) × 9 PE (3 KH × 3 KW),")
lines.append(f"//                 each PE: DEPTH=2 weight reg (sel=0/1 = round 1/2)")
lines.append(f"// OC pairing    : (sel, group) → (oc_w0, oc_w1)")
lines.append(f"//                   (0, 1)→(0, 1)  (0, 2)→(2, 3)")
lines.append(f"//                   (1, 1)→(4, 5)  (1, 2)→(6, 7)")
lines.append(f"// addr layout   :  0.. 8 = g1 sel=0 PE[0..8]")
lines.append(f"//                  9..17 = g2 sel=0 PE[0..8]")
lines.append(f"//                 18..26 = g1 sel=1 PE[0..8]")
lines.append(f"//                 27..35 = g2 sel=1 PE[0..8]")
lines.append(f"//                 PE idx i → (kh, kw) = (i/3, i%3)")
lines.append(f"// element       : A_port = W1*2^17 + W0  (25-bit 2's complement)")
lines.append(f"//                 zero-extended to 32-bit (MSB 7 bits = 0)")
lines.append("")
lines.append(f"#define CONV1_SIMD_NUM_PE_PER_GROUP  {NUM_PE_PER_GROUP}")
lines.append(f"#define CONV1_SIMD_NUM_GROUP         {NUM_GROUP}")
lines.append(f"#define CONV1_SIMD_NUM_ROUND         {NUM_ROUND}")
lines.append(f"#define CONV1_SIMD_LEN               {NUM_ADDR}")
lines.append("")
lines.append(f"static const uint32_t conv1_weights_simd[CONV1_SIMD_LEN] = {{")

# 한 줄에 4개씩 (가독성)
PER_LINE = 4
for i in range(0, NUM_ADDR, PER_LINE):
    chunk = packed[i:i + PER_LINE]
    body  = ", ".join(f"0x{v:08X}u" for v in chunk)
    comma = "," if i + PER_LINE < NUM_ADDR else ""
    lines.append(f"    {body}{comma}")

lines.append("};")
lines.append("")
lines.append(f"#endif // {guard}")
lines.append("")

with open(OUTPUT_H, "w") as f:
    f.write("\n".join(lines))
print(f"[Write] {OUTPUT_H}")

# ===========================================================================
# Verification — SIMD decode 가 expected W0*X, W1*X 와 일치하는지 exhaustive 검증
# ===========================================================================
def simd_decode(aport_25bit, x_8bit):
    """DSP48E1 의 25×18 signed multiplication 및 mul0/mul1 추출 모델."""
    # 25-bit signed
    aport_signed = aport_25bit - (1 << 25) if aport_25bit & (1 << 24) else aport_25bit
    # 8-bit signed (X)
    x_signed = x_8bit - 256 if x_8bit & 0x80 else x_8bit

    p = aport_signed * x_signed

    # mul0 = P[16:0] (17-bit signed)
    mul0_bits = p & 0x1FFFF
    mul0 = mul0_bits - 0x20000 if mul0_bits & 0x10000 else mul0_bits

    # mul1 = P[32:17] (16-bit signed) + carry [P[16]<0]
    mul1_bits = (p >> 17) & 0xFFFF
    mul1 = mul1_bits - 0x10000 if mul1_bits & 0x8000 else mul1_bits
    if mul0 < 0:
        mul1 += 1

    return mul0, mul1


print("\n[Verify] exhaustive SIMD packing test ...")
for w0 in range(-127, 128):
    for w1 in range(-127, 128):
        aport = (w1 * (1 << 17) + w0) & MASK_25
        for x in range(-128, 128):
            mul0, mul1 = simd_decode(aport, x & 0xFF)
            assert mul0 == w0 * x, f"FAIL mul0: W0={w0}, W1={w1}, X={x} → got {mul0} expected {w0*x}"
            assert mul1 == w1 * x, f"FAIL mul1: W0={w0}, W1={w1}, X={x} → got {mul1} expected {w1*x}"

print(f"[Verify] PASS — 254 × 254 × 256 = {254*254*256} cases all match")
print(f"\n[Done] Conv1 weight packing 완료.")
