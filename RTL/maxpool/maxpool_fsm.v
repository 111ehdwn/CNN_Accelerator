`timescale 1ns / 1ps

module maxpool_fsm (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    output reg          done,

    output reg  [10:0]  rd_addr,      // [수정 2.1] 10비트 -> 11비트로 확장
    output reg          rd_en,
    input  wire signed [127:0] rd_data,
    input  wire         bank_sel,

    output reg          mc_en,
    output reg signed [7:0] p00 [0:15],
    output reg signed [7:0] p01 [0:15],
    output reg signed [7:0] p10 [0:15],
    output reg signed [7:0] p11 [0:15],

    output wire         out_valid,
    output wire [7:0]   out_addr      // [수정 2.2] 7비트 -> 8비트로 확장 (0~143 카운트)
);
    localparam IDLE  = 2'd0;
    localparam RUN   = 2'd1;
    localparam FLUSH = 2'd2;
    localparam DONE  = 2'd3;

    reg [1:0] state;
    reg [3:0] out_row;
    reg [3:0] out_col;
    reg [1:0] phase;
    reg [2:0] flush_cnt;
    reg       first_phase0;

    wire [4:0] in_row = out_row << 1;
    wire [4:0] in_col = out_col << 1;
    
    // [수정 2.1] base 주소 11비트 명시
    wire [10:0] base   = bank_sel ? 11'd576 : 11'd0;
    
    // [수정 5.1] 명시적 산술 폭 할당을 위한 11비트 캐스팅
    wire [10:0] in_row_11 = {6'd0, in_row};
    wire [10:0] in_col_11 = {6'd0, in_col};

    wire signed [7:0] rd_ch [0:15];
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi+1) begin : unpack
            assign rd_ch[gi] = rd_data[gi*8 +: 8];
        end
    endgenerate

    integer j;
    reg [7:0] cur_addr_reg;  // [수정 2.2] 7비트 -> 8비트로 확장

    always @(posedge clk) begin
        if (rst) begin
            state        <= IDLE;
            done         <= 1'b0;
            rd_en        <= 1'b0;
            rd_addr      <= 11'd0;   // [수정 2.1]
            mc_en        <= 1'b0;
            out_row      <= 4'd0;
            out_col      <= 4'd0;
            phase        <= 2'd0;
            flush_cnt    <= 3'd0;
            first_phase0 <= 1'b1;
            cur_addr_reg <= 8'd0;    // [수정 2.2]
            for (j = 0; j < 16; j = j+1) begin
                p00[j] <= 8'sd0; p01[j] <= 8'sd0;
                p10[j] <= 8'sd0; p11[j] <= 8'sd0;
            end
        end else begin
            done  <= 1'b0;
            mc_en <= 1'b0;

            case (state)
                IDLE: begin
                    rd_en        <= 1'b0;
                    out_row      <= 4'd0;
                    out_col      <= 4'd0;
                    phase        <= 2'd0;
                    flush_cnt    <= 3'd0;
                    first_phase0 <= 1'b1;
                    if (start) state <= RUN;
                end

                RUN: begin
                    rd_en <= 1'b1;
                    phase <= phase + 1'b1;

                    case (phase)
                        2'd0: begin
                            // [수정 2.3] cur_addr_reg 업데이트를 Phase 3으로 이동 (여기서 제거)
                            
                            // [수정 5.1] 명시적 폭 캐스팅 연산
                            rd_addr <= base + (in_row_11 * 11'd24) + in_col_11;
                            
                            if (!first_phase0) begin
                                for (j = 0; j < 16; j = j+1)
                                    p11[j] <= rd_ch[j];
                                mc_en <= 1'b1;
                            end
                            first_phase0 <= 1'b0;
                        end

                        2'd1: begin
                            for (j = 0; j < 16; j = j+1)
                                p00[j] <= rd_ch[j];
                            rd_addr <= base + (in_row_11 * 11'd24) + (in_col_11 + 11'd1);
                        end

                        2'd2: begin
                            for (j = 0; j < 16; j = j+1)
                                p01[j] <= rd_ch[j];
                            rd_addr <= base + ((in_row_11 + 11'd1) * 11'd24) + in_col_11;
                        end

                        2'd3: begin
                            // [수정 2.3 & 5.1] out_col, out_row 증가 이전에 현재 좌표 캡처
                            cur_addr_reg <= ({4'd0, out_row} * 8'd12) + {4'd0, out_col};

                            for (j = 0; j < 16; j = j+1)
                                p10[j] <= rd_ch[j];
                            
                            rd_addr <= base + ((in_row_11 + 11'd1) * 11'd24) + (in_col_11 + 11'd1);
                            
                            if (out_col == 4'd11) begin
                                out_col <= 4'd0;
                                if (out_row == 4'd11)
                                    state <= FLUSH;
                                else
                                    out_row <= out_row + 1'b1;
                            end else begin
                                out_col <= out_col + 1'b1;
                            end
                        end
                    endcase
                end

                FLUSH: begin
                    // [수정 4.1] rd_en을 무조건 0으로 끄지 않음
                    flush_cnt <= flush_cnt + 1'b1;

                    if (flush_cnt == 3'd0) begin
                        for (j = 0; j < 16; j = j+1)
                            p11[j] <= rd_ch[j];
                        mc_en <= 1'b1;
                        rd_en <= 1'b0;   // [수정 4.1] BRAM 출력 래치 후 rd_en 안전하게 비활성화
                    end

                    if (flush_cnt == 3'd4)
                        state <= DONE;
                end

                DONE: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end

    //==========================================================================
    // 파이프라인 지연선 동기화
    //==========================================================================
    reg         v_d1, v_d2;
    reg [7:0]   a_d1, a_d2;    // [수정 2.2] 7비트 -> 8비트로 확장

    always @(posedge clk) begin
        if (rst) begin
            v_d1 <= 1'b0;
            v_d2 <= 1'b0;
            a_d1 <= 8'd0; a_d2 <= 8'd0;  // [수정 2.2] 초기화 값 변경
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