`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_fsm
// Description:
//   FC layer FSM for input layout: input BRAM width = 16*8 = 128-bit,
//   depth = 144 spatial words.
//
//   Weight BRAM layout:
//     width = 256-bit, depth = 720
//     addr  = pair_cnt * 144 + s_cnt
//     LSB [127:0]   = even output column weights, 16ch
//     MSB [255:128] = odd  output column weights, 16ch
//
//   Operation:
//     5 output pairs are processed sequentially.
//     Each pair scans 144 spatial addresses.
//     Total compute issue cycles = 5 * 144 = 720.
//////////////////////////////////////////////////////////////////////////////////

module fc_fsm (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,                // legacy system arm pulse (init 용)

    // Handshake with previous ping-pong buffer (maxpool / poolfc)
    input  wire        prior_wdone,
    output reg         rdone,
    output reg         input_bank_sel,

    // Datapath counters
    output reg  [7:0]  s_cnt,       // 0..143
    output reg  [2:0]  pair_cnt,    // 0..4
    output reg  [9:0]  wbase,       // pair_cnt * 144

    output reg         comp_v,
    output reg         s_first,
    output reg         s_last,

    output reg         busy
);

    localparam [1:0] IDLE    = 2'd0;
    localparam [1:0] COMPUTE = 2'd1;
    localparam [1:0] DRAIN   = 2'd2;
    localparam [1:0] DONE    = 2'd3;

    localparam [7:0] SPATIAL_LAST = 8'd143;
    localparam [9:0] WBASE_STEP   = 10'd144;

    // Datapath latency drain margin.
    // Engine aligns control internally; this just keeps busy long enough after last issue.
    localparam [3:0] DRAIN_MAX = 4'd10;   // PE 2→4 cycle (+2): datapath drain margin 확대

    reg [1:0] state;
    reg [3:0] drain_cnt;

    //==========================================================================
    // Handshake counter (race-free, conv2 / maxpool 패턴 차용)
    //
    // NBA 의 1-cycle 지연으로 인한 race 회피:
    //   - prior_diff 자체는 register (NBA 로 update)
    //   - data_ready 는 *combinational* prior_diff_next 기준으로 평가
    //   - 같은 cycle 에 rdone 가 high 가 되어도, prior_diff_next 가 즉시 반영
    //     → IDLE 의 transition check 가 정확한 값 사용
    //
    // FC 는 terminal layer 이므로 output 측 handshake 없음.
    // ready_to_compute = data_ready (= output_avail 1'b1 고정).
    //
    // 상세 분석: docs/handshake_counter_nba_race.md
    //==========================================================================
    reg signed [2:0] prior_diff;
    reg signed [2:0] prior_diff_next;

    always @(*) begin
        case ({rdone, prior_wdone})
            2'b10:   prior_diff_next = prior_diff + 3'sd1;
            2'b01:   prior_diff_next = prior_diff - 3'sd1;
            2'b11:   prior_diff_next = prior_diff;
            default: prior_diff_next = prior_diff;
        endcase
    end

    wire data_ready       = (prior_diff_next < 3'sd0);
    wire output_avail     = 1'b1;                          // FC=terminal: 항상 true
    wire ready_to_compute = data_ready && output_avail;

    //==========================================================================
    // start edge-detect — system arm pulse (init 용 backup trigger).
    //
    //   conv1 / maxpool 패턴: 첫 image 진입 전 PS 가 한 번 pulse 하면 즉시 COMPUTE 진입.
    //   이후 image 는 prior_wdone 만으로 자동 trigger (data_ready 가 다음 cycle 에 true).
    //
    //   level signal 직접 사용 시 high 가 여러 cycle 지속되면 재트리거 위험 → edge-detect.
    //==========================================================================
    reg start_d;
    wire start_pulse = start & ~start_d;

    always @(posedge clk) begin
        if (rst) start_d <= 1'b0;
        else     start_d <= start;
    end

    //==========================================================================
    // State + counters
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
                //--------------------------------------------------------------
                // IDLE: 새 image 대기.
                //   - ready_to_compute (= data_ready, prior_wdone 도착) 또는
                //   - start_pulse (system arm) 이면 즉시 COMPUTE 진입.
                //   - conv1 / maxpool 패턴 정합 — image-by-image trigger 는 handshake 만.
                //--------------------------------------------------------------
                IDLE: begin
                    s_cnt     <= 8'd0;
                    pair_cnt  <= 3'd0;
                    wbase     <= 10'd0;
                    drain_cnt <= 4'd0;
                    if (ready_to_compute || start_pulse)
                        state <= COMPUTE;
                end

                COMPUTE: begin
                    if (s_cnt == SPATIAL_LAST) begin
                        s_cnt <= 8'd0;

                        if (pair_cnt == 3'd4) begin
                            pair_cnt  <= 3'd0;
                            wbase     <= 10'd0;
                            drain_cnt <= 4'd0;
                            state     <= DRAIN;
                        end else begin
                            pair_cnt <= pair_cnt + 3'd1;
                            wbase    <= wbase + WBASE_STEP;
                        end
                    end else begin
                        s_cnt <= s_cnt + 8'd1;
                    end
                end

                DRAIN: begin
                    if (drain_cnt == DRAIN_MAX - 4'd1) begin
                        drain_cnt <= 4'd0;
                        state     <= DONE;
                    end else begin
                        drain_cnt <= drain_cnt + 4'd1;
                    end
                end

                DONE: begin
                    state <= IDLE;
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

    //==========================================================================
    // Datapath strobes
    //==========================================================================
    always @(*) begin
        comp_v  = 1'b0;
        s_first = 1'b0;
        s_last  = 1'b0;
        busy    = (state == COMPUTE) || (state == DRAIN);

        if (state == COMPUTE) begin
            comp_v  = 1'b1;
            s_first = (s_cnt == 8'd0);
            s_last  = (s_cnt == SPATIAL_LAST);
        end
    end

    //==========================================================================
    // rdone: one pulse when the last input bank has been consumed.
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            rdone <= 1'b0;
        else
            rdone <= (state == COMPUTE) && (pair_cnt == 3'd4) && (s_cnt == SPATIAL_LAST);
    end

    //==========================================================================
    // Handshake counter register update (next value 그대로 NBA)
    //   prior_wdone increments available written banks.
    //   rdone consumes one readable bank.
    //   *_next 는 위에서 combinational 으로 계산 — race-free.
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            prior_diff <= 3'sd0;
        else
            prior_diff <= prior_diff_next;
    end

    always @(posedge clk) begin
        if (rst)
            input_bank_sel <= 1'b0;
        else if (rdone)
            input_bank_sel <= ~input_bank_sel;
    end

endmodule
