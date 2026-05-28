`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: pe_cell
// Description:
//   - DSP48E1 1개를 사용하는 기본 PE
//   - Conv1 용도: DEPTH=2 (sel=0: reg[0]=oc0/oc1, sel=1: reg[1]=oc4/oc5 등)
//
//   Weight 적재 인터페이스:
//     load_en=1 && load_idx==i → w_regs[i] <= packed_w
//
//   Packing 식 (Python 오프라인 계산):
//     packed_w[24:0] = W1 × 2^17 + W0   (W0, W1 ∈ [-127, 127])
//     A_port (30bit signed) = sign_ext(packed_w[24:0])
//     B_port (18bit signed) = sign_ext(x[7:0])
//     P = A × B = W1×X×2^17 + W0×X
//
//   결과 추출:
//     mul0 = P[16:0]                        → W0×X
//     mul1 = P[33:17] + carry_corr          → W1×X (carry 보정)
//     carry_corr = P[16] (psum0 부호비트)   → W0×X 음수면 +1
//
//   ※ OPMODE 수정: 7'b0000001 (X=M, Y=0, Z=0) → P = M = A×B
//      이전 코드 7'b0000101은 X=M, Y=M → P=2×M 오류
//
//   파이프라인: DSP 내부 AREG=1, BREG=1, MREG=1, PREG=1 → 3사이클
//              출력 레지스터(mul0, mul1) → +1사이클 = 총 4사이클
//
//   포트 변경 이력:
//     - weight_load1/2 → load_en + load_idx 로 통일
//     - psum0/psum1    → mul0/mul1 로 통일 (adder_tree 입력)
//////////////////////////////////////////////////////////////////////////////////

module conv1_pe_cell #(
    parameter integer DEPTH  = 2,
    parameter integer ADDR_W = 1    // $clog2(DEPTH), DEPTH=2이면 1
)(
    input  wire        clk,
    input  wire        rst,

    // Weight 적재
    input  wire [24:0]       packed_w,   // weight_loader 브로드캐스트
    input  wire [ADDR_W-1:0] load_idx,   // 어느 reg에 쓸지
    input  wire              load_en,    // 1사이클 펄스

    // 라운드 선택 (매 cycle)
    input  wire [ADDR_W-1:0] sel,

    // 파이프라인
    input  wire              en,
    input  wire signed [7:0] x,

    // 출력 (4사이클 지연)
    output reg signed [16:0] mul0,   // W0 × X
    output reg signed [16:0] mul1    // W1 × X
);

    //==========================================================================
    // 1. Weight Registers
    //==========================================================================
    reg [24:0] w_regs [0:DEPTH-1];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < DEPTH; i = i + 1)
                w_regs[i] <= 25'd0;
        end else if (load_en) begin
            w_regs[load_idx] <= packed_w;
        end
    end

    //==========================================================================
    // 2. Active Weight Selection
    //==========================================================================
    wire [24:0] active_w;
    generate
        if (DEPTH == 1)
            assign active_w = w_regs[0];
        else
            assign active_w = w_regs[sel];
    endgenerate

    //==========================================================================
    // 3. DSP48E1
    //    OPMODE 수정: 7'b0000001 → X=M, Y=0, Z=0 → P = A×B
    //    이전: 7'b0000101 → X=M, Y=M → P = 2×(A×B) [버그]
    //==========================================================================
    wire [47:0] P;

DSP48E1 #(
        .A_INPUT            ("DIRECT"),
        .B_INPUT            ("DIRECT"),
        .USE_DPORT          ("FALSE"),
        .USE_MULT           ("MULTIPLY"),
        .USE_SIMD           ("ONE48"),
        .AUTORESET_PATDET   ("NO_RESET"),
        .MASK               (48'h3fffffffffff),
        .PATTERN            (48'h000000000000),
        .SEL_MASK           ("MASK"),
        .SEL_PATTERN        ("PATTERN"),
        .USE_PATTERN_DETECT ("NO_PATDET"),
        .ACASCREG           (1),
        .ADREG              (0),
        .ALUMODEREG         (0), // ★ 0으로 변경 (고정 제어 신호이므로 레지스터 제거)
        .AREG               (1),
        .BCASCREG           (1),
        .BREG               (1),
        .CARRYINREG         (0), // ★ 0으로 변경
        .CARRYINSELREG      (0), // ★ 0으로 변경 (Warning 제거 핵심)
        .CREG               (0), // ★ 사용 안 하므로 0
        .DREG               (0),
        .INMODEREG          (0), // ★ 0으로 변경
        .MREG               (1),
        .OPMODEREG          (0), // ★ 0으로 변경 (Warning 및 무조건적 연산 매칭 제어)
        .PREG               (1)
    ) dsp_inst (
        // Unused cascade
        .ACOUT          (),  .BCOUT          (),
        .CARRYCASCOUT   (),  .MULTSIGNOUT    (),  .PCOUT  (),
        // Unused status
        .OVERFLOW       (),  .PATTERNBDETECT (),
        .PATTERNDETECT  (),  .UNDERFLOW      (),
        .CARRYOUT       (),
        // Data output
        .P              (P),
        // Unused cascade inputs
        .ACIN           (30'b0),  .BCIN   (18'b0),
        .CARRYCASCIN    (1'b0),   .MULTSIGNIN(1'b0),  .PCIN(48'b0),
        // Control - fixed
        .ALUMODE        (4'b0000),
        .CARRYINSEL     (3'b000),
        .CLK            (clk),
        .INMODE         (5'b00000),

        
        // ★ 핵심 수정: X=M, Y=M, Z=0 조합인 7'b0000101 로 변경해야 하드웨어 규칙에 맞습니다.
        .OPMODE         (7'b0000101), 
        
        // Data inputs
        .A              ({{5{active_w[24]}}, active_w[24:0]}),  // 30bit sign-ext
        .B              ({{10{x[7]}}, x[7:0]}),                  // 18bit sign-ext
        .C              (48'b0),
        .CARRYIN        (1'b0),
        .D              (25'b0),
        // CE - data path
        .CEA1           (1'b0),
        .CEA2           (en),
        .CEB1           (1'b0),
        .CEB2           (en),
        .CEM            (en),
        .CEP            (en),
        // CE - unused
        .CEAD           (1'b0),  .CEC     (1'b0),  .CED     (1'b0),
        // CE - control
        .CEALUMODE      (1'b1),  .CECARRYIN(1'b1),
        .CECTRL         (1'b1),  .CEINMODE (1'b1),
        // Reset - active registers (DSP48E1은 active-high → ~rst_n 변환)
        .RSTA           (rst),  .RSTB      (rst),
        .RSTM           (rst),  .RSTP      (rst),
        .RSTCTRL        (rst),  .RSTALUMODE(rst),
        .RSTINMODE      (rst),  .RSTALLCARRYIN(rst),
        // Reset - inactive
        .RSTC           (1'b0),  .RSTD  (1'b0)
    );
    //==========================================================================
    // 4. 결과 추출
    //    P = W1×X×2^17 + W0×X
    //    mul0 = P[16:0]             → W0×X (하위 17비트)
    //    mul1 = P[33:17] + carry    → W1×X (carry 보정)
    //    carry_corr: W0×X < 0이면 P[33:17]이 1 작으므로 +1 보정
    //                P[16] = mul0의 MSB(부호) → 음수면 1
    //==========================================================================
    wire signed [16:0] raw0      = P[16:0];
    wire signed [17:0] p1_slot   = $signed(P[33:17]);   // 17비트 슬롯
    wire        [16:0] carry_val = {{16{1'b0}}, P[16]};  // 0 or 1

    wire signed [16:0] raw1 = p1_slot[16:0] + $signed({1'b0, carry_val});

    always @(posedge clk) begin
        if (rst) begin
            mul0 <= 17'sd0;
            mul1 <= 17'sd0;
        end else if (en) begin
            mul0 <= raw0;
            mul1 <= raw1;
        end
    end

endmodule
