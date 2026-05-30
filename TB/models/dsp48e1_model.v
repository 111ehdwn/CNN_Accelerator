`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// dsp48e1_model.v — iverilog 전용 DSP48E1 약식 behavioral 모델
//
//   ★ Vivado 시뮬/합성에서는 이 파일을 소스에서 제외할 것.
//     (실제 Xilinx DSP48E1 primitive / unisims 라이브러리 사용)
//
//   RTL/core/pe_cell.v 가 사용하는 모드만 재현:
//     - AREG=BREG=MREG=PREG=1 → A/B latch → M=A*B → P=M  (3-stage)
//     - OPMODE=7'b0000101, ALUMODE=4'b0000 → P = A*B  (Z=0, X+Y=M)
//     - CEA2/CEB2/CEM/CEP = en,  RSTA/RSTB/RSTM/RSTP = rst (active-high)
//   그 외 포트/파라미터/cascade/pattern-detect 는 named 매칭용으로만 선언(무시).
//////////////////////////////////////////////////////////////////////////////////

module DSP48E1 #(
    parameter        A_INPUT            = "DIRECT",
    parameter        B_INPUT            = "DIRECT",
    parameter        USE_DPORT          = "FALSE",
    parameter        USE_MULT           = "MULTIPLY",
    parameter        USE_SIMD           = "ONE48",
    parameter        AUTORESET_PATDET   = "NO_RESET",
    parameter [47:0] MASK               = 48'h3fffffffffff,
    parameter [47:0] PATTERN            = 48'h000000000000,
    parameter        SEL_MASK           = "MASK",
    parameter        SEL_PATTERN        = "PATTERN",
    parameter        USE_PATTERN_DETECT = "NO_PATDET",
    parameter        ACASCREG           = 1,
    parameter        ADREG              = 0,
    parameter        ALUMODEREG         = 1,
    parameter        AREG               = 1,
    parameter        BCASCREG           = 1,
    parameter        BREG               = 1,
    parameter        CARRYINREG         = 1,
    parameter        CARRYINSELREG      = 1,
    parameter        CREG               = 1,
    parameter        DREG               = 0,
    parameter        INMODEREG          = 1,
    parameter        MREG               = 1,
    parameter        OPMODEREG          = 1,
    parameter        PREG               = 1
)(
    // cascade / status outputs (미사용)
    output [29:0] ACOUT,
    output [17:0] BCOUT,
    output        CARRYCASCOUT,
    output        MULTSIGNOUT,
    output [47:0] PCOUT,
    output        OVERFLOW,
    output        PATTERNBDETECT,
    output        PATTERNDETECT,
    output        UNDERFLOW,
    output [3:0]  CARRYOUT,
    output [47:0] P,

    // cascade inputs (미사용)
    input  [29:0] ACIN,
    input  [17:0] BCIN,
    input         CARRYCASCIN,
    input         MULTSIGNIN,
    input  [47:0] PCIN,

    // control
    input  [3:0]  ALUMODE,
    input  [2:0]  CARRYINSEL,
    input         CLK,
    input  [4:0]  INMODE,
    input  [6:0]  OPMODE,

    // data
    input  [29:0] A,
    input  [17:0] B,
    input  [47:0] C,
    input         CARRYIN,
    input  [24:0] D,

    // clock enables
    input         CEA1, CEA2, CEB1, CEB2, CEM, CEP,
    input         CEAD, CEC, CED,
    input         CEALUMODE, CECARRYIN, CECTRL, CEINMODE,

    // resets (active-high)
    input         RSTA, RSTB, RSTM, RSTP,
    input         RSTCTRL, RSTALUMODE, RSTINMODE, RSTALLCARRYIN,
    input         RSTC, RSTD
);

    // 3-stage 곱셈 파이프 (A/B reg → M=A*B reg → P=M reg)
    reg signed [29:0] a_reg;
    reg signed [17:0] b_reg;
    reg signed [47:0] m_reg;
    reg signed [47:0] p_reg;

    always @(posedge CLK) begin
        if (RSTA)      a_reg <= 30'sd0;
        else if (CEA2) a_reg <= $signed(A);

        if (RSTB)      b_reg <= 18'sd0;
        else if (CEB2) b_reg <= $signed(B);

        if (RSTM)      m_reg <= 48'sd0;
        else if (CEM)  m_reg <= a_reg * b_reg;   // 30b×18b signed → 48b

        if (RSTP)      p_reg <= 48'sd0;
        else if (CEP)  p_reg <= m_reg;           // OPMODE=...0101 → P=M
    end

    assign P              = p_reg;
    assign PCOUT          = p_reg;
    assign ACOUT          = 30'd0;
    assign BCOUT          = 18'd0;
    assign CARRYCASCOUT   = 1'b0;
    assign MULTSIGNOUT    = 1'b0;
    assign OVERFLOW       = 1'b0;
    assign PATTERNBDETECT = 1'b0;
    assign PATTERNDETECT  = 1'b0;
    assign UNDERFLOW      = 1'b0;
    assign CARRYOUT       = 4'd0;

endmodule
