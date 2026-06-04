`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: cdc_pulse_sync
// Description:
//   Toggle 기반 1-bit pulse synchronizer (clock-domain crossing).
//   src_clk 의 1-cycle pulse(pulse_in) 를 dst_clk 의 1-cycle pulse(pulse_out) 로
//   안전하게 전달. 방향 무관(slow→fast / fast→slow 모두 가능).
//
//   ★ 제약: 연속 pulse_in 간 간격이 dst_clk 기준 최소 ~2 cycle 이상이어야 손실 없음.
//     본 설계의 모든 제어 pulse(start/img_ready/img_done/input_consumed)는 image 당
//     1회 수준(수백 cycle 간격) → 항상 안전.
//
//   원리:
//     src: pulse_in 마다 toggle FF(tgl) 반전 → level 로 인코딩 (edge = event)
//     dst: tgl 을 2-FF 동기(메타스테이블 resolve) + 1 지연, 상위 2단 XOR 로 edge 복원
//
//   용도 (cnn_accelerator 200MHz overclock CDC):
//     start / img_ready          : src=aclk(100) → dst=clk(200)   slow→fast (2배카운트 방지)
//     img_done / input_consumed  : src=clk(200)  → dst=aclk(100)  fast→slow (펄스 손실 방지)
//
//   ※ aclk 와 clk 는 같은 MMCM(clk_wiz) 출력이라 위상 정렬(3:1)이지만, 본 동기화기는
//     비동기 가정으로도 안전 (2-FF + toggle). 단 multi-bit 버스(BMG Port A)는 동기화기로
//     못 쓰므로 timing 제약(set_multicycle_path)으로 처리 — docs/overclock_300mhz.md 참조.
//////////////////////////////////////////////////////////////////////////////////
module cdc_pulse_sync (
    input  wire src_clk,
    input  wire src_rst,    // active-high sync reset (src 도메인)
    input  wire pulse_in,   // src_clk 1-cycle pulse

    input  wire dst_clk,
    input  wire dst_rst,    // active-high sync reset (dst 도메인)
    output wire pulse_out   // dst_clk 1-cycle pulse
);
    // --- src 도메인: event toggle ---
    reg tgl;
    always @(posedge src_clk) begin
        if (src_rst)        tgl <= 1'b0;
        else if (pulse_in)  tgl <= ~tgl;
    end

    // --- dst 도메인: 2-FF 동기 + edge 복원 ---
    (* ASYNC_REG = "TRUE" *) reg sync0, sync1;
    reg sync2;
    always @(posedge dst_clk) begin
        if (dst_rst) begin
            sync0 <= 1'b0; sync1 <= 1'b0; sync2 <= 1'b0;
        end else begin
            sync0 <= tgl;     // CDC 1st (메타 발생 가능 지점)
            sync1 <= sync0;   // CDC 2nd (resolve)
            sync2 <= sync1;   // edge 검출용 1 지연
        end
    end

    assign pulse_out = sync1 ^ sync2;   // toggle edge = 1-cycle pulse
endmodule
