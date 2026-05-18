`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2026/05/13 14:21:22
// Design Name:
// Module Name: line_buffer
// line_buffer.v
//   - DEPTH cycle delay box (FIFO equivalent)
//   - Circular buffer (BRAM 추론용 idiom)
//   - 매 cycle din을 받고, DEPTH cycle 후 dout으로 내보냄
//   *현재로써는 reset 로직 존재하지 않음!! => 이후에 추가해야 할 수도??*
//////////////////////////////////////////////////////////////////////////////////


module line_buffer#(
    parameter integer WIDTH = 8,
    parameter integer DEPTH = 101
)(
    input  wire             clk,
    input  wire              en,
    input  wire [WIDTH-1:0] din,
    output reg [WIDTH-1:0] dout
);
    localparam integer ADDR_W = $clog2(DEPTH); // 101 => 7bits for address!

    // Main memory block(must be mapped into BRAM!)
    (* ram_style = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];

    // Address for memory (pointer)
    reg [ADDR_W-1:0] ptr = {ADDR_W{1'b0}};

    // Sequential Logic
    always @(posedge clk) begin
        if (en) begin
            dout     <= mem[ptr];   // read data in address=ptr
            mem[ptr] <= din;        // write data in address=ptr
            // mod(DEPTH) => circular address
            ptr      <= (ptr == DEPTH-1) ? {ADDR_W{1'b0}} : ptr + 1'b1;
        end
    end

endmodule
