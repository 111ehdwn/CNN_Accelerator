`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: truncate_relu
// Description:
//   - IC adder tree 출력(24비트 signed)을 INT8로 변환 (양자화 후처리)
//   - 처리 순서: arithmetic right shift >>> 10  →  saturate [-128, 127]  →  ReLU
//
//   비트 폭 분석:
//     mul (PE 출력):         signed 17-bit  (= [-128]×[-127] ~ 127×127)
//     K_row sum (3 누적):    signed 19-bit  (17 + log2(3))
//     K_col accum (3 cycle): signed 21-bit  (19 + log2(3))
//     IC sum (8 누적):       signed 24-bit  (21 + log2(8))
//     → 입력 sum 폭: 24-bit
//
//   >>> 10의 이유:
//     weight, activation 모두 INT8 quantized (scale factor = 2^10)
//     곱셈 후 누적 결과를 다시 INT8 scale로 복원하려면 >>> 10 필요
//     >>> 10 후 범위: 24 - 10 = 14-bit signed
//
//   Saturation [-128, 127]:
//     >>> 10 후 14-bit이 8-bit signed 범위 [-128, 127] 초과 시 클리핑
//     양수 > 127 → 127
//     음수 < -128 → -128 (단, 직후 ReLU로 0이 되므로 사실상 의미 없음)
//
//   ReLU:
//     음수 → 0 (활성화 함수)
//     양수 → 그대로
//     → 최종 출력 범위: [0, 127]
//
//   Layer별 재사용:
//     Conv1: N=4 (OC_pair=2 × SIMD=2)
//     Conv2: N=16 (OC_pair=8 × SIMD=2)
//
//   Latency: 1 cycle (input sum → output out)
//
//   write_done 등 control 신호:
//     이 모듈은 순수 datapath. 상위 fsm에서 처리.
//////////////////////////////////////////////////////////////////////////////////

module truncate_relu #(
    // 동시 출력 채널 수 (Conv1=4(2회 time mx, 총 8 OC), Conv2=16)
    parameter integer N = 4
)(
    input  wire                clk,
    input  wire                rst,         // active-high synchronous reset
    input  wire                en,          // 1이면 매 cycle 변환 진행

    //==========================================================================
    // 입력: IC adder tree 출력
    //   - N개 채널, 각 24-bit signed (packed 1D array)
    //   - 채널 i의 sum: sum_flat[i*24 +: 24]
    //==========================================================================
    input  wire [N*24-1:0]     sum_flat,

    //==========================================================================
    // 출력: 양자화 + ReLU 적용된 INT8
    //   - N개 채널, 각 8-bit signed (packed 1D array)
    //   - 채널 i의 out: out_flat[i*8 +: 8]
    //==========================================================================
    output reg  [N*8-1:0]      out_flat
);

    //==========================================================================
    // 1. sat_relu function
    //    - 14-bit signed 입력을 받아 INT8로 변환
    //    - saturate [-128, 127] 후 ReLU 적용
    //
    //    구현 노트:
    //      - 입력 val이 14-bit signed (>>> 10 후 폭)
    //      - 14'sd127, 14'sd0 같은 signed literal 사용해 비교 정확성 보장
    //      - val < 0 분기에서 ReLU와 음수 saturation이 동시에 처리됨
    //        (어차피 ReLU 때문에 음수 → 0이므로 -128 saturation 별도 불필요)
    //==========================================================================
    function signed [7:0] sat_relu;
        input signed [13:0] val;
        begin
            if (val > 14'sd127)
                sat_relu = 8'sd127;         // 양수 saturation
            else if (val < 14'sd0)
                sat_relu = 8'sd0;           // ReLU + 음수 saturation (통합 처리)
            else
                sat_relu = val[7:0];        // 0 ~ 127 범위 그대로
        end
    endfunction

    //==========================================================================
    // 2. 채널별 처리 (N개 generate)
    //
    //    각 채널마다:
    //      (a) sum_flat에서 24-bit slice 추출
    //      (b) >>> 10 (arithmetic right shift) → 14-bit signed
    //      (c) sat_relu function 적용 → 8-bit signed
    //      (d) 출력 register에 latch (en일 때)
    //
    //    generate 내부에 always 블록 사용 (Verilog-2001 합법)
    //==========================================================================
    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : ch

            // (a) 입력 slice 추출
            wire signed [23:0] sum_i = sum_flat[i*24 +: 24];

            // (b) arithmetic right shift by 10
            //     - signed 키워드로 부호 유지하며 shift
            //     - 결과 폭: 24 - 10 = 14-bit
            wire signed [13:0] shifted_i = sum_i >>> 10;

            // (c) + (d) saturate + ReLU + 출력 register
            always @(posedge clk) begin
                if (rst)
                    out_flat[i*8 +: 8] <= 8'sd0;
                else if (en)
                    out_flat[i*8 +: 8] <= sat_relu(shifted_i);
            end

        end
    endgenerate

endmodule
