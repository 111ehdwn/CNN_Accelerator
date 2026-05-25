`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: kcol_accumulator
// Description:
//   한 output pixel의 K_col 0, 1, 2 contributions를 3 cycle 동안 누적.
//   krow_ic_adder_tree 출력(22-bit signed)을 받아 24-bit signed로 누적.
//
//   동작:
//     kw_phase=0: out = in              (첫 값, reset 효과)
//     kw_phase=1: out = out + in        (누적)
//     kw_phase=2: out = out + in        (최종), out_valid pulse
//
//   비트 폭 분석:
//     입력: 22-bit signed (krow_ic_adder_tree 출력)
//     3개 누적: 22 + ceil(log2(3)) = 22 + 2 = 24-bit signed
//
//   kw_phase 신호:
//     FSM의 sel을 (PE + adder_tree) latency만큼 지연한 값
//     conv2_engine.v에서 shift register로 생성하여 입력
//     → 본 모듈은 단순히 phase에 따라 reset/accumulate
//
//   en 신호:
//     pipeline enable (pe_en을 동일하게 지연한 값)
//     en=1일 때만 누적 동작
//
//   out_valid:
//     kw_phase=2 && en=1일 때 1-cycle pulse
//     다음 stage (truncate_relu)의 enable로 사용
//
//   16개 instance 병렬 (OC_pair=8 × SIMD=2)
//
//   Latency: 1 cycle (input → output register)
//   Throughput: 매 cycle 1 누적 동작 (3 cycle에 1 output)
//////////////////////////////////////////////////////////////////////////////////

module kcol_accumulator (
    input  wire                clk,
    input  wire                rst,
    input  wire                en,           // pipeline enable

    //==========================================================================
    // 입력: 22-bit signed (krow_ic_adder_tree 출력)
    //==========================================================================
    input  wire signed [21:0]  in,

    //==========================================================================
    // K_col phase (외부에서 sel을 지연하여 입력)
    //   0: first (reset 효과, out = in)
    //   1: middle (accumulate)
    //   2: last (accumulate + valid)
    //==========================================================================
    input  wire        [1:0]   kw_phase,

    //==========================================================================
    // 출력: 24-bit signed accumulated value
    //==========================================================================
    output reg signed  [23:0]  out,

    //==========================================================================
    // 출력 valid pulse (kw_phase=2 시점에 1-cycle)
    //==========================================================================
    output reg                 out_valid
);

    //==========================================================================
    // Accumulator logic
    //
    //   Sign-extension은 Verilog signed semantic으로 자동 (in: 22-bit → 24-bit)
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            out       <= 24'sd0;
            out_valid <= 1'b0;
        end else if (en) begin
            case (kw_phase)
                2'd0: out <= in;            // first: reset + 첫 누적
                2'd1: out <= out + in;      // middle: 누적
                2'd2: out <= out + in;      // last: 최종 누적
                default: out <= out;
            endcase

            out_valid <= (kw_phase == 2'd2);
        end else begin
            out_valid <= 1'b0;
            // out은 hold (en=0일 때 변화 없음)
        end
    end

endmodule