`timescale 1ns / 1ps

module maxpool_fsm (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,            // one-shot system init (legacy, 무시 가능)
    output reg          done,

    // 4-way handshake (conv2_fsm 패턴 차용)
    //   prior_diff = (rdone count) - (prior_wdone count) ; data_ready = (prior_diff < 0)
    //   after_diff = (wdone count) - (succ_rdone count)  ; output_avail = (after_diff < 2)
    input  wire         prior_wdone,      // c2pool buffer (Conv2 wdone) — 입력 image 준비됨
    input  wire         succ_rdone,       // poolfc buffer (FC rdone) — 출력 bank 비움
    output reg          rdone,            // c2pool read 완료 (= done, P0 단순 매핑)
    output reg          wdone,            // poolfc write 완료 (= done, P0 단순 매핑)

    // Bank select (conv2_fsm 패턴 — maxpool 내부 관리, engine 이 addr 에 prepend)
    output reg          input_bank_sel,   // c2pool read bank  : rdone 시 toggle
    output reg          output_bank_sel,  // poolfc write bank : wdone 시 toggle

    // local addr only (0~575). engine 이 input_bank_sel 을 prepend.
    output reg  [9:0]   rd_addr,
    output reg          rd_en,
    input  wire signed [127:0] rd_data,

    output reg          mc_en,

    output reg signed [127:0] p00_flat,
    output reg signed [127:0] p01_flat,
    output reg signed [127:0] p10_flat,
    output reg signed [127:0] p11_flat,

    output wire         out_valid,
    output wire [7:0]   out_addr
);

    localparam IDLE  = 2'd0;
    localparam RUN   = 2'd1;
    localparam FLUSH = 2'd2;
    localparam DONE  = 2'd3;

    reg [1:0] state;
    reg [3:0] out_row;
    reg [3:0] out_col;
    reg [2:0] phase;      // 0~5: BRAM 1-cycle latency 고려
    reg [2:0] flush_cnt;
    reg [7:0] cur_addr_reg;

    // start input edge-detect (P1-1): buffer 의 maxpool_start level signal 도 안전 처리
    reg start_d;
    wire start_pulse = start & ~start_d;

    // handshake counters (P1-2, conv2_fsm 패턴 + race fix)
    //
    // Race-free design (P1 race fix):
    //   prior_diff / after_diff 는 register (NBA). DONE→IDLE 진입 cycle 에 rdone 가
    //   register 출력으로 high 가 되지만 prior_diff 의 NBA update 는 한 cycle 늦음.
    //   같은 cycle 에 IDLE 의 data_ready check 가 stale prior_diff 를 보고 잘못 RUN 진입.
    //
    //   해결: data_ready / output_avail 을 *next* 값 기준으로 combinational 평가.
    //         그러면 NBA timing 과 무관하게 결정 cycle 의 신호 (rdone/wdone/prior_wdone/succ_rdone)
    //         반영된 후의 counter 값을 보고 RUN 결정.
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

    wire [4:0] in_row = out_row << 1;
    wire [4:0] in_col = out_col << 1;

    // local addr (0~575) — 10-bit. bank offset 제거됨 (buffer 가 prepend).
    wire [9:0] in_row_10 = {5'd0, in_row};
    wire [9:0] in_col_10 = {5'd0, in_col};

    integer j;

    always @(posedge clk) begin
        if (rst) begin
            state        <= IDLE;
            done         <= 1'b0;
            rd_en        <= 1'b0;
            rd_addr      <= 10'd0;
            mc_en        <= 1'b0;
            out_row      <= 4'd0;
            out_col      <= 4'd0;
            phase        <= 3'd0;
            flush_cnt    <= 3'd0;
            cur_addr_reg <= 8'd0;
            p00_flat     <= 128'd0;
            p01_flat     <= 128'd0;
            p10_flat     <= 128'd0;
            p11_flat     <= 128'd0;
            start_d      <= 1'b0;
            rdone        <= 1'b0;
            wdone        <= 1'b0;
        end else begin
            done  <= 1'b0;
            mc_en <= 1'b0;
            rdone <= 1'b0;
            wdone <= 1'b0;
            start_d <= start;

            case (state)
                IDLE: begin
                    rd_en     <= 1'b0;
                    out_row   <= 4'd0;
                    out_col   <= 4'd0;
                    phase     <= 3'd0;
                    flush_cnt <= 3'd0;

                    // RUN 진입 조건: 입력 image 준비 + 출력 bank 여유.
                    //   data_ready   = (prior_diff_next < 0) — 다음 cycle 의 prior_diff 값 기준
                    //   output_avail = (after_diff_next < 2)
                    //   start_pulse  = system init 시 첫 image 강제 진입용 (legacy)
                    if ((data_ready && output_avail) || start_pulse) begin
                        state <= RUN;
                    end
                end

                RUN: begin
                    case (phase)
                        //======================================================
                        // phase 0
                        // request p00
                        // 이 클럭에서 주소만 요청한다.
                        // 동기식 BRAM이므로 rd_data는 아직 유효하지 않다.
                        //======================================================
                        3'd0: begin
                            rd_en   <= 1'b1;
                            rd_addr <= (in_row_10 * 10'd24) + in_col_10;
                            phase   <= 3'd1;
                        end

                        //======================================================
                        // phase 1
                        // request p01
                        // 이 시점에서 BRAM은 p00을 출력 준비하지만,
                        // 같은 posedge에서 FSM이 잡으면 이전 rd_data를 보게 된다.
                        // 따라서 여기서는 캡처하지 않고 다음 phase에서 p00을 잡는다.
                        //======================================================
                        3'd1: begin
                            rd_en   <= 1'b1;
                            rd_addr <= (in_row_10 * 10'd24) + (in_col_10 + 10'd1);
                            phase   <= 3'd2;
                        end

                        //======================================================
                        // phase 2
                        // capture p00, request p10
                        //======================================================
                        3'd2: begin
                            rd_en   <= 1'b1;

                            for (j = 0; j < 16; j = j + 1)
                                p00_flat[j*8 +: 8] <= rd_data[j*8 +: 8];

                            rd_addr <= ((in_row_10 + 10'd1) * 10'd24) + in_col_10;
                            phase   <= 3'd3;
                        end

                        //======================================================
                        // phase 3
                        // capture p01, request p11
                        //======================================================
                        3'd3: begin
                            rd_en   <= 1'b1;

                            for (j = 0; j < 16; j = j + 1)
                                p01_flat[j*8 +: 8] <= rd_data[j*8 +: 8];

                            rd_addr <= ((in_row_10 + 10'd1) * 10'd24) + (in_col_10 + 10'd1);
                            phase   <= 3'd4;
                        end

                        //======================================================
                        // phase 4
                        // capture p10
                        // p11은 이 클럭에서 BRAM 쪽에서 출력 준비되므로,
                        // 다음 phase에서 캡처해야 한다.
                        //======================================================
                        3'd4: begin
                            rd_en <= 1'b0;

                            for (j = 0; j < 16; j = j + 1)
                                p10_flat[j*8 +: 8] <= rd_data[j*8 +: 8];

                            phase <= 3'd5;
                        end

                        //======================================================
                        // phase 5
                        // capture p11, start compare, advance output pixel
                        //======================================================
                        3'd5: begin
                            rd_en <= 1'b0;

                            for (j = 0; j < 16; j = j + 1)
                                p11_flat[j*8 +: 8] <= rd_data[j*8 +: 8];

                            cur_addr_reg <= ({4'd0, out_row} * 8'd12) + {4'd0, out_col};
                            mc_en <= 1'b1;
                            phase <= 3'd0;

                            if (out_col == 4'd11) begin
                                out_col <= 4'd0;
                                if (out_row == 4'd11) begin
                                    state <= FLUSH;
                                end else begin
                                    out_row <= out_row + 1'b1;
                                end
                            end else begin
                                out_col <= out_col + 1'b1;
                            end
                        end

                        default: begin
                            phase <= 3'd0;
                        end
                    endcase
                end

                FLUSH: begin
                    rd_en <= 1'b0;
                    flush_cnt <= flush_cnt + 1'b1;
                    if (flush_cnt == 3'd5) begin
                        state <= DONE;
                    end
                end

                DONE: begin
                    done  <= 1'b1;
                    rdone <= 1'b1;        // P0 단순 매핑: read/write 모두 끝 시점
                    wdone <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    //=========================================================================
    // Handshake counters (conv2_fsm 패턴 차용)
    //   prior_diff: rdone(+1), prior_wdone(-1)
    //   after_diff: wdone(+1), succ_rdone(-1)
    //=========================================================================
    always @(posedge clk) begin
        if (rst) begin
            prior_diff <= 3'sd0;
        end else begin
            case ({rdone, prior_wdone})
                2'b10:   prior_diff <= prior_diff + 3'sd1;
                2'b01:   prior_diff <= prior_diff - 3'sd1;
                2'b11:   prior_diff <= prior_diff;
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
                2'b11:   after_diff <= after_diff;
                default: after_diff <= after_diff;
            endcase
        end
    end

    //=========================================================================
    // Bank select toggle FF (conv2_fsm 패턴 — maxpool 내부 관리)
    //   input_bank_sel  : c2pool read bank, rdone 시 toggle
    //   output_bank_sel : poolfc write bank, wdone 시 toggle
    //
    //   이전엔 TB 가 maxpool_rdone_count[0] / wdone_count[0] 로 derive 했으나,
    //   conv1 / conv2 / FC 와 동일하게 RTL 내부에서 관리하도록 표준화.
    //   rdone/wdone 이 image 종료 시점(DONE)에 pulse → 다음 image 의 read/write
    //   에 새 bank 적용. 현재 image 의 마지막 read/write 는 toggle 이전 값 사용
    //   (RUN/FLUSH 구간엔 pulse 없음 → race 없음).
    //=========================================================================
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

    //=========================================================================
    // Compare tree latency alignment
    // 기존 구조 유지
    //=========================================================================
    reg       v_d1;
    reg       v_d2;
    reg [7:0] a_d1;
    reg [7:0] a_d2;

    always @(posedge clk) begin
        if (rst) begin
            v_d1 <= 1'b0;
            v_d2 <= 1'b0;
            a_d1 <= 8'd0;
            a_d2 <= 8'd0;
        end else begin
            v_d1 <= mc_en;
            v_d2 <= v_d1;
            a_d1 <= cur_addr_reg;
            a_d2 <= a_d1;
        end
    end

    assign out_valid = v_d2;
    assign out_addr  = a_d2;

endmodule