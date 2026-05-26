`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_simd_adder_tree
// Description:
//   FC SIMD 16:1 adder tree × 2 OC (현재 처리 중인 pair의 even/odd).
//   4-stage pipeline, 1 result/cycle throughput.
//
//   입력: p0_flat/p1_flat [255:0] (16 × 16-bit signed product)
//   출력: sum0/sum1       [19:0]  (20-bit signed partial sum)
//
//   Latency: 4 cycle
//////////////////////////////////////////////////////////////////////////////////

module fc_adder_tree (
    input  wire         clk,
    input  wire         rst,
    input  wire         en,

    input  wire [255:0] p0_flat,   // OC_even 16 × 16b
    input  wire [255:0] p1_flat,   // OC_odd  16 × 16b

    output reg signed [19:0] sum0, // OC_even partial sum
    output reg signed [19:0] sum1  // OC_odd  partial sum
);

    // 입력 unpack
    wire signed [15:0] p0 [0:15];
    wire signed [15:0] p1 [0:15];
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : unpack
            assign p0[gi] = p0_flat[gi*16 +: 16];
            assign p1[gi] = p1_flat[gi*16 +: 16];
        end
    endgenerate

    // --- OC_even tree ---
    reg signed [16:0] e1 [0:7];
    reg signed [17:0] e2 [0:3];
    reg signed [18:0] e3 [0:1];

    // --- OC_odd tree ---
    reg signed [16:0] o1 [0:7];
    reg signed [17:0] o2 [0:3];
    reg signed [18:0] o3 [0:1];

    integer i;

    // Stage 1
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 8; i = i + 1) begin
                e1[i] <= 17'sd0;
                o1[i] <= 17'sd0;
            end
        end else if (en) begin
            for (i = 0; i < 8; i = i + 1) begin
                e1[i] <= p0[i*2] + p0[i*2+1];
                o1[i] <= p1[i*2] + p1[i*2+1];
            end
        end
    end

    // Stage 2
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 4; i = i + 1) begin
                e2[i] <= 18'sd0;
                o2[i] <= 18'sd0;
            end
        end else if (en) begin
            for (i = 0; i < 4; i = i + 1) begin
                e2[i] <= e1[i*2] + e1[i*2+1];
                o2[i] <= o1[i*2] + o1[i*2+1];
            end
        end
    end

    // Stage 3
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 2; i = i + 1) begin
                e3[i] <= 19'sd0;
                o3[i] <= 19'sd0;
            end
        end else if (en) begin
            for (i = 0; i < 2; i = i + 1) begin
                e3[i] <= e2[i*2] + e2[i*2+1];
                o3[i] <= o2[i*2] + o2[i*2+1];
            end
        end
    end

    // Stage 4
    always @(posedge clk) begin
        if (rst) begin
            sum0 <= 20'sd0;
            sum1 <= 20'sd0;
        end else if (en) begin
            sum0 <= e3[0] + e3[1];
            sum1 <= o3[0] + o3[1];
        end
    end

endmodule