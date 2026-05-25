`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: window_register
// Description:
//   - 3×3 sliding window register (Conv1 전용, IC=1)
//   - Sobel의 win_r0/r1/r2 구조를 독립 모듈로 분리
//
//   데이터 흐름 (Sobel과 동일):
//     BRAM → (1사이클) → b1_douta
//     b1_douta → lb1(DEPTH=27) → (28사이클 지연) → lb1_out
//     lb1_out  → lb2(DEPTH=27) → (28사이클 지연) → lb2_out
//
//   window 구조:
//     row0 (가장 위, 오래된 행): lb2_out 흐름
//     row1 (중간 행):            lb1_out 흐름
//     row2 (가장 아래, 최신 행): bram_out 흐름
//
//     win[row][0]=left(오래된), win[row][1]=center, win[row][2]=right(최신)
//
//   출력 픽셀 순서 (K index):
//     k0=win[0][0]  k1=win[0][1]  k2=win[0][2]
//     k3=win[1][0]  k4=win[1][1]  k5=win[1][2]
//     k6=win[2][0]  k7=win[2][1]  k8=win[2][2]
//
//   유효 window 조건:
//     col >= 2 && row >= 2  (Sobel의 w_valid와 동일 원리)
//     → 외부 FSM에서 pixel_valid 생성 후 입력
//////////////////////////////////////////////////////////////////////////////////

module window_register #(
    parameter integer WIDTH = 8
)(
    input  wire             clk,
    input  wire             en,          // pipe_en (state == RUN)

    // 3행 입력 (line_buffer 2개 + BRAM 직접)
    input  wire [WIDTH-1:0] row2_in,     // BRAM 출력 (최신 행)
    input  wire [WIDTH-1:0] row1_in,     // lb1 출력 (1행 위)
    input  wire [WIDTH-1:0] row0_in,     // lb2 출력 (2행 위, 가장 오래된)

    // 3×3 window 출력 (9픽셀, signed INT8)
    output reg signed [WIDTH-1:0] k0,    // win[0][0]
    output reg signed [WIDTH-1:0] k1,    // win[0][1]
    output reg signed [WIDTH-1:0] k2,    // win[0][2]
    output reg signed [WIDTH-1:0] k3,    // win[1][0]
    output reg signed [WIDTH-1:0] k4,    // win[1][1]
    output reg signed [WIDTH-1:0] k5,    // win[1][2]
    output reg signed [WIDTH-1:0] k6,    // win[2][0]
    output reg signed [WIDTH-1:0] k7,    // win[2][1]
    output reg signed [WIDTH-1:0] k8     // win[2][2]
);

    // 내부 window 레지스터 (Sobel의 win_r0/r1/r2와 동일)
    // [0]=left(오래된), [1]=center, [2]=right(최신)
    reg signed [WIDTH-1:0] win_r0 [0:2]; // row0: lb2_out 흐름
    reg signed [WIDTH-1:0] win_r1 [0:2]; // row1: lb1_out 흐름
    reg signed [WIDTH-1:0] win_r2 [0:2]; // row2: bram_out 흐름

    always @(posedge clk) begin
        if (en) begin
            // row0: lb2 출력 흐름 (가장 오래된 행)
            win_r0[0] <= win_r0[1];
            win_r0[1] <= win_r0[2];
            win_r0[2] <= row0_in;

            // row1: lb1 출력 흐름
            win_r1[0] <= win_r1[1];
            win_r1[1] <= win_r1[2];
            win_r1[2] <= row1_in;

            // row2: BRAM 직접 흐름 (가장 최신 행)
            win_r2[0] <= win_r2[1];
            win_r2[1] <= win_r2[2];
            win_r2[2] <= row2_in;
        end
    end

    // window 출력 (조합 논리 — 레지스터 값 그대로 연결)
    always @(*) begin
        k0 = win_r0[0]; k1 = win_r0[1]; k2 = win_r0[2];
        k3 = win_r1[0]; k4 = win_r1[1]; k5 = win_r1[2];
        k6 = win_r2[0]; k7 = win_r2[1]; k8 = win_r2[2];
    end

endmodule
