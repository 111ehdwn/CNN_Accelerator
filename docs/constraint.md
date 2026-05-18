# MNIST CNN 가속기 설계 명세 (v0.1)

## 1. 보드 / 환경

- **보드**: Arty A7-100T (Xilinx XC7A100T)
- **자원**: DSP48E1 240개, BRAM 135 (4.6Mb), LUT 63K, FF 126K
- **개발 환경**: Vivado, Vitis, Pycharm

## 2. 타겟 CNN

```
Input (1, 28, 28) INT8
  ↓ Conv1 (8, 1, 3, 3), stride 1, no pad
Feature Map1 (8, 26, 26)
  ↓ ReLU
  ↓ Conv2 (16, 8, 3, 3), stride 1, no pad
Feature Map2 (16, 24, 24)
  ↓ ReLU
  ↓ MaxPool 2×2
Feature Map3 (16, 12, 12)
  ↓ Flatten (W, H, C order) → 2304
  ↓ FC (2304, 10)
Output Logit (10) → argmax
```

## 3. 과제 명세 (변경 불가)

- Weight: signed INT8 (.npy 제공)
- Activation: signed INT8
- 누적 후 saturation: LSB 10 bit 버림 → ±127 clip → INT8 출력
- PS는 데이터 transfer + start/done control만
- 평가 지표: latency(최우선 과제), power, resource utilization

## 4. 결정 사항
 - Convolution 2 Layer이 병목이므로, 이 부분을 베이스라인에서 Winograd Convolution으로 변경 예정.