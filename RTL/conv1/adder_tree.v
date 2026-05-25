`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: adder_tree
// Description:
//   - pe_cell 9개의 psum을 1사이클에 합산
//   - 입력: psum0[0~8] (W0×X), psum1[0~8] (W1×X) 각 17비트 signed
//   - 출력: sum0 (oc_even), sum1 (oc_odd) 각 24비트 signed
//
//   비트 성장:
//     psum 1개 최대: 127×128 = 16256 → 17비트
//     9개 합산 최대: 16256×9 = 146304 → 18비트면 충분
//     여유있게 24비트 출력 (truncate_relu에서 >>10 후 8비트로 줄어듦)
//
//   레이턴시: 1사이클
//////////////////////////////////////////////////////////////////////////////////

module adder_tree (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,

    // pe_cell 9개 psum 입력 (17비트 signed)
    input  wire signed [16:0] psum0_0, psum0_1, psum0_2, psum0_3, psum0_4,
                               psum0_5, psum0_6, psum0_7, psum0_8,

    input  wire signed [16:0] psum1_0, psum1_1, psum1_2, psum1_3, psum1_4,
                               psum1_5, psum1_6, psum1_7, psum1_8,

    // 합산 결과 (24비트 signed)
    output reg signed [23:0] sum0,   // oc_even (W0채널)
    output reg signed [23:0] sum1    // oc_odd  (W1채널)
);

    always @(posedge clk) begin
        if (rst) begin
            sum0 <= 24'sd0;
            sum1 <= 24'sd0;
        end else if (en) begin
            sum0 <= psum0_0 + psum0_1 + psum0_2 + psum0_3 + psum0_4
                  + psum0_5 + psum0_6 + psum0_7 + psum0_8;
            sum1 <= psum1_0 + psum1_1 + psum1_2 + psum1_3 + psum1_4
                  + psum1_5 + psum1_6 + psum1_7 + psum1_8;
        end
    end

endmodule
