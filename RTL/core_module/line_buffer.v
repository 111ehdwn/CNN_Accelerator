`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: line_buffer
// Description:
//   - Sobel용 line_buffer와 동일한 구조
//   - Conv1 용도: 입력 28픽셀 행에서 DEPTH=27로 설정
//     (BRAM 등록 출력 1사이클 지연 포함 → 실질 지연 = DEPTH+1 = 28사이클 = 1행)
//   - WIDTH, DEPTH 파라미터로 재사용 가능
//////////////////////////////////////////////////////////////////////////////////

module line_buffer #(
    parameter integer WIDTH = 8,
    // Conv1: 28-1=27 (1행 추가 지연)
    // Conv2: 26-1=25 (1행 추가 지연)
    parameter integer DEPTH = 27
)(
    input  wire             clk,
    input  wire             en,
    input  wire [WIDTH-1:0] din,
    output reg  [WIDTH-1:0] dout
);
    localparam integer ADDR_W = $clog2(DEPTH);

    // BRAM 추론 부분 삭제 - 어차피 LUTRAM 합성되어도 문제 없음
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    reg [ADDR_W-1:0] ptr = {ADDR_W{1'b0}};

    always @(posedge clk) begin
        if (en) begin
            dout     <= mem[ptr];   // 현재 ptr 위치 읽기 (1사이클 등록 지연)
            mem[ptr] <= din;        // 새 데이터 쓰기
            ptr      <= (ptr == DEPTH-1) ? {ADDR_W{1'b0}} : ptr + 1'b1;
        end
    end

endmodule
