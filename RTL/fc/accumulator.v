`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_simd_accumulator
// Description:
//   FC SIMD 누산기.
//   현재 pair 의 2 OC(even/odd) 를 144 spatial 동안 누산.
//   s_last 사이클에 마지막 partial sum 까지 포함한 최종값을 logit0/1 에 출력하고
//   logit_valid 를 1-cycle pulse 로 올림.
//
//   pair 0→4 에 걸쳐 총 5번 logit_valid 가 발생하며,
//   engine 상위에서 10개 logit 을 레지스터에 누적한 뒤 argmax 에 1회 전달.
//
//   Latency:
//     en && last 가 assert 된 바로 그 edge 에서
//     acc + sum 의 최종값을 logit0/1 에 동시에 latch하고
//     logit_valid 도 같은 edge 에서 1로 세팅.
//     (상위에서는 logit_valid=1 인 cycle 에 logit0/1 을 캡처하면 됨)
//////////////////////////////////////////////////////////////////////////////////

module fc_accumulator #(
    parameter ACC_W = 24
)(
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    en,
    input  wire                    clear,    // s_first 정렬 신호 (acc 초기화)
    input  wire                    last,     // s_last  정렬 신호 (최종값 출력)

    input  wire signed [19:0]      sum0,     // OC_even partial sum
    input  wire signed [19:0]      sum1,     // OC_odd  partial sum

    output reg  signed [ACC_W-1:0] logit0,   // OC_even 최종 logit
    output reg  signed [ACC_W-1:0] logit1,   // OC_odd  최종 logit
    output reg                     logit_valid  // 1-cycle pulse (pair 완료)
);

    reg signed [ACC_W-1:0] acc0, acc1;

    always @(posedge clk) begin
        if (rst) begin
            acc0        <= {ACC_W{1'b0}};
            acc1        <= {ACC_W{1'b0}};
            logit0      <= {ACC_W{1'b0}};
            logit1      <= {ACC_W{1'b0}};
            logit_valid <= 1'b0;
        end else begin
            logit_valid <= 1'b0;   // default: deassert

            if (en) begin
                // 누산
                if (clear) begin
                    acc0 <= $signed(sum0);
                    acc1 <= $signed(sum1);
                end else begin
                    acc0 <= acc0 + $signed(sum0);
                    acc1 <= acc1 + $signed(sum1);
                end

                // last: 현재 edge 의 sum 이 마지막 → 최종값 = acc(이전) + sum
                // clear 와 last 가 동시에 올 수 있는 경우(144=1, 실제 없음)도 처리
                if (last) begin
                    if (clear) begin
                        logit0 <= $signed(sum0);
                        logit1 <= $signed(sum1);
                    end else begin
                        logit0 <= acc0 + $signed(sum0);
                        logit1 <= acc1 + $signed(sum1);
                    end
                    logit_valid <= 1'b1;
                end
            end
        end
    end

endmodule