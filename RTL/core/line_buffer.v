`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: line_buffer
// Description:
//   - Sobel용 line_buffer와 동일한 구조 (rst 추가 — Conv1 round 전환 시 lb_rst 용)
//   - Conv1 용도: 입력 28픽셀 행에서 DEPTH=27로 설정
//     (BRAM 등록 출력 1사이클 지연 포함 → 실질 지연 = DEPTH+1 = 28사이클 = 1행)
//   - Conv2 용도: DEPTH=25 (26픽셀 행)
//   - WIDTH, DEPTH 파라미터로 재사용 가능
//
//   reset 동작:
//     rst=1 (active-high synchronous) → ptr/dout/mem 전부 0으로 초기화.
//     Conv1: round 전환 (RUN1 → RUN2) 사이에 lb_rst pulse 로 stale data 제거.
//            mem 까지 클리어해야 PIPELINE_FILL 첫 cycle 부터 깨끗한 stream 출력 (안 그러면
//            Round1 trailing data 가 Round2 초기 window 오염).
//     Conv2: per-image 사이에 별도 reset 안 시킴. 시스템 reset 외엔 rst=0 유지.
//
//   Conv1 engine 이 active-low rst_n 을 쓰면 instantiation 에서 `.rst(~rst_n)` 으로 변환.
//////////////////////////////////////////////////////////////////////////////////

module line_buffer #(
    parameter integer WIDTH = 8,
    // Conv1: 28-1=27 (1행 추가 지연)
    // Conv2: 26-1=25 (1행 추가 지연)
    parameter integer DEPTH = 27
)(
    input  wire             clk,
    input  wire             rst,         // active-high synchronous
    input  wire             en,
    input  wire [WIDTH-1:0] din,
    output reg  [WIDTH-1:0] dout
);
    localparam integer ADDR_W = $clog2(DEPTH);

    // BRAM 추론 부분 삭제 - 어차피 LUTRAM 합성되어도 문제 없음
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    reg [ADDR_W-1:0] ptr;

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            ptr  <= {ADDR_W{1'b0}};
            dout <= {WIDTH{1'b0}};
            for (i = 0; i < DEPTH; i = i + 1)
                mem[i] <= {WIDTH{1'b0}};
        end else if (en) begin
            dout     <= mem[ptr];       // 현재 ptr 위치 읽기 (1사이클 등록 지연)
            mem[ptr] <= din;            // 새 데이터 쓰기
            ptr      <= (ptr == DEPTH-1) ? {ADDR_W{1'b0}} : ptr + 1'b1;
        end
    end

endmodule
