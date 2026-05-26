`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_simd_argmax
// Description:
//   FC SIMD 병렬 argmax.
//   engine 에서 10개 logit 이 모두 준비된 뒤 in_valid=1 과 함께
//   logit_flat[239:0] (10 × 24-bit signed) 을 한꺼번에 받아 비교.
//
//   동작:
//     in_valid=1 : logit_flat 에서 combinational 최댓값 탐색
//                  → 다음 edge 에 class_idx / done 확정.
//
//   Latency: 1 cycle (in_valid → done)
//////////////////////////////////////////////////////////////////////////////////

module fc_argmax #(
    parameter ACC_W = 24
)(
    input  wire                    clk,
    input  wire                    rst,

    input  wire                    in_valid,          // 1-cycle pulse: 10개 logit 준비 완료
    input  wire [10*ACC_W-1:0]     logit_flat,        // 10 × ACC_W-bit signed

    output reg  [3:0]              class_idx,
    output reg                     done
);

    // unpack
    wire signed [ACC_W-1:0] logit [0:9];
    genvar gi;
    generate
        for (gi = 0; gi < 10; gi = gi + 1) begin : unpack
            assign logit[gi] = logit_flat[gi*ACC_W +: ACC_W];
        end
    endgenerate

    // combinational 비교 트리 (10개 순차, 합성 시 병렬 최적화)
    reg [3:0]              best_idx_c;
    reg signed [ACC_W-1:0] best_val_c;

    integer oc;
    always @(*) begin
        best_idx_c = 4'd0;
        best_val_c = logit[0];
        for (oc = 1; oc < 10; oc = oc + 1) begin
            if (logit[oc] > best_val_c) begin
                best_val_c = logit[oc];
                best_idx_c = oc[3:0];
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            class_idx <= 4'd0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;
            if (in_valid) begin
                class_idx <= best_idx_c;
                done      <= 1'b1;
            end
        end
    end

endmodule