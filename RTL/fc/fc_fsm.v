`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_simd_fsm
// Description:
//   FC SIMD FSM (20 DSP 제약 버전).
//
//   구조:
//     5 pair (OC 0~9) 를 순차 처리, pair 당 144 spatial cycle.
//     총 COMPUTE = 5 × 144 = 720 cycle (기존 1440 대비 2배 단축).
//
//   카운터:
//     s_cnt    : 0..143 (spatial, 매 cycle 증가)
//     pair_cnt : 0..4   (현재 OC pair)
//
//   Weight BRAM 주소:
//     addrb = pair_cnt * 144 + s_cnt (0..719)
//     → wbase = pair_cnt * 144 (누산), addrb = wbase + s_cnt
//     BRAM 구성: 128-bit × 720 (기존 1440 대신 720 depth)
//               각 addr 에 w0(16ch)+w1(16ch) = 128-bit 저장
//
//   출력:
//     s_cnt, pair_cnt, wbase : datapath 주소 생성용
//     comp_v    : COMPUTE 중 매 cycle
//     s_first   : s_cnt == 0 (acc clear)
//     s_last    : s_cnt == 143 (acc last → logit valid)
//     pair_done : s_last 와 동일 (argmax 에 pair 완료 통지)
//
//   Pipeline depth: BRAM 2 + pe 2 + adder 4 + acc 1 = 9
//   DRAIN: 9 cycle
//////////////////////////////////////////////////////////////////////////////////

module fc_fsm (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,

    // Handshake
    input  wire        prior_wdone,
    output reg         rdone,
    output reg         input_bank_sel,

    // Datapath
    output reg  [7:0]  s_cnt,
    output reg  [2:0]  pair_cnt,
    output reg  [9:0]  wbase,      // pair_cnt * 144 (누산)

    output reg         comp_v,
    output reg         s_first,
    output reg         s_last,

    output reg         busy
);

    localparam [1:0] IDLE    = 2'd0;
    localparam [1:0] COMPUTE = 2'd1;
    localparam [1:0] DRAIN   = 2'd2;
    localparam [1:0] DONE    = 2'd3;

    // Pipeline depth: BRAM 2 + pe_cell 2 + adder 4 + acc 1 = 9
    localparam [3:0] DRAIN_MAX = 4'd9;

    reg [1:0] state;
    reg [3:0] drain_cnt;

    reg signed [2:0] prior_diff;
    wire data_ready = (prior_diff < 3'sd0);

    //==========================================================================
    // State + counter
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            s_cnt     <= 8'd0;
            pair_cnt  <= 3'd0;
            wbase     <= 10'd0;
            drain_cnt <= 4'd0;
        end else begin
            case (state)
                IDLE: begin
                    s_cnt    <= 8'd0;
                    pair_cnt <= 3'd0;
                    wbase    <= 10'd0;
                    if (start && data_ready)
                        state <= COMPUTE;
                end

                COMPUTE: begin
                    if (s_cnt == 8'd143) begin
                        s_cnt <= 8'd0;
                        if (pair_cnt == 3'd4) begin
                            // 마지막 pair 완료 → DRAIN
                            pair_cnt  <= 3'd0;
                            wbase     <= 10'd0;
                            state     <= DRAIN;
                            drain_cnt <= 4'd0;
                        end else begin
                            pair_cnt <= pair_cnt + 3'd1;
                            wbase    <= wbase + 10'd144;
                        end
                    end else begin
                        s_cnt <= s_cnt + 8'd1;
                    end
                end

                DRAIN: begin
                    if (drain_cnt == DRAIN_MAX - 4'd1) begin
                        state     <= DONE;
                        drain_cnt <= 4'd0;
                    end else begin
                        drain_cnt <= drain_cnt + 4'd1;
                    end
                end

                DONE:    state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end

    //==========================================================================
    // Datapath strobes (combinational)
    //==========================================================================
    always @(*) begin
        comp_v  = 1'b0;
        s_first = 1'b0;
        s_last  = 1'b0;
        busy    = (state == COMPUTE) || (state == DRAIN);

        if (state == COMPUTE) begin
            comp_v  = 1'b1;
            s_first = (s_cnt == 8'd0);
            s_last  = (s_cnt == 8'd143);
        end
    end

    //==========================================================================
    // rdone: 마지막 pair 마지막 spatial issue 직후
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            rdone <= 1'b0;
        else
            rdone <= (state == COMPUTE) && (pair_cnt == 3'd4) && (s_cnt == 8'd143);
    end

    //==========================================================================
    // Handshake + bank toggle
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            prior_diff <= 3'sd0;
        else begin
            case ({rdone, prior_wdone})
                2'b10:   prior_diff <= prior_diff + 3'sd1;
                2'b01:   prior_diff <= prior_diff - 3'sd1;
                default: prior_diff <= prior_diff;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst)
            input_bank_sel <= 1'b0;
        else if (rdone)
            input_bank_sel <= ~input_bank_sel;
    end

endmodule