`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_simd_pe_cell
// Description:
//   DSP48E1 SIMD packing 셀.
//   단일 DSP 로 두 OC 의 8×8 곱셈을 동시에 처리.
//
//   알고리즘 (첨부 문서 기반):
//     Aport = W1 * 2^17 + W0   (W0=OC_even weight, W1=OC_odd weight)
//     Bport = X                 (공유 activation)
//     P     = Aport * X
//
//   결과 추출:
//     P0 = W0*X = sint17(P[16:0])
//     P1 = W1*X = sint16(P[32:17]) + [P0<0] - 256*X*ovf
//
//   Overflow 조건: W1 == -128 && W0 < 0
//
//   Latency: 2 cycle
//     cycle 1: Aport 조립 + DSP 곱셈
//     cycle 2: 결과 추출 및 보정
//////////////////////////////////////////////////////////////////////////////////

module fc_pe_cell (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,

    input  wire signed [7:0]  x,       // shared activation (INT8)
    input  wire signed [7:0]  w0,      // weight OC_even
    input  wire signed [7:0]  w1,      // weight OC_odd

    output reg  signed [15:0] p0_out,  // w0 * x
    output reg  signed [15:0] p1_out   // w1 * x
);

    //------------------------------------------------------------------
    // Aport 조립: Aport = W1*2^17 + W0 (25-bit signed)
    //   [7:0]   = W0[7:0]
    //   [16:8]  = {9{W0[7]}}   (sign extension)
    //   [24:17] = W1 + (W0<0 ? -1 : 0)
    //------------------------------------------------------------------
    wire w0_neg = w0[7];
    wire signed [7:0] w1_adj = w1 + (w0_neg ? 8'shFF : 8'sh00);
    wire signed [24:0] aport = { w1_adj, {9{w0_neg}}, w0[7:0] };

    //------------------------------------------------------------------
    // Overflow 검출
    //------------------------------------------------------------------
    wire ovf = (w1 == 8'sh80) && w0_neg;

    //------------------------------------------------------------------
    // DSP 곱셈 (* use_dsp = "yes" *)
    //------------------------------------------------------------------
    (* use_dsp = "yes" *)
    wire signed [42:0] p_dsp = aport * $signed({{10{x[7]}}, x});

    //------------------------------------------------------------------
    // Stage 1: 중간값 등록
    //------------------------------------------------------------------
    wire p0_neg_comb = p_dsp[16];  // P0 부호 (carry 보정용)

    reg signed [42:0] p_dsp_r;
    reg               ovf_r;
    reg signed [8:0]  x_r;        // 9-bit signed X (부호 유지)
    reg               p0_neg_r;

    always @(posedge clk) begin
        if (rst) begin
            p_dsp_r  <= 43'sd0;
            ovf_r    <= 1'b0;
            x_r      <= 9'sd0;
            p0_neg_r <= 1'b0;
        end else if (en) begin
            p_dsp_r  <= p_dsp;
            ovf_r    <= ovf;
            x_r      <= $signed({x[7], x});
            p0_neg_r <= p0_neg_comb;
        end
    end

    //------------------------------------------------------------------
    // Stage 2: 결과 추출 + 보정
    //   P0 = sint17(P[16:0]) → 16-bit (|W0*X| ≤ 2^14, 안전)
    //   P1 = P[32:17] + [P0<0] - 256*X*ovf
    //------------------------------------------------------------------
    wire signed [15:0] p0_clip   = p_dsp_r[15:0];
    wire signed [15:0] p1_slot   = p_dsp_r[32:17];
    wire signed [15:0] carry_c   = {{15{1'b0}}, p0_neg_r};
    wire signed [15:0] ovf_corr  = ovf_r ? $signed(x_r <<< 8) : 16'sd0;

    always @(posedge clk) begin
        if (rst) begin
            p0_out <= 16'sd0;
            p1_out <= 16'sd0;
        end else if (en) begin
            p0_out <= p0_clip;
            p1_out <= p1_slot + carry_c - ovf_corr;
        end
    end

endmodule