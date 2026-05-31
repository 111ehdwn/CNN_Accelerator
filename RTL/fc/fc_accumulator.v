`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
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
//
//   마지막 spatial (sp143) 처리:
//     acc_last 가 fire 하는 cycle 에 sum0 = sp143 의 adder 결과이고
//     acc0_OLD 에는 sp0..sp142 만 누적된 상태. 이 cycle 에 acc0 += sp143 이
//     일어나지만, logit0 는 non-blocking 으로 acc0_OLD 만 캡처 → sp143 누락.
//     해결: logit0 <= acc0 + sum0 (combinational add) 로 sp143 contribution
//     직접 포함. acc0 update 와 동일한 식이라 자원 부담 없음.
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

                // last: 이 cycle 의 sum 이 마지막 spatial (sp143) 의 결과.
                // acc0 는 sp0..sp142 만 누적된 상태이므로 sum0 까지 더해야 완전.
                // → logit0 <= acc0 + sum0 (acc0 update 와 동일 식, 자원 공유).
                if (last) begin
                    if (clear) begin
                        // pair 1 sample 만 있는 경우 (현재 144-spatial 구조에서는 안 일어남)
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