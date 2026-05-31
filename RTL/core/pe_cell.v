`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: pe_cell
// Description:
//   - DSP48E1 1개 + parameterized weight 레지스터 N_WEIGHTS개
//   - N_WEIGHTS=2: Conv1 (OC round mux)
//   - N_WEIGHTS=3: Conv2 (K_col time-mux)
//   - N_WEIGHTS=1: FC (streaming, sel 무시)
//   - sel: 매 cycle 활성 weight register 선택
//
//   Packing 식:
//     A_port = W1 × 2^17 + W0  (25bit, Python 오프라인 계산)
//     B_port = X               (18bit signed)
//     P      = A × B = W1×X×2^17 + W0×X
//
//   결과 추출 (-128 없으므로 carry 보정만):
//     psum0 = P[16:0]                          (W0×X)
//     psum1 = sint16(P[32:17]) + [P0<0]        (W1×X, carry 보정만)
//
//   -128 없으므로 overflow 검출 및 -256×X 보정 불필요
//
//   파이프라인: DSP 3사이클 + 출력 레지스터 1사이클 = 총 4사이클
//////////////////////////////////////////////////////////////////////////////////

module pe_cell #(
    parameter STREAM = 0,                                   // 1 = weight reg 우회, packed_w → A포트 직결 (FC streaming)
    parameter DEPTH = 2,
    parameter ADDR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1
)(
    input  wire        clk,
    input  wire        rst,            // active-high, cnn_accel_top에서 변환

    // weight 적재
    input  wire [24:0]          packed_w,   // weight_loader에서 공급
    input  wire [ADDR_W-1:0] load_idx,   // parameterized weight index
    input  wire                 load_en,    // load enable, active-high

    // 라운드 선택, Selection(each cycle)
    input  wire [ADDR_W-1:0] sel,

    // Pipeline
    input  wire              en,       // active-high
    input  wire signed [7:0] x,

    // Output
    output reg signed [16:0] mul0,    // W0 × X
    output reg signed [16:0] mul1     // W1 × X
);

    //==========================================================================
    // 1+2. Weight 공급 + Active Weight Selection
    //
    //   STREAM=0 (conv1/conv2): weight-stationary. packed_w 를 w_regs 에 load 후
    //                           sel 로 매 cycle 활성 weight 선택.
    //   STREAM=1 (FC)         : streaming. packed_w 를 레지스터/load 없이 A포트 직결.
    //                           (FC 는 144 spatial 마다 weight 가 바뀌어 load 불가)
    //==========================================================================
    wire [24:0] active_reg;
    generate
    if (STREAM == 0) begin : gen_wreg
        reg [24:0] w_regs [0:DEPTH-1];
        integer i;
        always @(posedge clk) begin
            if(rst) begin
                for (i=0; i<DEPTH; i=i+1) begin
                    w_regs[i] <= 25'd0;
                end
            end else if (load_en) begin
                w_regs[load_idx] <= packed_w;
            end
        end

        if (DEPTH == 1) begin : gen_sel1
            assign active_reg = w_regs[0];
        end else begin : gen_selN
            assign active_reg = w_regs[sel];
        end
    end else begin : gen_stream
        assign active_reg = packed_w;
    end
    endgenerate

    //==========================================================================
    // 3. DSP48E1 Instantiation
    //==========================================================================
    wire [47:0] P;

    DSP48E1 #(
    // Feature Control Attributes
    .A_INPUT            ("DIRECT"),
    .B_INPUT            ("DIRECT"),
    .USE_DPORT          ("FALSE"),
    .USE_MULT           ("MULTIPLY"),
    .USE_SIMD           ("ONE48"),

    // Pattern Detector Attributes (미사용)
    .AUTORESET_PATDET   ("NO_RESET"),
    .MASK               (48'h3fffffffffff),
    .PATTERN            (48'h000000000000),
    .SEL_MASK           ("MASK"),
    .SEL_PATTERN        ("PATTERN"),
    .USE_PATTERN_DETECT ("NO_PATDET"),

    // Pipeline Register Configuration
    .ACASCREG           (1),       // = AREG (제약)
    .ADREG              (0),       // pre-adder 미사용
    .ALUMODEREG         (1),       // ALUMODE register 활성
    .AREG               (1),       // A input 1-stage
    .BCASCREG           (1),       // = BREG (제약)
    .BREG               (1),       // B input 1-stage
    .CARRYINREG         (1),       // CARRYIN register 활성
    .CARRYINSELREG      (1),       // CARRYINSEL register 활성
    .CREG               (1),       // C register 활성 (미사용이지만 UG479 권장)
    .DREG               (0),       // D 미사용
    .INMODEREG          (1),       // INMODE register 활성
    .MREG               (1),       // multiplier 출력 register
    .OPMODEREG          (1),       // OPMODE register 활성
    .PREG               (1)        // P output register
) dsp_inst (
    // Cascade outputs (미사용)
    .ACOUT              (),
    .BCOUT              (),
    .CARRYCASCOUT       (),
    .MULTSIGNOUT        (),
    .PCOUT              (),

    // Control outputs (미사용)
    .OVERFLOW           (),
    .PATTERNBDETECT     (),
    .PATTERNDETECT      (),
    .UNDERFLOW          (),

    // Data output
    .CARRYOUT           (),
    .P                  (P),

    // Cascade inputs (미사용)
    .ACIN               (30'b0),
    .BCIN               (18'b0),
    .CARRYCASCIN        (1'b0),
    .MULTSIGNIN         (1'b0),
    .PCIN               (48'b0),

    // Control inputs (상수)
    .ALUMODE            (4'b0000),       // Z + (X + Y + CIN)
    .CARRYINSEL         (3'b000),        // CARRYIN from fabric
    .CLK                (clk),
    .INMODE             (5'b00000),      // A2/B2 select, pre-adder bypass
    .OPMODE             (7'b0000101),    // X=M[31:0], Y=M[47:32], Z=0

    // Data inputs
    .A                  ({{5{active_reg[24]}}, active_reg[24:0]}),
    .B                  ({{10{x[7]}}, x[7:0]}),
    .C                  (48'b0),
    .CARRYIN            (1'b0),
    .D                  (25'b0),

    // CE - data path (active)
    .CEA1               (1'b0),          // AREG=1 → A1 미사용
    .CEA2               (en),            // A latch
    .CEB1               (1'b0),          // BREG=1 → B1 미사용
    .CEB2               (en),            // B latch
    .CEM                (en),            // multiplier 출력 latch
    .CEP                (en),            // P 출력 latch

    // CE - data path (inactive)
    .CEAD               (1'b0),          // ADREG=0
    .CEC                (1'b0),          // C 미사용
    .CED                (1'b0),          // DREG=0

    // CE - control path (상수 latch 유지)
    .CEALUMODE          (1'b1),
    .CECARRYIN          (1'b1),
    .CECTRL             (1'b1),
    .CEINMODE           (1'b1),

    // Reset - active register
    .RSTA               (rst),
    .RSTB               (rst),
    .RSTM               (rst),
    .RSTP               (rst),
    .RSTCTRL            (rst),
    .RSTALUMODE         (rst),
    .RSTINMODE          (rst),
    .RSTALLCARRYIN      (rst),

    // Reset - inactive register
    .RSTC               (1'b0),          // C register 활성이나 미사용 (UG479 권장)
    .RSTD               (1'b0)           // DREG=0, ADREG=0
);

    //==========================================================================
    // 4. 결과 추출
    //
    // W ∈ [-127, 127] → -128 없음 → overflow 없음
    //
    // psum0 = P[16:0]           → W0×X 단순 슬라이싱
    // psum1 = P[32:17] + [P0<0] → W1×X + carry 보정
    //
    // carry 보정 이유:
    //   P = W1×X×2^17 + W0×X
    //   P[32:17] = W1×X + floor(W0×X / 2^17)
    //   W0×X가 음수면 floor = -1 → +1 보정 필요
    //   → [P0<0] = psum0의 MSB(부호비트)
    //
    // DSP 3사이클 레이턴시 → P와 같은 타이밍에 바로 추출 가능
    // (x 지연 레지스터 불필요, ovf 제거로 단순화)
    //==========================================================================

    wire signed [16:0] p0_raw     = P[16:0];
    wire signed [16:0] p1_slot    = {{1{P[32]}}, P[32:17]};
    wire signed [16:0] carry_corr = {16'd0, p0_raw[16]};  // [P0<0]

    wire signed [16:0] p1_raw = p1_slot + carry_corr;

    // 출력 레지스터 (Output Register)
    always @(posedge clk) begin
        if (rst) begin
            mul0 <= 17'sd0;
            mul1 <= 17'sd0;
        end else if (en) begin
            mul0 <= p0_raw;
            mul1 <= p1_raw;
        end
    end

endmodule
