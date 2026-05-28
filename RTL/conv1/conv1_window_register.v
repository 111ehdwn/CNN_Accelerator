`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: window_register
// Description:
//   - 3×3 sliding window register
//   - Conv1: IC=1이므로 1 instance
//   - en=1 cycle edge에 left-shift, en=0이면 hold
//
//   데이터 흐름:
//     row2_in : BRAM 출력 (가장 최신 행)
//     row1_in : lb1 출력 (1행 지연)
//     row0_in : lb2 출력 (2행 지연, 가장 오래된)
//
//   window 출력 (row 순서: 0=가장 오래된, 2=가장 최신):
//     k0=win[0][0]  k1=win[0][1]  k2=win[0][2]
//     k3=win[1][0]  k4=win[1][1]  k5=win[1][2]
//     k6=win[2][0]  k7=win[2][1]  k8=win[2][2]
//     (col: 0=가장 오래된, 2=가장 최신)
//
//   rst=1이면 전체 레지스터 0 초기화
//////////////////////////////////////////////////////////////////////////////////

module conv1_window_register #(
    parameter integer WIDTH = 8
)(
    input  wire             clk,
    input  wire             rst,        // active-high 동기 리셋
    input  wire             en,

    input  wire signed [WIDTH-1:0] row2_in,
    input  wire signed [WIDTH-1:0] row1_in,
    input  wire signed [WIDTH-1:0] row0_in,

    output wire signed [WIDTH-1:0] k0, k1, k2,
    output wire signed [WIDTH-1:0] k3, k4, k5,
    output wire signed [WIDTH-1:0] k6, k7, k8
);

    reg signed [WIDTH-1:0] win_r0 [0:2];
    reg signed [WIDTH-1:0] win_r1 [0:2];
    reg signed [WIDTH-1:0] win_r2 [0:2];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 3; i = i + 1) begin
                win_r0[i] <= {WIDTH{1'b0}};
                win_r1[i] <= {WIDTH{1'b0}};
                win_r2[i] <= {WIDTH{1'b0}};
            end
        end else if (en) begin
            win_r0[0] <= win_r0[1];
            win_r0[1] <= win_r0[2];
            win_r0[2] <= row0_in;

            win_r1[0] <= win_r1[1];
            win_r1[1] <= win_r1[2];
            win_r1[2] <= row1_in;

            win_r2[0] <= win_r2[1];
            win_r2[1] <= win_r2[2];
            win_r2[2] <= row2_in;
        end
    end

    // output wire 로 직접 연결 (always @(*) reg 제거)
    assign k0 = win_r0[0]; assign k1 = win_r0[1]; assign k2 = win_r0[2];
    assign k3 = win_r1[0]; assign k4 = win_r1[1]; assign k5 = win_r1[2];
    assign k6 = win_r2[0]; assign k7 = win_r2[1]; assign k8 = win_r2[2];

endmodule
