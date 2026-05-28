`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: line_buffer
// Description:
//   - 1행 지연 FIFO (shift register)
//   - en=1일 때만 동작, en=0이면 hold
//   - rst=1이면 ptr 및 출력 초기화
//   - Conv1: DEPTH=27 (28픽셀 행 - 1)
//   - Conv2: DEPTH=25 (26픽셀 행 - 1)
//
//   타이밍:
//     cycle N: din 입력, mem[ptr] 읽어 dout 출력, ptr 증가
//     → din이 DEPTH+1 사이클 후 dout으로 나옴 (1행 지연)
//////////////////////////////////////////////////////////////////////////////////

module conv1_line_buffer #(
    parameter integer WIDTH = 8,
    parameter integer DEPTH = 27
)(
    input  wire             clk,
    input  wire             rst,        // active-high 동기 리셋
    input  wire             en,
    input  wire [WIDTH-1:0] din,
    output reg  [WIDTH-1:0] dout
);
    localparam integer ADDR_W = $clog2(DEPTH);

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_W-1:0] ptr;

    integer j;
    always @(posedge clk) begin
        if (rst) begin
            ptr  <= {ADDR_W{1'b0}};
            dout <= {WIDTH{1'b0}};
            // mem 초기화 (시뮬레이션 안전)
            for (j = 0; j < DEPTH; j = j + 1)
                mem[j] <= {WIDTH{1'b0}};
        end else if (en) begin
            dout     <= mem[ptr];
            mem[ptr] <= din;
            ptr      <= (ptr == DEPTH-1) ? {ADDR_W{1'b0}} : ptr + 1'b1;
        end
    end

endmodule
