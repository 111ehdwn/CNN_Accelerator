`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Description:
<<<<<<< HEAD
//   FC argmax - pipelined tournament tree (300MHz timing 대응).
=======
//   FC argmax — pipelined tournament tree (200MHz timing 대응).
>>>>>>> dohyun
//
//   [설계 의도]
//     기존 1-cycle combinational 10-way 비교는 24-bit 비교기 9단이 직렬로 풀려
//     100MHz 에서도 setup 위반(-8.6ns)이었다. 200MHz(5.0ns)를 노리려면 각
//     register-to-register 경로에 "24-bit 비교기 1개" 만 남겨야 한다.
//
//     → 10→5→3→2→1 의 4-round 토너먼트로 분해, round 마다 register.
//       각 stage 의 critical path = (레지스터 출력) → 24-bit signed 비교 1개
//       → 2:1 mux → (레지스터). 입력 mux 가 비교 경로에 없으므로 가장 짧다.
//
//   [tie-break]
//     candidate = {idx[3:0], val[ACC_W-1:0]}. 페어링을 left 가 항상 더 낮은
//     원본 인덱스를 갖도록 구성(아래 트리), 비교는 strict '>' 로 동률 시 left
//     유지 → "낮은 인덱스 우선". 기존 combinational 루프와 bit-exact 동일.
//
//   Latency  : in_valid 후 4 cycle 뒤 done(1-cycle pulse).
//   가정     : logit_flat 은 비교 구간 동안 stable (engine 의 logit_reg 유지).
////////////////////////////////////////////////////////////////////////////////////

module fc_argmax #(
    parameter ACC_W   = 24,
    parameter N_CLASS = 10               // 트리 구조는 10 고정
)(
    input  wire                       clk,
    input  wire                       rst,

    input  wire                       in_valid,    // 1-cycle pulse: N_CLASS logit 준비 완료
    input  wire [N_CLASS*ACC_W-1:0]   logit_flat,  // N_CLASS × ACC_W-bit signed

    output reg  [3:0]                 class_idx,
    output reg                        done
);

    localparam CW = ACC_W + 4;           // candidate = {idx[3:0], val[ACC_W-1:0]}

    //--------------------------------------------------------------------------
    // 두 candidate 중 val 이 큰 쪽 선택. 동률이면 a(=left, 더 낮은 idx) 유지.
    //   a : 항상 더 낮은 원본 인덱스 (트리 페어링 규칙으로 보장)
    //   b : 항상 더 높은 원본 인덱스
    //--------------------------------------------------------------------------
    function [CW-1:0] pick;
        input [CW-1:0] a;
        input [CW-1:0] b;
        reg signed [ACC_W-1:0] av, bv;
        begin
            av   = a[ACC_W-1:0];
            bv   = b[ACC_W-1:0];
            pick = (bv > av) ? b : a;    // strict '>' → tie 는 a(낮은 idx)
        end
    endfunction

    // 입력 candidate: {idx, val}
    wire [CW-1:0] cand [0:N_CLASS-1];
    genvar gi;
    generate
        for (gi = 0; gi < N_CLASS; gi = gi + 1) begin : g_cand
            localparam [3:0] IDXg = gi[3:0];
            assign cand[gi] = { IDXg, logit_flat[gi*ACC_W +: ACC_W] };
        end
    endgenerate

    //--------------------------------------------------------------------------
    // 파이프라인 레지스터 (round 출력)
    //--------------------------------------------------------------------------
    reg [CW-1:0] r1 [0:4];   // round1 : 10 → 5   pairs (0,1)(2,3)(4,5)(6,7)(8,9)
    reg [CW-1:0] r2 [0:2];   // round2 : 5  → 3   pairs (0,1)(2,3) + 4 passthrough
    reg [CW-1:0] r3 [0:1];   // round3 : 3  → 2   pairs (0,1)     + 2 passthrough
    reg          v1, v2, v3; // valid pipe (in_valid 정렬)

    // round4 : 2 → 1  (left r3[0] idx≤7  <  right r3[1] idx∈{8,9})
    wire [CW-1:0] r4_win = pick(r3[0], r3[1]);

    integer j;
    always @(posedge clk) begin
        if (rst) begin
            for (j = 0; j < 5; j = j + 1) r1[j] <= {CW{1'b0}};
            for (j = 0; j < 3; j = j + 1) r2[j] <= {CW{1'b0}};
            for (j = 0; j < 2; j = j + 1) r3[j] <= {CW{1'b0}};
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
            class_idx <= 4'd0;
            done      <= 1'b0;
        end else begin
            // round1 (left idx < right idx 유지)
            r1[0] <= pick(cand[0], cand[1]);
            r1[1] <= pick(cand[2], cand[3]);
            r1[2] <= pick(cand[4], cand[5]);
            r1[3] <= pick(cand[6], cand[7]);
            r1[4] <= pick(cand[8], cand[9]);
            // round2
            r2[0] <= pick(r1[0], r1[1]);   // idx 0..3
            r2[1] <= pick(r1[2], r1[3]);   // idx 4..7
            r2[2] <= r1[4];                // idx 8..9 passthrough
            // round3
            r3[0] <= pick(r2[0], r2[1]);   // idx 0..7
            r3[1] <= r2[2];                // idx 8..9 passthrough
            // round4 → 결과 확정
            class_idx <= r4_win[CW-1 -: 4];

            // valid pipe + done (class_idx 와 동일 edge 정렬)
            v1   <= in_valid;
            v2   <= v1;
            v3   <= v2;
            done <= v3;
        end
    end

endmodule
