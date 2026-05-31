`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv1_fsm
// Description:
//   - Conv1 전체 제어 FSM (active-high rst, 4-way handshake 통합)
//
//   인터페이스:
//     - rst              : active-high synchronous reset (시스템 통일)
//     - start            : legacy system-init pulse (사용 X — prior_wdone 으로 trigger)
//     - prior_wdone      : 외부에서 image 시작 trigger (입력 image 준비 알림)
//     - succ_rdone       : 외부에서 다운스트림 read 완료 알림 (Conv2.rdone direct wire)
//     - rdone            : Conv1 의 input bram read 완료 1-cycle pulse
//     - wdone            : Conv1 의 c1c2 write 완료 1-cycle pulse → Conv2.prior_wdone
//
//   Handshake counter (race-free combinational next-value 패턴):
//     prior_diff = (rdone count) - (prior_wdone count) ; data_ready = (prior_diff_next < 0)
//     after_diff = (wdone count) - (succ_rdone count)  ; output_avail = (after_diff_next < 2)
//     docs/handshake_counter_nba_race.md 참조.
//
//   동작 순서:
//     1. IDLE  : prior_wdone + output bank 여유 대기
//     2. LOAD  : weight_loader 완료 대기
//     3. RUN1  : sel=0, 28×28 스캔 (oc0~3)
//     4. FLUSH1: 파이프라인 드레인 6사이클
//     5. LBRST : line_buffer + window_register 리셋 1사이클
//     6. RUN2  : sel=1, 28×28 재스캔 (oc4~7) → 끝 시점 rdone pulse
//     7. FLUSH2: 파이프라인 드레인 6사이클
//     8. DONE  : done + wdone pulse 1사이클
//
//   파이프라인 딜레이:
//     pe_cell:       4, adder_tree: 1, truncate_relu: 1 → 총 6
//////////////////////////////////////////////////////////////////////////////////

module conv1_fsm (
    input  wire        clk,
    input  wire        rst,                  // active-high synchronous
    input  wire        start,                // legacy system init (사용 X)

    // 4-way handshake
    input  wire        prior_wdone,
    input  wire        succ_rdone,
    output reg         rdone,
    output reg         wdone,

    // weight_loader 인터페이스
    output reg         load_start,
    input  wire        load_done,

    // 파이프라인 제어
    output reg         pipe_en,
    output reg         sel,

    // line_buffer / window_register 리셋 (RUN2 진입 전 클리어)
    output reg         lb_rst,

    // 파이프라인 딜레이 보상 후 출력 주소
    output wire [4:0]  out_row,
    output wire [4:0]  out_col,
    output wire        out_valid,
    output wire        out_sel,

    output reg         done                  // legacy (debug)
);

    //==========================================================================
    // FSM 상태
    //==========================================================================
    localparam IDLE   = 4'd0;
    localparam LOAD   = 4'd1;
    localparam RUN1   = 4'd2;
    localparam FLUSH1 = 4'd3;
    localparam LBRST  = 4'd4;
    localparam RUN2   = 4'd5;
    localparam FLUSH2 = 4'd6;
    localparam DONE   = 4'd7;

    reg [3:0] state;

    //==========================================================================
    // 래스터 스캔 카운터
    //==========================================================================
    localparam IMG_W      = 28;
    localparam IMG_H      = 28;
    localparam PIPE_DELAY = 6;

    reg [4:0] row;
    reg [4:0] col;

    wire scan_done = (row == IMG_H-1) && (col == IMG_W-1);
    wire run_state = (state == RUN1) || (state == RUN2);

    always @(posedge clk) begin
        if (rst) begin
            row <= 5'd0;
            col <= 5'd0;
        end else if (state == FLUSH1 || state == FLUSH2) begin
            row <= 5'd0;
            col <= 5'd0;
        end else if (state == LBRST) begin
            row <= 5'd0;
            col <= 5'd0;
        end else if (run_state) begin
            if (col == IMG_W-1) begin
                col <= 5'd0;
                if (row == IMG_H-1)
                    row <= 5'd0;
                else
                    row <= row + 1'b1;
            end else begin
                col <= col + 1'b1;
            end
        end else begin
            row <= 5'd0;
            col <= 5'd0;
        end
    end

    //==========================================================================
    // pixel_valid: 유효 window (row>=2, col>=2). FSM 내부에서만 사용.
    //==========================================================================
    wire pixel_valid = run_state && (row >= 5'd2) && (col >= 5'd2);

    //==========================================================================
    // flush 카운터
    //==========================================================================
    reg [2:0] flush_cnt;

    //==========================================================================
    // Handshake counters (race-free combinational next value)
    //==========================================================================
    reg signed [2:0] prior_diff;
    reg signed [2:0] after_diff;
    reg signed [2:0] prior_diff_next;
    reg signed [2:0] after_diff_next;

    always @(*) begin
        case ({rdone, prior_wdone})
            2'b10:   prior_diff_next = prior_diff + 3'sd1;
            2'b01:   prior_diff_next = prior_diff - 3'sd1;
            default: prior_diff_next = prior_diff;
        endcase
        case ({wdone, succ_rdone})
            2'b10:   after_diff_next = after_diff + 3'sd1;
            2'b01:   after_diff_next = after_diff - 3'sd1;
            default: after_diff_next = after_diff;
        endcase
    end

    wire data_ready   = (prior_diff_next < 3'sd0);
    wire output_avail = (after_diff_next < 3'sd2);

    // start edge-detect (legacy)
    reg start_d;
    wire start_pulse = start & ~start_d;

    always @(posedge clk) begin
        if (rst) begin
            prior_diff <= 3'sd0;
            after_diff <= 3'sd0;
            start_d    <= 1'b0;
        end else begin
            prior_diff <= prior_diff_next;
            after_diff <= after_diff_next;
            start_d    <= start;
        end
    end

    //==========================================================================
    // FSM
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state      <= IDLE;
            load_start <= 1'b0;
            pipe_en    <= 1'b0;
            sel        <= 1'b0;
            lb_rst     <= 1'b0;
            done       <= 1'b0;
            rdone      <= 1'b0;
            wdone      <= 1'b0;
            flush_cnt  <= 3'd0;
        end else begin
            // default deasserts
            load_start <= 1'b0;
            done       <= 1'b0;
            lb_rst     <= 1'b0;
            rdone      <= 1'b0;
            wdone      <= 1'b0;

            case (state)
                //--------------------------------------------------------------
                IDLE: begin
                    pipe_en <= 1'b0;
                    sel     <= 1'b0;
                    // RUN 진입 조건: 입력 image 준비 + 출력 bank 여유
                    if ((data_ready && output_avail) || start_pulse) begin
                        load_start <= 1'b1;
                        state      <= LOAD;
                    end
                end

                //--------------------------------------------------------------
                LOAD: begin
                    pipe_en <= 1'b0;
                    if (load_done) begin
                        pipe_en <= 1'b1;
                        sel     <= 1'b0;
                        state   <= RUN1;
                    end
                end

                //--------------------------------------------------------------
                RUN1: begin
                    pipe_en <= 1'b1;
                    sel     <= 1'b0;
                    if (scan_done) begin
                        flush_cnt <= 3'd0;
                        state     <= FLUSH1;
                    end
                end

                //--------------------------------------------------------------
                FLUSH1: begin
                    pipe_en <= 1'b1;
                    sel     <= 1'b0;
                    if (flush_cnt == PIPE_DELAY-1) begin
                        pipe_en   <= 1'b0;
                        flush_cnt <= 3'd0;
                        state     <= LBRST;
                    end else begin
                        flush_cnt <= flush_cnt + 1'b1;
                    end
                end

                //--------------------------------------------------------------
                LBRST: begin
                    pipe_en <= 1'b0;
                    lb_rst  <= 1'b1;
                    sel     <= 1'b1;
                    state   <= RUN2;
                end

                //--------------------------------------------------------------
                RUN2: begin
                    pipe_en <= 1'b1;
                    sel     <= 1'b1;
                    if (scan_done) begin
                        flush_cnt <= 3'd0;
                        state     <= FLUSH2;
                        rdone     <= 1'b1;        // ★ input read 완료 알림
                    end
                end

                //--------------------------------------------------------------
                FLUSH2: begin
                    pipe_en <= 1'b1;
                    sel     <= 1'b1;
                    if (flush_cnt == PIPE_DELAY-1) begin
                        pipe_en   <= 1'b0;
                        flush_cnt <= 3'd0;
                        state     <= DONE;
                    end else begin
                        flush_cnt <= flush_cnt + 1'b1;
                    end
                end

                //--------------------------------------------------------------
                DONE: begin
                    done  <= 1'b1;
                    wdone <= 1'b1;                // ★ c1c2 write 완료 알림
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    //==========================================================================
    // 출력 주소 파이프라인 지연 (PIPE_DELAY 사이클)
    //==========================================================================
    reg        valid_sr [0:PIPE_DELAY-1];
    reg [4:0]  row_sr   [0:PIPE_DELAY-1];
    reg [4:0]  col_sr   [0:PIPE_DELAY-1];
    reg        sel_sr   [0:PIPE_DELAY-1];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < PIPE_DELAY; i = i + 1) begin
                valid_sr[i] <= 1'b0;
                row_sr[i]   <= 5'd0;
                col_sr[i]   <= 5'd0;
                sel_sr[i]   <= 1'b0;
            end
        end else begin
            valid_sr[0] <= pixel_valid;
            row_sr[0]   <= (row >= 5'd2) ? (row - 5'd2) : 5'd0;
            col_sr[0]   <= (col >= 5'd2) ? (col - 5'd2) : 5'd0;
            sel_sr[0]   <= sel;

            for (i = 1; i < PIPE_DELAY; i = i + 1) begin
                valid_sr[i] <= valid_sr[i-1];
                row_sr[i]   <= row_sr[i-1];
                col_sr[i]   <= col_sr[i-1];
                sel_sr[i]   <= sel_sr[i-1];
            end
        end
    end

    assign out_valid = valid_sr[PIPE_DELAY-1];
    assign out_row   = row_sr  [PIPE_DELAY-1];
    assign out_col   = col_sr  [PIPE_DELAY-1];
    assign out_sel   = sel_sr  [PIPE_DELAY-1];

endmodule
