`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv2_fsm
// Description:
//   Conv2 engine의 제어 FSM (control plane만 담당)
//
//   책임:
//     - 상태 전이 (FSM)
//     - 내부 카운터 (row_cnt, col_cnt, kw_cnt, wrap_cnt, drain_cnt, output_pixel_cnt)
//     - 양방향 handshake counter (prior_diff, after_diff)
//     - 외부 제어 신호 (sel, col_sel, shift_en, pe_en, bank_sel, loader_start)
//
//   책임 아님 (datapath = conv2_engine.v 측):
//     - rdone, wdone pulse 생성 (BRAM read/write 코드 옆에서 생성)
//     - output BRAM write 좌표 (datapath가 output_pixel_cnt 를 받아 자체 생성)
//     - PE array, line_buffer, window register
//     - weight_loader 내부 동작
//
//   FSM 상태 (8개):
//     IDLE             : 시스템 시작 후 weight loading 전 대기
//     LOAD_WEIGHTS     : weight loader 동작 중 (576 cycle, 1번만 진입)
//     DONE             : image 처리 끝, 다음 image 대기
//     PIPELINE_FILL    : line_buffer + window 초기 fill (56 cycle, L=2 fix)
//     COMPUTE_HOLD     : compute, window 정지 (2 cycle, kw 0/1)
//     COMPUTE_ADVANCE  : compute, window 1 col 진행 (1 cycle, kw 2)
//     COMPUTE_WRAP     : compute, row 변경 처리 (3 cycle, r=0..22 만)
//     DRAIN            : 마지막 ADV 후 pipeline drain (12 cycle), 그 후 DONE
//
//   카운터 의미:
//     (row_cnt, col_cnt) = "현재 cycle에 BRAM에 emit 하는 read addr 좌표"
//                          항상 0 ≤ row_cnt ≤ 25, 0 ≤ col_cnt ≤ 25 (cap 보장)
//                          shift_en=1 cycle 의 edge 에서 nested counter 증가
//                          단, (25, 25) 에서는 cap 으로 유지 (BRAM ping-pong
//                          영역 밖 access 방지)
//
//   BRAM L=2 (Primitive Output Register Enable):
//     ENA = REGCE = shift_en (단일 게이팅)
//     dout @ cycle T = mem[addr @ "T 직전 2 shift_en=1 events"]
//     첫 valid window: counter (2, 4) 의 FILL 종료 edge 후 cycle 의 win_r2 =
//                       [(2, 0), (2, 1), (2, 2)] = 출력 (0, 0) 의 input row 2.
//     상세 cycle-by-cycle 표: docs RTL/conv2/conv2_timing.md
//
//   상태 전이 조건:
//     PIPELINE_FILL → COMPUTE_HOLD:
//       (row_cnt, col_cnt) == (2, 4)
//
//     COMPUTE_HOLD → COMPUTE_ADVANCE:
//       kw_cnt == 1 (다음 cycle은 kw=2 = ADVANCE)
//
//     COMPUTE_ADVANCE → DRAIN/COMPUTE_WRAP/COMPUTE_HOLD:
//       output_pixel_cnt == 575: DRAIN (이 ADV 가 마지막 출력 (23, 23) 의 K_col=2)
//       col_cnt == 1:            COMPUTE_WRAP (r=0..22 의 row boundary)
//                                 output (r, 23) K_col=2 cycle 에 counter=(r+3, 1)
//       else:                    COMPUTE_HOLD (정상 진행)
//
//     COMPUTE_WRAP → COMPUTE_HOLD:
//       wrap_cnt == 2 (3 cycle 완료)
//
//     DRAIN → DONE:
//       drain_cnt == 11 (12 cycle pipeline drain 완료)
//       이 edge 에 모든 카운터 (row_cnt, col_cnt, drain_cnt, output_pixel_cnt) reset
//
//   output_pixel_cnt (10-bit, 0..576):
//     ADV 종료 edge 마다 +1, WRAP w=2 종료 edge 에 +1.
//     575 = 마지막 ADV 시작 시 값 → 그 cycle 에 DRAIN entry condition fire.
//     datapath 가 이 카운터로 c2pool BRAM write addr 생성.
//
//   Handshake counters (signed 3-bit, "내 처리 - 상대 처리"):
//     prior_diff = (Conv2 rdone count) - (Conv1 wdone count)
//                = Conv2가 처리한 image 수 - Conv1이 보낸 image 수
//                data_ready = (prior_diff < 0)
//                            = Conv2가 처리할 image가 prior에 남아있음
//
//     after_diff = (Conv2 wdone count) - (Maxpool rdone count)
//                = Conv2가 보낸 image 수 - Maxpool이 처리한 image 수
//                output_avail = (after_diff < 2)
//                              = 출력 bank에 여유 있음 (ping-pong)
//
//   속도 가정 없음:
//     양쪽 어느 쪽이 빠르거나 느리거나 무관.
//     카운터 자체적으로 backpressure 처리.
//
//   Bank selection (1-bit toggle FF, 별도):
//     input_bank_sel  toggle on rdone
//     output_bank_sel toggle on wdone
//////////////////////////////////////////////////////////////////////////////////

module conv2_fsm (
    input  wire        clk,
    input  wire        rst,              // active-high synchronous reset

    //==========================================================================
    // System control
    //==========================================================================
    input  wire        start,            // PS로부터 (csr 통해), 1-cycle pulse

    //==========================================================================
    // Internal weight loader handshake (conv2_engine 내부)
    //==========================================================================
    output reg         loader_start,
    input  wire        loader_done,

    //==========================================================================
    // Input side handshake (vs Conv1, c1c2 buffer)
    //==========================================================================
    input  wire        prior_wdone,      // Conv1으로부터 (외부)
    input  wire        rdone,            // datapath에서 (내부, registered)
    output reg         input_bank_sel,

    //==========================================================================
    // Output side handshake (vs Maxpool, c2pool buffer)
    //==========================================================================
    input  wire        succ_rdone,       // Maxpool로부터 (외부)
    input  wire        wdone,            // datapath에서 (내부, registered)
    output reg         output_bank_sel,

    //==========================================================================
    // Datapath control
    //==========================================================================
    output wire [1:0]  sel,              // PE weight selector (0, 1, 2)
    output wire [1:0]  col_sel,          // PE activation col selector (0, 1, 2)
    output reg         shift_en,         // line_buffer + window + BRAM enable
    output reg         pe_en,            // PE clock enable

    //==========================================================================
    // BRAM read coords (datapath와 공유, BRAM addr 합성용)
    //==========================================================================
    output reg  [4:0]  row_cnt,          // 0~25 (outer, cap @ 25)
    output reg  [4:0]  col_cnt,          // 0~25 (inner, cap @ 25)

    //==========================================================================
    // Output pixel counter (datapath와 공유, c2pool BRAM write addr 합성용)
    //==========================================================================
    output reg  [9:0]  output_pixel_cnt  // 0~576 (완성된 출력 픽셀 수)
);

    //==========================================================================
    // 1. 상태 정의
    //==========================================================================
    localparam [2:0] IDLE             = 3'd0;
    localparam [2:0] LOAD_WEIGHTS     = 3'd1;
    localparam [2:0] DONE             = 3'd2;
    localparam [2:0] PIPELINE_FILL    = 3'd3;
    localparam [2:0] COMPUTE_HOLD     = 3'd4;
    localparam [2:0] COMPUTE_ADVANCE  = 3'd5;
    localparam [2:0] COMPUTE_WRAP     = 3'd6;
    localparam [2:0] DRAIN            = 3'd7;

    reg [2:0] state;

    //==========================================================================
    // 2. 내부 phase 카운터
    //
    //   output_pixel_cnt 는 port 로 선언됨 (datapath 공유). 본 모듈 안에서는 일반
    //   reg 처럼 사용.
    //==========================================================================
    reg [1:0] kw_cnt;             // 0~2 (한 output pixel의 K_col index)
    reg [1:0] wrap_cnt;           // 0~2 (COMPUTE_WRAP 내부 cycle 카운터)
    reg [3:0] drain_cnt;          // 0~11 (DRAIN 내부 cycle 카운터, pipeline depth=12)

    //==========================================================================
    // 3. Handshake 차이 카운터 (signed 3-bit)
    //==========================================================================
    reg signed [2:0] prior_diff;
    reg signed [2:0] after_diff;

    //==========================================================================
    // 4. Compute 시작 조건
    //==========================================================================
    wire data_ready    = (prior_diff < 3'sd0);
    wire output_avail  = (after_diff < 3'sd2);
    wire ready_to_compute = data_ready && output_avail;

    //==========================================================================
    // 5. State + phase counter 갱신 (state 전이와 의미적으로 연결된 카운터)
    //
    //   State 전이, kw_cnt, wrap_cnt를 단일 always에 통합.
    //   row_cnt/col_cnt는 별도 always에서 shift_en 기반 자율 증가.
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state      <= IDLE;
            kw_cnt     <= 2'd0;
            wrap_cnt   <= 2'd0;
            drain_cnt  <= 4'd0;
        end else begin
            case (state)
                //------------------------------------------------------------------
                // IDLE: 시스템 reset 후 PS의 start 신호 대기
                //------------------------------------------------------------------
                IDLE: begin
                    if (start)
                        state <= LOAD_WEIGHTS;
                end

                //------------------------------------------------------------------
                // LOAD_WEIGHTS: weight loader 동작 중
                //------------------------------------------------------------------
                LOAD_WEIGHTS: begin
                    if (loader_done)
                        state <= DONE;
                end

                //------------------------------------------------------------------
                // DONE: image 처리 끝, 다음 image 대기
                //   ready_to_compute 충족 시 PIPELINE_FILL 진입
                //------------------------------------------------------------------
                DONE: begin
                    if (ready_to_compute)
                        state <= PIPELINE_FILL;
                end

                //------------------------------------------------------------------
                // PIPELINE_FILL: line_buffer + window 채우기 (L=2 fix)
                //   counter=(2, 4) 시점에 COMPUTE_HOLD 전이
                //   다음 cycle (counter=(2, 5))에 첫 HOLD0; win_r2 = [(2,0),(2,1),(2,2)]
                //------------------------------------------------------------------
                PIPELINE_FILL: begin
                    if (row_cnt == 5'd2 && col_cnt == 5'd4)
                        state <= COMPUTE_HOLD;
                end

                //------------------------------------------------------------------
                // COMPUTE_HOLD: window 정지, compute (2 cycle, kw 0/1)
                //   kw_cnt 0 → 1 → ADVANCE
                //------------------------------------------------------------------
                COMPUTE_HOLD: begin
                    if (kw_cnt == 2'd1) begin
                        state  <= COMPUTE_ADVANCE;
                        kw_cnt <= 2'd2;     // 다음 cycle ADVANCE에서 사용
                    end else begin
                        kw_cnt <= kw_cnt + 2'd1;
                    end
                end

                //------------------------------------------------------------------
                // COMPUTE_ADVANCE: window 1 col 진행, read, compute (1 cycle)
                //
                //   다음 상태 결정 (현재 cycle 값 기준):
                //     output_pixel_cnt == 575: DRAIN
                //       (이 ADV 가 마지막 출력 (23, 23) 의 K_col=2 cycle)
                //     col_cnt == 1: COMPUTE_WRAP
                //       (r=0..22 의 row boundary; cap 으로 r=23 에서는 절대 fire 안 함)
                //     else: COMPUTE_HOLD
                //
                //   kw_cnt는 0으로 reset (다음 output pixel 시작)
                //------------------------------------------------------------------
                COMPUTE_ADVANCE: begin
                    kw_cnt <= 2'd0;

                    if (output_pixel_cnt == 10'd575) begin
                        state <= DRAIN;
                    end else if (col_cnt == 5'd1) begin
                        state <= COMPUTE_WRAP;
                    end else begin
                        state <= COMPUTE_HOLD;
                    end
                end

                //------------------------------------------------------------------
                // COMPUTE_WRAP: row 변경 처리 (3 cycle)
                //   wrap_cnt 0 → 1 → 2, 매 cycle shift+read+compute
                //   kw_cnt 동기: sel=wrap_cnt
                //   wrap_cnt=2 끝에 COMPUTE_HOLD 진입 (다음 output row 첫 pixel)
                //------------------------------------------------------------------
                COMPUTE_WRAP: begin
                    if (wrap_cnt == 2'd2) begin
                        state    <= COMPUTE_HOLD;
                        wrap_cnt <= 2'd0;
                        kw_cnt   <= 2'd0;     // 다음 output pixel 시작
                    end else begin
                        wrap_cnt <= wrap_cnt + 2'd1;
                        kw_cnt   <= kw_cnt + 2'd1;
                    end
                end

                //------------------------------------------------------------------
                // DRAIN: pipeline drain (12 cycle, 마지막 ADV 후)
                //   PE 4 + adder_tree 5 + kcol_acc 1 + truncate_relu 1 + c2pool 1 = 12.
                //   drain_cnt 0..11, drain_cnt==11 cycle 의 edge 에 마지막 c2pool
                //   write 가 mem 에 갱신되고 동시에 DONE 진입.
                //   이 edge 에서 row_cnt/col_cnt/output_pixel_cnt 도 reset (다음 image).
                //------------------------------------------------------------------
                DRAIN: begin
                    if (drain_cnt == 4'd11) begin
                        state     <= DONE;
                        drain_cnt <= 4'd0;
                    end else begin
                        drain_cnt <= drain_cnt + 4'd1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    //==========================================================================
    // 6. row_cnt, col_cnt 갱신 (BRAM read 좌표)
    //
    //   shift_en=1 cycle 의 edge 에서 nested counter 증가.
    //   단, (25, 25) 에서는 cap (BRAM ping-pong 영역 밖 access 방지).
    //   DRAIN 종료 edge (drain_cnt==11) 에 (0, 0) 으로 reset (다음 image 위해).
    //
    //   shift_en 은 datapath control 출력 (combinational, state로부터):
    //     PIPELINE_FILL, COMPUTE_ADVANCE, COMPUTE_WRAP에서 shift_en=1
    //     그 외 (HOLD, DRAIN, IDLE, LOAD_WEIGHTS, DONE) 에서 shift_en=0
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            row_cnt <= 5'd0;
            col_cnt <= 5'd0;
        end else if (state == DRAIN && drain_cnt == 4'd11) begin
            // DRAIN 종료: 다음 image 위해 reset
            row_cnt <= 5'd0;
            col_cnt <= 5'd0;
        end else if (shift_en) begin
            if (row_cnt == 5'd25 && col_cnt == 5'd25) begin
                // Cap: counter 가 (25, 25) 를 넘어 가지 않도록 hold.
                // BRAM 은 (25, 25) 를 재read 하지만 col_pos chain 에 필요한
                // 데이터는 cap 이전 read 들로 이미 pipeline 안에 있음.
            end else if (col_cnt == 5'd25) begin
                col_cnt <= 5'd0;
                row_cnt <= row_cnt + 5'd1;
            end else begin
                col_cnt <= col_cnt + 5'd1;
            end
        end
    end

    //==========================================================================
    // 6.5 output_pixel_cnt 갱신
    //
    //   ADV 종료 edge 마다 +1 (HOLD/HOLD/ADV 묶음 = 1 픽셀 완성).
    //   WRAP w=2 종료 edge 마다 +1 (WRAP 3 cycle = 1 픽셀 완성).
    //   DRAIN 종료 edge 에 0 으로 reset (다음 image 위해).
    //
    //   값 0..576. 575 = ADV of (23, 23) 시작 시 값 → DRAIN entry trigger.
    //   datapath 가 이 카운터를 c2pool BRAM write addr 생성에 공유 사용.
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            output_pixel_cnt <= 10'd0;
        end else if (state == DRAIN && drain_cnt == 4'd11) begin
            // DRAIN 종료: 다음 image 위해 reset
            output_pixel_cnt <= 10'd0;
        end else if (state == COMPUTE_ADVANCE) begin
            // ADV cycle 종료 edge: HOLD/HOLD/ADV 묶음 1 픽셀 완성
            output_pixel_cnt <= output_pixel_cnt + 10'd1;
        end else if (state == COMPUTE_WRAP && wrap_cnt == 2'd2) begin
            // WRAP w=2 종료 edge: WRAP 묶음 1 픽셀 완성
            output_pixel_cnt <= output_pixel_cnt + 10'd1;
        end
    end

    //==========================================================================
    // 7. Handshake counter 갱신
    //
    //   prior_diff: rdone(+1), prior_wdone(-1)
    //   after_diff: wdone(+1), succ_rdone(-1)
    //   동시 발생 시 net 변화 0 (race 없음)
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            prior_diff <= 3'sd0;
        end else begin
            case ({rdone, prior_wdone})
                2'b10:   prior_diff <= prior_diff + 3'sd1;
                2'b01:   prior_diff <= prior_diff - 3'sd1;
                default: prior_diff <= prior_diff;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            after_diff <= 3'sd0;
        end else begin
            case ({wdone, succ_rdone})
                2'b10:   after_diff <= after_diff + 3'sd1;
                2'b01:   after_diff <= after_diff - 3'sd1;
                default: after_diff <= after_diff;
            endcase
        end
    end

    //==========================================================================
    // 8. Bank select toggle FF
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            input_bank_sel <= 1'b0;
        else if (rdone)
            input_bank_sel <= ~input_bank_sel;
    end

    always @(posedge clk) begin
        if (rst)
            output_bank_sel <= 1'b0;
        else if (wdone)
            output_bank_sel <= ~output_bank_sel;
    end

    //==========================================================================
    // 9. loader_start pulse
    //   IDLE → LOAD_WEIGHTS 진입 시 1-cycle pulse
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            loader_start <= 1'b0;
        else
            loader_start <= (state == IDLE) && start;
    end

    //==========================================================================
    // 10. Datapath control signal
    //
    //   sel은 모든 compute 상태에서 kw_cnt와 일치:
    //     COMPUTE_HOLD:    kw_cnt = 0, 1
    //     COMPUTE_ADVANCE: kw_cnt = 2
    //     COMPUTE_WRAP:    kw_cnt = 0, 1, 2 (wrap_cnt와 동기)
    //   다른 상태에서 kw_cnt = 0 → sel = 0 (자연)
    //
    //   col_sel은 COMPUTE_WRAP에서만 0 고정, 그 외엔 kw_cnt와 동일
    //
    //   상태별 신호 패턴:
    //                    sel       col_sel    shift_en  pe_en
    //   IDLE              0         0          0         0
    //   LOAD_WEIGHTS      0         0          0         0
    //   DONE              0         0          0         0
    //   PIPELINE_FILL     0         0          1         0
    //   COMPUTE_HOLD      0/1       0/1        0         1     (= kw_cnt)
    //   COMPUTE_ADVANCE   2         2          1         1
    //   COMPUTE_WRAP      0/1/2     0          1         1     (sel=wrap_cnt=kw_cnt)
    //   DRAIN             0         0          0         0     (pipeline drain only)
    //==========================================================================
    assign sel     = kw_cnt;
    assign col_sel = (state == COMPUTE_WRAP) ? 2'd0 : kw_cnt;

    always @(*) begin
        shift_en = 1'b0;
        pe_en    = 1'b0;

        case (state)
            PIPELINE_FILL: begin
                shift_en = 1'b1;
            end

            COMPUTE_HOLD: begin
                pe_en = 1'b1;
            end

            COMPUTE_ADVANCE: begin
                shift_en = 1'b1;
                pe_en    = 1'b1;
            end

            COMPUTE_WRAP: begin
                shift_en = 1'b1;
                pe_en    = 1'b1;
            end

            default: begin
            end
        endcase
    end

endmodule