`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: adder_tree
// Description:
//   - pe_cell 9개의 mul0/mul1을 1사이클에 합산
//   - 입력: mul0[0~8], mul1[0~8] 각 17비트 signed
//   - 출력: sum0 (oc_even), sum1 (oc_odd) 각 24비트 signed
//
//   비트 성장:
//     mul 1개 최대: 127×127 = 16129 → 15비트 (부호 포함 16비트)
//     9개 합산 최대: 16129×9 = 145161 → 18비트면 충분
//     24비트 출력으로 충분한 여유 확보
//
//   레이턴시: 1사이클 (등록 출력)
//////////////////////////////////////////////////////////////////////////////////

module conv1_adder_tree (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,

    input  wire signed [16:0] mul0_0, mul0_1, mul0_2, mul0_3, mul0_4,
                               mul0_5, mul0_6, mul0_7, mul0_8,

    input  wire signed [16:0] mul1_0, mul1_1, mul1_2, mul1_3, mul1_4,
                               mul1_5, mul1_6, mul1_7, mul1_8,

    output reg signed [23:0] sum0,
    output reg signed [23:0] sum1
);

    always @(posedge clk) begin
        if (!rst_n) begin
            sum0 <= 24'sd0;
            sum1 <= 24'sd0;
        end else if (en) begin
            sum0 <= $signed(mul0_0) + $signed(mul0_1) + $signed(mul0_2)
                  + $signed(mul0_3) + $signed(mul0_4) + $signed(mul0_5)
                  + $signed(mul0_6) + $signed(mul0_7) + $signed(mul0_8);
            sum1 <= $signed(mul1_0) + $signed(mul1_1) + $signed(mul1_2)
                  + $signed(mul1_3) + $signed(mul1_4) + $signed(mul1_5)
                  + $signed(mul1_6) + $signed(mul1_7) + $signed(mul1_8);
        end
    end

endmodule
