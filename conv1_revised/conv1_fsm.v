`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv1_fsm
// Description:
//   - Conv1 전체 제어 FSM
//
//   동작 순서:
//     1. IDLE  : start 대기
//     2. LOAD  : weight_loader 완료 대기
//     3. RUN1  : sel=0, 입력 이미지 28×28 스캔 (oc0~3 계산)
//     4. FLUSH1: 파이프라인 드레인 6사이클
//     5. RESET : line_buffer + window_register 리셋 1사이클 (RUN2 준비)
//     6. RUN2  : sel=1, 입력 이미지 28×28 재스캔 (oc4~7 계산)
//     7. FLUSH2: 파이프라인 드레인 6사이클
//     8. DONE  : done 펄스 1사이클
//
//   버그 수정:
//     - FLUSH 구간에서 row/col 리셋 → RUN1 마지막 데이터 flush 불가 문제 제거
//       (FLUSH 구간은 row/col 카운터 멈춤, pipe_en=1 유지)
//     - RUN2 진입 전 lb_rst=1 1사이클로 line_buffer, window_register 클리어
//       (RUN1 데이터 오염 방지)
//     - in_addr 재사용: RUN2 시 0부터 재스캔 가능하도록 engine 측에서
//       lb_rst와 연동하여 in_addr 리셋
//
//   파이프라인 딜레이:
//     pe_cell:        4사이클 (DSP 3 + 출력 레지스터 1)
//     adder_tree:     1사이클
//     truncate_relu:  1사이클
//     총:             6사이클
//
//   pixel_valid 조건:
//     row >= 2 && col >= 2 (28×28 입력, 3×3 커널, 패딩 없음)
//////////////////////////////////////////////////////////////////////////////////

module conv1_fsm (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,

    // weight_loader 인터페이스
    output reg         load_start,
    input  wire        load_done,

    // 파이프라인 제어
    output reg         pipe_en,
    output reg         sel,

    // line_buffer / window_register 리셋 (RUN2 진입 전 클리어)
    output reg         lb_rst,

    // pixel_valid: 유효 window (row>=2, col>=2)
    output wire        pixel_valid,

    // 파이프라인 딜레이 보상 후 출력 주소
    output wire [4:0]  out_row,
    output wire [4:0]  out_col,
    output wire        out_valid,
    output wire        out_sel,

    output reg         done
);

    //==========================================================================
    // FSM 상태
    //==========================================================================
    localparam IDLE   = 4'd0;
    localparam LOAD   = 4'd1;
    localparam RUN1   = 4'd2;
    localparam FLUSH1 = 4'd3;
    localparam LBRST  = 4'd4;   // ★ 추가: lb/win 리셋 1사이클
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
            // flush: 카운터 정지 (마지막 위치 유지, 필요 없으니 0으로)
            row <= 5'd0;
            col <= 5'd0;
        end else if (state == LBRST) begin
            // lb_rst 사이클: 카운터 0 유지
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
    // pixel_valid
    //==========================================================================
    assign pixel_valid = run_state && (row >= 5'd2) && (col >= 5'd2);

    //==========================================================================
    // flush 카운터
    //==========================================================================
    reg [2:0] flush_cnt;

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
            flush_cnt  <= 3'd0;
        end else begin
            load_start <= 1'b0;
            done       <= 1'b0;
            lb_rst     <= 1'b0;

            case (state)
                //--------------------------------------------------------------
                IDLE: begin
                    pipe_en <= 1'b0;
                    sel     <= 1'b0;
                    if (start) begin
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
                    // pipe_en=1 유지하여 마지막 픽셀이 파이프라인 끝까지 흐르게 함
                    // row/col은 이미 0으로 리셋됨 → 스캔 카운터 영향 없음
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
                // ★ LBRST: line_buffer, window_register 리셋 1사이클
                //    pipe_en=0 상태에서 lb_rst=1 → 다음 사이클에 RUN2 진입
                LBRST: begin
                    pipe_en <= 1'b0;
                    lb_rst  <= 1'b1;   // 1사이클 펄스
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
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    //==========================================================================
    // 출력 주소 파이프라인 지연 (PIPE_DELAY 사이클)
    // pixel_valid, row-2, col-2, sel을 동시에 지연
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
