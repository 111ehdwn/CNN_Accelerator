`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv2_fsm
// Description:
//   Conv2 engine의 제어 FSM
//   - 입력: 8 IC × 26×26 (c1c2 BRAM에서 stream read)
//   - 출력: 16 OC × 24×24 (c2pool BRAM에 write)
//   - K_col 3-cycle time-multiplexing
//   - Row boundary는 COMPUTE_WRAP으로 처리 (PE idle 없음)
//
//   한 output pixel 처리 (3 cycle):
//     COMPUTE_HOLD (cycle 0): kcol_phase=0, sel=0, col_sel=0, no shift
//     COMPUTE_HOLD (cycle 1): kcol_phase=1, sel=1, col_sel=1, no shift
//     COMPUTE_ADVANCE        : kcol_phase=2, sel=2, col_sel=2, shift + read
//
//   Row boundary 처리 (COMPUTE_WRAP, 3 cycle):
//     이전 row의 마지막 output을 계산하면서 다음 row 첫 3 pixel을 read
//     col_sel은 0으로 고정, sel만 0→1→2 진행
//
//   FSM 상태 (6개):
//     IDLE             : start 신호 대기 + 다음 이미지 대기
//     PIPELINE_FILL    : line_buffer + window 초기 fill
//     COMPUTE_HOLD     : compute, window 정지 (2 cycle)
//     COMPUTE_ADVANCE  : compute, window 1 col 진행 + read (1 cycle)
//     COMPUTE_WRAP     : compute, row 변경 처리 (3 cycle)
//     DONE             : read_done pulse + IDLE 복귀
//////////////////////////////////////////////////////////////////////////////////

module conv2_fsm (
    input  wire        clk,
    input  wire        rst,              // active-high synchronous reset

    //==========================================================================
    // Inter-layer handshake (c1c2 buffer 측)
    //==========================================================================
    input  wire        peer_write_done,  // Conv1으로부터 1-cycle pulse
                                         // (다음 이미지 input bank 준비됨)
    output reg         read_done,        // Conv1으로 1-cycle pulse
                                         // (현재 이미지 input bank 다 읽음)

    //==========================================================================
    // PE / window / line_buffer 제어 신호
    //==========================================================================
    output reg  [1:0]  sel,              // PE weight selector (0, 1, 2)
                                         // K_col index에 해당
    output reg  [1:0]  col_sel,          // window col selector (0, 1, 2)
                                         // PE에 전달할 window의 col 위치
    output reg         shift_en,         // line_buffer + window shift
    output reg         read_en,          // c1c2 BRAM read enable
    output reg         pe_en              // PE clock enable
);

    //==========================================================================
    // 1. 상태 정의
    //==========================================================================
    localparam [2:0] IDLE             = 3'd0;
    localparam [2:0] PIPELINE_FILL    = 3'd1;
    localparam [2:0] COMPUTE_HOLD     = 3'd2;
    localparam [2:0] COMPUTE_ADVANCE  = 3'd3;
    localparam [2:0] COMPUTE_WRAP     = 3'd4;
    localparam [2:0] DONE             = 3'd5;

    reg [2:0] state, next_state;

    //==========================================================================
    // 2. 카운터들
    //
    //   kcol_phase: 0, 1, 2 순환 (한 output pixel의 K_col index)
    //     - COMPUTE_HOLD에서 0 → 1
    //     - COMPUTE_ADVANCE에서 2
    //     - COMPUTE_WRAP에서 0 → 1 → 2 (3 cycle)
    //
    //   read_row, read_col: 다음에 c1c2 BRAM에서 read할 좌표 (0~25)
    //     - 매 read_en cycle마다 증가
    //     - col 25 도달 후 다음 row로
    //
    //   fill_cnt: PIPELINE_FILL 동안 fill된 pixel 수
    //     - line_buffer 2 row + window 2 col = 26*2 + 2 = 54 pixel 후 첫 valid
    //     - 단, line_buffer 1-cycle 지연 고려하여 55 cycle
    //==========================================================================
    reg [1:0] kcol_phase;
    reg [4:0] read_row;     // 0~25 (Conv2 input row)
    reg [4:0] read_col;     // 0~25 (Conv2 input col)
    reg [6:0] fill_cnt;     // 0~54 (PIPELINE_FILL 카운터)
    reg [1:0] wrap_cnt;     // 0~2 (COMPUTE_WRAP 내부 카운터)

    //==========================================================================
    // 3. 입력/출력 끝 검출
    //
    //   last_input_read: 한 이미지의 마지막 input pixel을 read하는 시점
    //     - read_row=25, read_col=25
    //
    //   row_boundary: 현재 read가 row 끝 (col=25)에 도달
    //     - COMPUTE_ADVANCE 끝에 boundary 판정
    //==========================================================================
    wire last_input_read = (read_row == 5'd25) && (read_col == 5'd25);
    wire row_boundary    = (read_col == 5'd25) && (read_row != 5'd25);
    // last_input_read 시점은 row_boundary가 아니라 DONE 진입

    //==========================================================================
    // 4. State Register (sequential)
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            state <= IDLE;
        else
            state <= next_state;
    end

    //==========================================================================
    // 5. Next State Logic (combinational)
    //==========================================================================
    always @(*) begin
        next_state = state;  // default: 현재 상태 유지

        case (state)
            //------------------------------------------------------------------
            // IDLE: start 신호 대기
            //   peer_write_done 받으면 PIPELINE_FILL 시작
            //------------------------------------------------------------------
            IDLE: begin
                if (peer_write_done)
                    next_state = PIPELINE_FILL;
            end

            //------------------------------------------------------------------
            // PIPELINE_FILL: line_buffer + window 채우기
            //   55 cycle 동안 매 cycle 1 pixel read
            //   (line_buffer 1 cycle 지연 포함하여 정확히 55 cycle)
            //   첫 valid window 도달 시 COMPUTE_HOLD 진입
            //------------------------------------------------------------------
            PIPELINE_FILL: begin
                if (fill_cnt == 7'd54)  // 0~54 = 55 cycle
                    next_state = COMPUTE_HOLD;
            end

            //------------------------------------------------------------------
            // COMPUTE_HOLD: window 정지, compute
            //   kcol_phase 0 → 1 → COMPUTE_ADVANCE
            //   2 cycle 머무름
            //------------------------------------------------------------------
            COMPUTE_HOLD: begin
                if (kcol_phase == 2'd1)
                    next_state = COMPUTE_ADVANCE;
            end

            //------------------------------------------------------------------
            // COMPUTE_ADVANCE: window 1 col 진행, read, compute
            //   1 cycle 머무름
            //   다음 상태 결정:
            //     - last_input_read: DONE (한 이미지 끝)
            //     - row_boundary:    COMPUTE_WRAP (다음 row 시작)
            //     - 그 외:           COMPUTE_HOLD (정상 진행)
            //------------------------------------------------------------------
            COMPUTE_ADVANCE: begin
                if (last_input_read)
                    next_state = DONE;
                else if (row_boundary)
                    next_state = COMPUTE_WRAP;
                else
                    next_state = COMPUTE_HOLD;
            end

            //------------------------------------------------------------------
            // COMPUTE_WRAP: row 변경 처리
            //   3 cycle 머무름 (wrap_cnt 0 → 1 → 2)
            //   각 cycle:
            //     - PE에 col_pos_0 전달 (col_sel=0 고정)
            //     - sel은 0 → 1 → 2 변화
            //     - shift + read 매 cycle
            //
            //   끝나면 COMPUTE_HOLD 진입 (다음 output row 첫 pixel 시작)
            //------------------------------------------------------------------
            COMPUTE_WRAP: begin
                if (wrap_cnt == 2'd2)
                    next_state = COMPUTE_HOLD;
            end

            //------------------------------------------------------------------
            // DONE: read_done pulse 출력 후 IDLE 복귀
            //   1 cycle 머무름
            //------------------------------------------------------------------
            DONE: begin
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    //==========================================================================
    // 6. 카운터 갱신
    //==========================================================================

    // kcol_phase: 한 output pixel의 K_col index
    //   COMPUTE_HOLD/ADVANCE 사이클에서 0 → 1 → 2 순환
    //   COMPUTE_WRAP에서도 0 → 1 → 2 순환 (sel 동기)
    //   다른 상태에서는 0으로 reset
    always @(posedge clk) begin
        if (rst) begin
            kcol_phase <= 2'd0;
        end else begin
            case (state)
                COMPUTE_HOLD: begin
                    // 0 → 1 진행
                    kcol_phase <= kcol_phase + 2'd1;
                end
                COMPUTE_ADVANCE: begin
                    // 한 pixel 끝, 다음 pixel 시작 위해 0으로
                    kcol_phase <= 2'd0;
                end
                COMPUTE_WRAP: begin
                    if (wrap_cnt == 2'd2)
                        kcol_phase <= 2'd0;  // WRAP 끝, 다음 pixel 시작
                    else
                        kcol_phase <= kcol_phase + 2'd1;
                end
                default: begin
                    kcol_phase <= 2'd0;
                end
            endcase
        end
    end

    // wrap_cnt: COMPUTE_WRAP 내부 cycle 카운터
    always @(posedge clk) begin
        if (rst) begin
            wrap_cnt <= 2'd0;
        end else if (state == COMPUTE_WRAP) begin
            if (wrap_cnt == 2'd2)
                wrap_cnt <= 2'd0;
            else
                wrap_cnt <= wrap_cnt + 2'd1;
        end else begin
            wrap_cnt <= 2'd0;
        end
    end

    // fill_cnt: PIPELINE_FILL 카운터
    always @(posedge clk) begin
        if (rst) begin
            fill_cnt <= 7'd0;
        end else if (state == PIPELINE_FILL) begin
            fill_cnt <= fill_cnt + 7'd1;
        end else begin
            fill_cnt <= 7'd0;
        end
    end

    // read_row, read_col: 다음 read할 BRAM 좌표
    //   read_en이 1인 cycle에 증가
    //   col 25 도달 후 row 증가
    always @(posedge clk) begin
        if (rst) begin
            read_row <= 5'd0;
            read_col <= 5'd0;
        end else if (state == IDLE) begin
            // 새 이미지 시작: 카운터 초기화
            read_row <= 5'd0;
            read_col <= 5'd0;
        end else if (read_en) begin
            if (read_col == 5'd25) begin
                read_col <= 5'd0;
                read_row <= read_row + 5'd1;
            end else begin
                read_col <= read_col + 5'd1;
            end
        end
    end

    //==========================================================================
    // 7. 제어 신호 출력 (combinational)
    //
    //   상태별 신호 패턴 (문서 5.2 참조):
    //                    sel       col_sel    shift_en  read_en   pe_en
    //   IDLE              0         0          0         0         0
    //   PIPELINE_FILL     0         0          1         1         0
    //   COMPUTE_HOLD      0/1       0/1        0         0         1
    //   COMPUTE_ADVANCE   2         2          1         1         1
    //   COMPUTE_WRAP      0/1/2     0          1         1         1
    //   DONE              0         0          0         0         0
    //==========================================================================
    always @(*) begin
        // Default values
        sel      = 2'd0;
        col_sel  = 2'd0;
        shift_en = 1'b0;
        read_en  = 1'b0;
        pe_en    = 1'b0;

        case (state)
            IDLE: begin
                // 모두 0 (default)
            end

            PIPELINE_FILL: begin
                shift_en = 1'b1;
                read_en  = 1'b1;
                // pe_en = 0 (compute 아직 안 함)
            end

            COMPUTE_HOLD: begin
                sel      = kcol_phase;   // 0 또는 1
                col_sel  = kcol_phase;   // 0 또는 1 (col_sel = sel in HOLD)
                shift_en = 1'b0;
                read_en  = 1'b0;
                pe_en    = 1'b1;
            end

            COMPUTE_ADVANCE: begin
                sel      = 2'd2;
                col_sel  = 2'd2;
                shift_en = 1'b1;
                read_en  = 1'b1;
                pe_en    = 1'b1;
            end

            COMPUTE_WRAP: begin
                sel      = wrap_cnt;     // 0 → 1 → 2
                col_sel  = 2'd0;         // 고정 0 (WRAP의 핵심)
                shift_en = 1'b1;
                read_en  = 1'b1;
                pe_en    = 1'b1;
            end

            DONE: begin
                // 모두 0 (default)
            end

            default: begin
                // 모두 0
            end
        endcase
    end

    //==========================================================================
    // 8. read_done pulse 출력
    //   DONE 상태에서 1-cycle pulse
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            read_done <= 1'b0;
        else
            read_done <= (next_state == DONE);
            // DONE 상태에 진입하는 cycle에 1
    end

endmodule