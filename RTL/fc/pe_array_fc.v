`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_simd_pe_array
// Description:
//   FC SIMD PE array: 1 OC pair × 16 channel lane = 16 DSP.
//
//   DSP 제약 20개 환경에서 1 pair씩 순차 처리.
//   5 pair (OC 0~9) 를 FSM 이 순차 구동 → 총 5 × 144 = 720 COMPUTE cycle.
//
//   입력:
//     x_flat  [127:0] : 16 ch activation (INT8, 공유)
//     w0_flat [ 63:0] : OC_even 16 ch weight
//     w1_flat [ 63:0] : OC_odd  16 ch weight
//
//   출력:
//     p0_flat [255:0] : OC_even 16 product (16b × 16)
//     p1_flat [255:0] : OC_odd  16 product (16b × 16)
//
//   Latency: 2 cycle
//   DSP: 16개
//////////////////////////////////////////////////////////////////////////////////

module fc_pe_array (
    input  wire         clk,
    input  wire         rst,
    input  wire         en,

    input  wire [127:0] x_flat,   // 16 ch × 8b activation
    input  wire [ 63:0] w0_flat,  // OC_even 16 ch × 8b weight
    input  wire [ 63:0] w1_flat,  // OC_odd  16 ch × 8b weight

    output wire [255:0] p0_flat,  // OC_even 16 × 16b product
    output wire [255:0] p1_flat   // OC_odd  16 × 16b product
);

    genvar ch;
    generate
        for (ch = 0; ch < 16; ch = ch + 1) begin : gen_ch
            wire signed [7:0]  x_ch  = x_flat [ch*8    +: 8];
            wire signed [7:0]  w0_ch = w0_flat[ch*8    +: 8];
            wire signed [7:0]  w1_ch = w1_flat[ch*8    +: 8];
            wire signed [15:0] p0_ch;
            wire signed [15:0] p1_ch;

            fc_pe_cell cell_inst (
                .clk   (clk),
                .rst   (rst),
                .en    (en),
                .x     (x_ch),
                .w0    (w0_ch),
                .w1    (w1_ch),
                .p0_out(p0_ch),
                .p1_out(p1_ch)
            );

            assign p0_flat[ch*16 +: 16] = p0_ch;
            assign p1_flat[ch*16 +: 16] = p1_ch;
        end
    endgenerate

endmodule