`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_pe_array
// Description:
//   FC SIMD PE array.
//
//   x_flat  : 16 channel activation, 16 * 8 = 128-bit
//   w0_flat : even output column weights, 16 * 8 = 128-bit
//   w1_flat : odd  output column weights, 16 * 8 = 128-bit
//
//   Each lane uses one SIMD-packed DSP cell that computes:
//     p0 = x[ch] * w0[ch]
//     p1 = x[ch] * w1[ch]
//////////////////////////////////////////////////////////////////////////////////

module fc_pe_array (
    input  wire         clk,
    input  wire         rst,
    input  wire         en,

    input  wire [127:0] x_flat,
    input  wire [127:0] w0_flat,
    input  wire [127:0] w1_flat,

    output wire [255:0] p0_flat,
    output wire [255:0] p1_flat
);

    genvar ch;
    generate
        for (ch = 0; ch < 16; ch = ch + 1) begin : gen_ch
            wire signed [7:0]  x_ch  = x_flat [ch*8 +: 8];
            wire signed [7:0]  w0_ch = w0_flat[ch*8 +: 8];
            wire signed [7:0]  w1_ch = w1_flat[ch*8 +: 8];

            // SIMD A-port pack: A = W1*2^17 + W0 (25b), W0<0 carry 보정.
            //   [7:0]   = W0
            //   [16:8]  = {9{W0[7]}}  (sign extension)
            //   [24:17] = W1 + (W0<0 ? -1 : 0)
            // 공용 core/pe_cell (STREAM=1) 의 A포트가 받는 packed_w 포맷.
            wire               w0_neg      = w0_ch[7];
            wire signed [7:0]  w1_adj      = w1_ch + (w0_neg ? 8'shFF : 8'sh00);
            wire        [24:0] packed_w_ch = { w1_adj, {9{w0_neg}}, w0_ch[7:0] };

            wire signed [16:0] p0_ch;   // core/pe_cell 출력 17b
            wire signed [16:0] p1_ch;

            pe_cell #(.STREAM(1), .DEPTH(1)) cell_inst (
                .clk     (clk),
                .rst     (rst),
                .packed_w(packed_w_ch),
                .load_idx(1'b0),       // STREAM 에서 미사용
                .load_en (1'b0),       // STREAM 에서 미사용
                .sel     (1'b0),       // STREAM 에서 미사용
                .en      (en),
                .x       (x_ch),
                .mul0    (p0_ch),
                .mul1    (p1_ch)
            );

            // adder_tree 입력은 16b/lane → 하위 16b 취함.
            //   INT8 양자화에서 |W*X| <= 127*128 = 16256 < 32767 → 17번째 비트는
            //   항상 부호확장(p_ch[16]==p_ch[15]) 이므로 [15:0] 슬라이스는 무손실.
            assign p0_flat[ch*16 +: 16] = p0_ch[15:0];
            assign p1_flat[ch*16 +: 16] = p1_ch[15:0];
        end
    endgenerate

endmodule
