`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_pe_array
// Description:
//   FC SIMD PE array (16 lanes).
//
//   x_flat        : 16 channel activation,         16 * 8  = 128-bit
//   w_packed_flat : 16 channel SIMD-packed weight, 16 * 32 = 512-bit
//                   각 32b 슬롯 = gen script(weight_simd_pack.py) 의 A = W1*2^17 + W0
//                   (25-bit, [24:0]). PS/BMG 가 변환 없이 그대로 저장 → 재조립 없이
//                   pe_cell.packed_w 로 직결 (conv1/conv2 와 동일 SIMD-direct 방식).
//
//   Each lane: pe_cell(STREAM=1) computes
//     p0 = x[ch] * W0[ch]   (even output column)
//     p1 = x[ch] * W1[ch]   (odd  output column)
//////////////////////////////////////////////////////////////////////////////////

module fc_pe_array (
    input  wire         clk,
    input  wire         rst,
    input  wire         en,

    input  wire [127:0] x_flat,
    input  wire [511:0] w_packed_flat,   // 16ch × 32b SIMD-A (A=W1*2^17+W0), gen 그대로

    output wire [255:0] p0_flat,
    output wire [255:0] p1_flat
);

    genvar ch;
    generate
        for (ch = 0; ch < 16; ch = ch + 1) begin : gen_ch
            wire signed [7:0] x_ch = x_flat[ch*8 +: 8];

            // SIMD-packed A (25b) 를 BMG 에서 그대로 받아 pe_cell A포트로 직결.
            //   (구: even/odd 8b 분리 후 A 재조립 → A 직접 저장으로 제거. bit-identical.)
            wire [24:0] packed_w_ch = w_packed_flat[ch*32 +: 25];

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
