`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: cdc_bit_sync
// Description:
//   2-FF level synchronizer (clock-domain crossing). 느리게 변하는 level 신호를
//   dst_clk 도메인으로 안전 전달. (1-cycle pulse 동기화 아님 — pulse 는 cdc_pulse_sync.)
//   용도 (cnn_accelerator 200MHz overclock): enable (CSR 100 → datapath 200).
//////////////////////////////////////////////////////////////////////////////////
module cdc_bit_sync #(
    parameter STAGES = 2
)(
    input  wire dst_clk,
    input  wire dst_rst,    // active-high sync reset
    input  wire d_in,       // 타 도메인 level (비동기)
    output wire d_out
);
    (* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] sync;
    always @(posedge dst_clk) begin
        if (dst_rst) sync <= {STAGES{1'b0}};
        else         sync <= {sync[STAGES-2:0], d_in};
    end
    assign d_out = sync[STAGES-1];
endmodule
