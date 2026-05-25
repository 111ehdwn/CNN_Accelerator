`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: krow_ic_adder_tree
// Description:
//   24:1 signed adder tree (5-stage pipeline, 200 MHz target)
//
//   입력: 24개 17-bit signed (K_row 3 × IC 8개의 PE 출력)
//   출력: 1개 22-bit signed (모두 합)
//
//   비트 폭 계산:
//     17-bit 24개 합: 17 + ceil(log2(24)) = 17 + 5 = 22-bit
//
//   Stage 구조 (각 stage 1-cycle pipeline register):
//     Stage 1: 24 → 12 (12 adders, 17+17 → 18-bit)
//     Stage 2: 12 → 6  (6 adders, 18+18 → 19-bit)
//     Stage 3: 6 → 3   (3 adders, 19+19 → 20-bit)
//     Stage 4: 3 → 2   (1 adder + 1 pass-through, 20→21-bit)
//     Stage 5: 2 → 1   (1 adder, 21+21 → 22-bit)
//
//   Total latency: 5 cycle (input → output)
//   Throughput: 1 result/cycle (en=1 동안)
//
//   16개 instance 병렬 (OC_pair=8 × SIMD=2)
//   각 instance가 같은 (OC_pair, SIMD) 조합의 K_row × IC = 24개 합산
//
//   사용 자원 추정:
//     Stage 1: 12 × 18-bit adder ~ 216 LUT
//     Stage 2: 6 × 19-bit adder ~ 114 LUT
//     Stage 3: 3 × 20-bit adder ~ 60 LUT
//     Stage 4: 1 × 21-bit adder + pass ~ 21 LUT
//     Stage 5: 1 × 22-bit adder ~ 22 LUT
//     Total: ~433 LUT per instance, 16 instances ~ 7K LUT
//     Pipeline FF: ~(12*18 + 6*19 + 3*20 + 2*21 + 1*22) = 414 FF per instance
//                  16 instances ~ 6.6K FF
//////////////////////////////////////////////////////////////////////////////////

module krow_ic_adder_tree (
    input  wire                clk,
    input  wire                rst,
    input  wire                en,           // pipeline enable

    //==========================================================================
    // 입력: 24개 17-bit signed (packed 1D)
    //   in_flat[i*17 +: 17] = i번째 input (i = 0..23)
    //   순서: (K_row, IC) 평탄화 (예: i = kr*8 + ic, 또는 ic*3 + kr)
    //   conv2_engine에서 일관성만 유지하면 무관
    //==========================================================================
    input  wire [24*17-1:0]    in_flat,

    //==========================================================================
    // 출력: 22-bit signed 합
    //==========================================================================
    output reg signed [21:0]   sum
);

    //==========================================================================
    // 1. 입력 unpack (24개 17-bit signed)
    //==========================================================================
    wire signed [16:0] in_arr [0:23];

    genvar gi;
    generate
        for (gi = 0; gi < 24; gi = gi + 1) begin : unpack
            assign in_arr[gi] = in_flat[gi*17 +: 17];
        end
    endgenerate

    //==========================================================================
    // 2. Stage 1: 24 → 12 (12 adders, 17+17 → 18-bit)
    //==========================================================================
    reg signed [17:0] s1 [0:11];

    integer i1;
    always @(posedge clk) begin
        if (rst) begin
            for (i1 = 0; i1 < 12; i1 = i1 + 1)
                s1[i1] <= 18'sd0;
        end else if (en) begin
            for (i1 = 0; i1 < 12; i1 = i1 + 1)
                s1[i1] <= in_arr[i1*2] + in_arr[i1*2 + 1];
        end
    end

    //==========================================================================
    // 3. Stage 2: 12 → 6 (6 adders, 18+18 → 19-bit)
    //==========================================================================
    reg signed [18:0] s2 [0:5];

    integer i2;
    always @(posedge clk) begin
        if (rst) begin
            for (i2 = 0; i2 < 6; i2 = i2 + 1)
                s2[i2] <= 19'sd0;
        end else if (en) begin
            for (i2 = 0; i2 < 6; i2 = i2 + 1)
                s2[i2] <= s1[i2*2] + s1[i2*2 + 1];
        end
    end

    //==========================================================================
    // 4. Stage 3: 6 → 3 (3 adders, 19+19 → 20-bit)
    //==========================================================================
    reg signed [19:0] s3 [0:2];

    integer i3;
    always @(posedge clk) begin
        if (rst) begin
            for (i3 = 0; i3 < 3; i3 = i3 + 1)
                s3[i3] <= 20'sd0;
        end else if (en) begin
            for (i3 = 0; i3 < 3; i3 = i3 + 1)
                s3[i3] <= s2[i3*2] + s2[i3*2 + 1];
        end
    end

    //==========================================================================
    // 5. Stage 4: 3 → 2
    //   s4[0] = s3[0] + s3[1]   (21-bit)
    //   s4[1] = s3[2]           (20→21-bit sign-extend)
    //==========================================================================
    reg signed [20:0] s4 [0:1];

    always @(posedge clk) begin
        if (rst) begin
            s4[0] <= 21'sd0;
            s4[1] <= 21'sd0;
        end else if (en) begin
            s4[0] <= s3[0] + s3[1];
            s4[1] <= {s3[2][19], s3[2]};   // sign-extend
        end
    end

    //==========================================================================
    // 6. Stage 5: 2 → 1 (1 adder, 21+21 → 22-bit)
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            sum <= 22'sd0;
        else if (en)
            sum <= s4[0] + s4[1];
    end

endmodule