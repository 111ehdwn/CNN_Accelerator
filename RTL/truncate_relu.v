`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: truncate_relu
// Description:
//   - adder_tree 출력(24비트)을 INT8로 변환
//   - 순서: >>10 → saturate [-127, 127] → ReLU
//
//   >>10 이유:
//     weight(INT8) × activation(INT8) = INT16
//     quantization scale factor = 2^10 = 1024
//     >> 10으로 소수점 위치 복원
//
//   saturate [-127, 127]:
//     >>10 후 범위 초과 시 클리핑
//     -128 제외 이유: weight에 -128 없으므로 일관성 유지
//
//   ReLU:
//     음수 → 0
//     양수 → 그대로
//
//   레이턴시: 1사이클
//////////////////////////////////////////////////////////////////////////////////

module truncate_relu (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,

    // adder_tree 출력 (24비트 signed) × 4채널
    input  wire signed [23:0] sum0,   // oc_even 묶음1 (oc0 or oc4)
    input  wire signed [23:0] sum1,   // oc_odd  묶음1 (oc1 or oc5)
    input  wire signed [23:0] sum2,   // oc_even 묶음2 (oc2 or oc6)
    input  wire signed [23:0] sum3,   // oc_odd  묶음2 (oc3 or oc7)

    // INT8 출력 × 4채널
    output reg signed [7:0] out0,
    output reg signed [7:0] out1,
    output reg signed [7:0] out2,
    output reg signed [7:0] out3
);

    //==========================================================================
    // >>10 후 값 (24-10 = 14비트면 충분, 16비트로 여유있게)
    //==========================================================================
    wire signed [13:0] shifted0 = sum0 >>> 10;
    wire signed [13:0] shifted1 = sum1 >>> 10;
    wire signed [13:0] shifted2 = sum2 >>> 10;
    wire signed [13:0] shifted3 = sum3 >>> 10;

    //==========================================================================
    // saturate + ReLU 함수
    //   양수  > 127 → 127
    //   음수  < 0   → 0   (ReLU)
    //   그 외        → 그대로
    //==========================================================================
    function signed [7:0] sat_relu;
        input signed [13:0] val;
        begin
            if (val > 14'sd127)
                sat_relu = 8'sd127;
            else if (val < 14'sd0)
                sat_relu = 8'sd0;       // ReLU: 음수 → 0
            else
                sat_relu = val[7:0];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            out0 <= 8'sd0;
            out1 <= 8'sd0;
            out2 <= 8'sd0;
            out3 <= 8'sd0;
        end else if (en) begin
            out0 <= sat_relu(shifted0);
            out1 <= sat_relu(shifted1);
            out2 <= sat_relu(shifted2);
            out3 <= sat_relu(shifted3);
        end
    end

endmodule