`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: window_register
// Description:
//   - 3×3 sliding window register, 1-stream 일반 모듈
//   - Conv1: 1 instance (IC=1)
//   - Conv2: 8 instance (IC=8, IC당 1개)
//   - en=1 cycle 의 edge 에 left-shift; en=0 면 hold
//
//   데이터 흐름:
//     BRAM (Port B, L=1 또는 2)        → row2_in   (가장 최신 행)
//     row2_in → line_buffer1 → lb1.dout → row1_in  (1행 지연)
//     row1_in → line_buffer2 → lb2.dout → row0_in  (2행 지연)
//
//   window 구조 (en=1 cycle 의 edge 에 shift):
//     row0 (가장 오래된 행): row0_in 흐름
//     row1 (중간 행):       row1_in 흐름
//     row2 (가장 최신 행):  row2_in 흐름
//
//     win[row][0]=left(가장 오래된 col), win[row][1]=center, win[row][2]=right(최신)
//
//   출력 (9 픽셀 평탄화):
//     k0=win[0][0]  k1=win[0][1]  k2=win[0][2]
//     k3=win[1][0]  k4=win[1][1]  k5=win[1][2]
//     k6=win[2][0]  k7=win[2][1]  k8=win[2][2]
//
//   col_sel 기반 PE input 선택은 외부에서 수행:
//     col_sel=0 → (k0, k3, k6)  // row 0/1/2 의 col 0 (가장 오래된)
//     col_sel=1 → (k1, k4, k7)
//     col_sel=2 → (k2, k5, k8)
//
//   유효 window 조건 (외부 FSM 책임):
//     Conv1: col >= 2 && row >= 2 (28×28 → 26×26 출력)
//     Conv2: PIPELINE_FILL 종료 + counter 진행 (상세는 conv2_timing.md)
//////////////////////////////////////////////////////////////////////////////////

module window_register #(
    parameter integer WIDTH = 8
)(
    input  wire             clk,
    input  wire             rst,         // active-high synchronous (Conv1 round 전환용)
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

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 3; i = i + 1) begin
                win_r0[i] <= {WIDTH{1'b0}};
                win_r1[i] <= {WIDTH{1'b0}};
                win_r2[i] <= {WIDTH{1'b0}};
            end
        end else if (en) begin
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
