`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv1_fsm
// Description:
//   - Conv1 전체 제어
//
//   동작 순서:
//     1. LOAD:  weight_loader에 load_start → load_done 대기
//     2. RUN1:  sel=0, 26×26 픽셀 순회 (oc0~3)
//     3. RUN2:  sel=1, 26×26 픽셀 순회 (oc4~7)
//     4. DONE:  done 펄스
//
//   파이프라인 딜레이:
//     pe_cell:       4사이클
//     adder_tree:    1사이클
//     truncate_relu: 1사이클
//     총 6사이클
//     → pixel_valid를 6사이클 지연시켜 out_valid 생성
//     → out_row, out_col도 동일하게 지연
//
//   pixel_valid 조건 (Sobel과 동일 원리):
//     입력 28×28, 커널 3×3, 패딩 없음
//     → row >= 2 && col >= 2 일 때 유효 window 완성
//////////////////////////////////////////////////////////////////////////////////

module conv1_fsm (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,        // conv1 시작 펄스

    // weight_loader 인터페이스
    output reg         load_start,   // 1사이클 펄스
    input  wire        load_done,    // 1사이클 펄스

    // 파이프라인 제어
    output reg         pipe_en,      // line_buffer, pe_cell 등 enable
    output reg         sel,          // 0: 라운드1(oc0~3), 1: 라운드2(oc4~7)

    // pixel_valid: 유효 window (row>=2, col>=2)
    output wire        pixel_valid,

    // 출력 픽셀 주소 (파이프라인 딜레이 보상 후)
    output wire [4:0]  out_row,      // 0~25
    output wire [4:0]  out_col,      // 0~25
    output wire        out_valid,    // truncate_relu 출력 유효
    output wire        out_sel,      // out_valid 시점의 sel (어떤 라운드 출력인지)

    // 완료
    output reg         done
);

    //==========================================================================
    // FSM 상태
    //==========================================================================
    localparam IDLE  = 3'd0;
    localparam LOAD  = 3'd1;   // weight 적재 대기
    localparam RUN1  = 3'd2;   // 라운드1: oc0~3
    localparam FLUSH1= 3'd3;   // 라운드1 파이프라인 flush (6사이클)
    localparam RUN2  = 3'd4;   // 라운드2: oc4~7
    localparam FLUSH2= 3'd5;   // 라운드2 파이프라인 flush (6사이클)
    localparam DONE  = 3'd6;

    reg [2:0] state;

    //==========================================================================
    // 래스터 스캔 카운터 (Sobel과 동일)
    // 입력 28×28 전체 순회
    // row, col: 현재 읽고 있는 입력 픽셀 좌표
    //==========================================================================
    localparam IMG_W  = 28;
    localparam IMG_H  = 28;
    localparam PIPE_DELAY = 6;  // pe_cell(4) + adder(1) + relu(1)

    reg [4:0] row;   // 0~27
    reg [4:0] col;   // 0~27

    wire scan_done = (row == IMG_H-1) && (col == IMG_W-1);
    wire run_state = (state == RUN1) || (state == RUN2);

    always @(posedge clk) begin
        if (rst) begin
            row <= 5'd0;
            col <= 5'd0;
        end else if (state == FLUSH1 || state == FLUSH2) begin
            // flush 구간: 카운터 정지
            row <= 5'd0;
            col <= 5'd0;
        end else if (run_state) begin
            if (col == IMG_W-1) begin
                col <= 5'd0;
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
    // pixel_valid: 유효 window 완성 구간
    // line_buffer 2개를 채워야 하므로 row>=2, col>=2
    //==========================================================================
    assign pixel_valid = run_state && (row >= 5'd2) && (col >= 5'd2);

    //==========================================================================
    // flush 카운터 (파이프라인 드레인)
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
            done       <= 1'b0;
            flush_cnt  <= 3'd0;
        end else begin
            load_start <= 1'b0;
            done       <= 1'b0;

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
                        // 파이프라인에 남은 데이터 flush
                        flush_cnt <= 3'd0;
                        state     <= FLUSH1;
                    end
                end

                //--------------------------------------------------------------
                FLUSH1: begin
                    pipe_en <= 1'b1;  // 파이프라인 계속 흘려야 마지막 데이터 나옴
                    sel     <= 1'b0;
                    if (flush_cnt == PIPE_DELAY-1) begin
                        pipe_en <= 1'b1;
                        sel     <= 1'b1;
                        state   <= RUN2;
                        flush_cnt <= 3'd0;
                    end else begin
                        flush_cnt <= flush_cnt + 1'b1;
                    end
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
                        pipe_en <= 1'b0;
                        state   <= DONE;
                        flush_cnt <= 3'd0;
                    end else begin
                        flush_cnt <= flush_cnt + 1'b1;
                    end
                end

                //--------------------------------------------------------------
                DONE: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end

    //==========================================================================
    // 출력 주소 파이프라인 지연 (PIPE_DELAY 사이클)
    // pixel_valid, row-2, col-2, sel을 동시에 지연
    // → truncate_relu 출력과 타이밍 맞춤
    //==========================================================================
    reg        valid_sr [0:PIPE_DELAY-1];
    reg [4:0]  row_sr   [0:PIPE_DELAY-1];
    reg [4:0]  col_sr   [0:PIPE_DELAY-1];
    reg        sel_sr   [0:PIPE_DELAY-1];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < PIPE_DELAY; i = i+1) begin
                valid_sr[i] <= 1'b0;
                row_sr[i]   <= 5'd0;
                col_sr[i]   <= 5'd0;
                sel_sr[i]   <= 1'b0;
            end
        end else begin
            // 입력단 (pixel_valid 시점의 출력 좌표 = row-2, col-2)
            valid_sr[0] <= pixel_valid;
            row_sr[0]   <= row - 5'd2;
            col_sr[0]   <= col - 5'd2;
            sel_sr[0]   <= sel;

            for (i = 1; i < PIPE_DELAY; i = i+1) begin
                valid_sr[i] <= valid_sr[i-1];
                row_sr[i]   <= row_sr[i-1];
                col_sr[i]   <= col_sr[i-1];
                sel_sr[i]   <= sel_sr[i-1];
            end
        end
    end

    assign out_valid = valid_sr[PIPE_DELAY-1];
    assign out_row   = row_sr[PIPE_DELAY-1];
    assign out_col   = col_sr[PIPE_DELAY-1];
    assign out_sel   = sel_sr[PIPE_DELAY-1];

endmodule