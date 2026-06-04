`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv1_adder_tree
// Description:
//   - pe_cell 9개의 mul0/mul1을 합산 (2 그룹: sum0 = Σmul0, sum1 = Σmul1)
//   - 입력: mul0[0~8], mul1[0~8] 각 17비트 signed
//   - 출력: sum0 (oc_even), sum1 (oc_odd) 각 24비트 signed
//
//   ★ 200MHz refactor (docs/conv1_timing.md §5.2):
//     기존 1-cycle 조합 9입력 가산 → 4-stage pipeline (1 add-level/stage).
//     Artix-7 −1 의 9입력 4-level 조합 가산 경로가 200MHz(5.0ns) 임계 →
//     conv2 krow_ic_adder_tree (24:1, 5-stage) 와 동일 철학으로 파이프라인.
//
//   Stage 구조 (각 stage 1-cycle pipeline register, en 게이팅):
//     Stage 1: 9 → 5   pair-add ×4 + m8 passthrough     17+17 → 18-bit
//     Stage 2: 5 → 3   pair-add ×2 + passthrough         18+18 → 19-bit
//     Stage 3: 3 → 2   pair-add ×1 + passthrough         19+19 → 20-bit
//     Stage 4: 2 → 1   pair-add ×1                        20+20 → 21-bit (24-bit 저장)
//
//   비트 성장:
//     mul 1개 최대: 127×127 = 16129 → 15비트 (부호 포함 16비트, 저장 17)
//     9개 합산 최대: 16129×9 = 145161 → 18비트 magnitude → 19비트 signed 충분
//     24비트 출력으로 충분한 여유 확보
//
//   레이턴시: 4 cycle (입력 → 등록 출력). throughput 1 result/cycle (en=1).
//   ★ 모든 입력이 정확히 4 register stage 통과 (passthrough 포함) → latency 균형.
//////////////////////////////////////////////////////////////////////////////////

module conv1_adder_tree (
    input  wire        clk,
    input  wire        rst,                  // active-high (시스템 통일)
    input  wire        en,

    input  wire signed [16:0] mul0_0, mul0_1, mul0_2, mul0_3, mul0_4,
                               mul0_5, mul0_6, mul0_7, mul0_8,

    input  wire signed [16:0] mul1_0, mul1_1, mul1_2, mul1_3, mul1_4,
                               mul1_5, mul1_6, mul1_7, mul1_8,

    output reg signed [23:0] sum0,
    output reg signed [23:0] sum1
);

    //==========================================================================
    // 입력 unpack (그룹 0 = mul0_*, 그룹 1 = mul1_*)
    //==========================================================================
    wire signed [16:0] m0 [0:8];
    wire signed [16:0] m1 [0:8];

    assign m0[0]=mul0_0; assign m0[1]=mul0_1; assign m0[2]=mul0_2;
    assign m0[3]=mul0_3; assign m0[4]=mul0_4; assign m0[5]=mul0_5;
    assign m0[6]=mul0_6; assign m0[7]=mul0_7; assign m0[8]=mul0_8;

    assign m1[0]=mul1_0; assign m1[1]=mul1_1; assign m1[2]=mul1_2;
    assign m1[3]=mul1_3; assign m1[4]=mul1_4; assign m1[5]=mul1_5;
    assign m1[6]=mul1_6; assign m1[7]=mul1_7; assign m1[8]=mul1_8;

    //==========================================================================
    // Pipeline registers (그룹별 동일 구조)
    //   s1: 18-bit ×5,  s2: 19-bit ×3,  s3: 20-bit ×2,  sum: 24-bit
    //==========================================================================
    reg signed [17:0] g0_s1 [0:4];
    reg signed [18:0] g0_s2 [0:2];
    reg signed [19:0] g0_s3 [0:1];

    reg signed [17:0] g1_s1 [0:4];
    reg signed [18:0] g1_s2 [0:2];
    reg signed [19:0] g1_s3 [0:1];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 5; i = i + 1) begin g0_s1[i] <= 18'sd0; g1_s1[i] <= 18'sd0; end
            for (i = 0; i < 3; i = i + 1) begin g0_s2[i] <= 19'sd0; g1_s2[i] <= 19'sd0; end
            for (i = 0; i < 2; i = i + 1) begin g0_s3[i] <= 20'sd0; g1_s3[i] <= 20'sd0; end
            sum0 <= 24'sd0;
            sum1 <= 24'sd0;
        end else if (en) begin
            //--------------------------------------------------------------
            // Group 0 (sum0)
            //--------------------------------------------------------------
            // Stage 1: 9 → 5
            g0_s1[0] <= $signed(m0[0]) + $signed(m0[1]);
            g0_s1[1] <= $signed(m0[2]) + $signed(m0[3]);
            g0_s1[2] <= $signed(m0[4]) + $signed(m0[5]);
            g0_s1[3] <= $signed(m0[6]) + $signed(m0[7]);
            g0_s1[4] <= {m0[8][16], m0[8]};                 // sign-ext 17→18 (passthrough)
            // Stage 2: 5 → 3
            g0_s2[0] <= $signed(g0_s1[0]) + $signed(g0_s1[1]);
            g0_s2[1] <= $signed(g0_s1[2]) + $signed(g0_s1[3]);
            g0_s2[2] <= {g0_s1[4][17], g0_s1[4]};           // sign-ext 18→19 (passthrough)
            // Stage 3: 3 → 2
            g0_s3[0] <= $signed(g0_s2[0]) + $signed(g0_s2[1]);
            g0_s3[1] <= {g0_s2[2][18], g0_s2[2]};           // sign-ext 19→20 (passthrough)
            // Stage 4: 2 → 1
            sum0     <= $signed(g0_s3[0]) + $signed(g0_s3[1]);

            //--------------------------------------------------------------
            // Group 1 (sum1)
            //--------------------------------------------------------------
            // Stage 1: 9 → 5
            g1_s1[0] <= $signed(m1[0]) + $signed(m1[1]);
            g1_s1[1] <= $signed(m1[2]) + $signed(m1[3]);
            g1_s1[2] <= $signed(m1[4]) + $signed(m1[5]);
            g1_s1[3] <= $signed(m1[6]) + $signed(m1[7]);
            g1_s1[4] <= {m1[8][16], m1[8]};
            // Stage 2: 5 → 3
            g1_s2[0] <= $signed(g1_s1[0]) + $signed(g1_s1[1]);
            g1_s2[1] <= $signed(g1_s1[2]) + $signed(g1_s1[3]);
            g1_s2[2] <= {g1_s1[4][17], g1_s1[4]};
            // Stage 3: 3 → 2
            g1_s3[0] <= $signed(g1_s2[0]) + $signed(g1_s2[1]);
            g1_s3[1] <= {g1_s2[2][18], g1_s2[2]};
            // Stage 4: 2 → 1
            sum1     <= $signed(g1_s3[0]) + $signed(g1_s3[1]);
        end
    end

endmodule
