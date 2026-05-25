`timescale 1ns / 1ps

module maxpool_fsm (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    output reg          done,

    output reg  [9:0]   rd_addr,
    output reg          rd_en,
    input  wire signed [127:0] rd_data,
    input  wire         bank_sel,

    output reg          mc_en,
    output reg signed [7:0] p00 [0:15],
    output reg signed [7:0] p01 [0:15],
    output reg signed [7:0] p10 [0:15],
    output reg signed [7:0] p11 [0:15],

    output wire         out_valid,
    output wire [6:0]   out_addr     // 내부 0~143 카운트용 7비트 포트 유지
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
    wire [9:0] base   = bank_sel ? 10'd576 : 10'd0;

    wire signed [7:0] rd_ch [0:15];
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi+1) begin : unpack
            assign rd_ch[gi] = rd_data[gi*8 +: 8];
        end
    endgenerate

    integer j;
    reg [6:0] cur_addr_reg; // 내부 주소 보존용 7비트 레지스터

    always @(posedge clk) begin
        if (rst) begin
            state        <= IDLE;
            done         <= 1'b0;
            rd_en        <= 1'b0;
            rd_addr      <= 10'd0;
            mc_en        <= 1'b0;
            out_row      <= 4'd0;
            out_col      <= 4'd0;
            phase        <= 2'd0;
            flush_cnt    <= 3'd0;
            first_phase0 <= 1'b1;
            cur_addr_reg <= 7'd0;
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
                            // 12x12 안에서 0~143 범위를 만드는 순수 내부 주소 계산
                            cur_addr_reg <= out_row * 12 + out_col;
                            rd_addr      <= base + (in_row * 24) + in_col;

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
                            rd_addr <= base + (in_row * 24) + (in_col + 1);
                        end

                        2'd2: begin
                            for (j = 0; j < 16; j = j+1)
                                p01[j] <= rd_ch[j];
                            rd_addr <= base + ((in_row + 1) * 24) + in_col;
                        end

                        2'd3: begin
                            for (j = 0; j < 16; j = j+1)
                                p10[j] <= rd_ch[j];
                            rd_addr <= base + ((in_row + 1) * 24) + (in_col + 1);

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
                    rd_en     <= 1'b0;
                    flush_cnt <= flush_cnt + 1'b1;

                    if (flush_cnt == 3'd0) begin
                        for (j = 0; j < 16; j = j+1)
                            p11[j] <= rd_ch[j];
                        mc_en <= 1'b1;
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
    reg [6:0]   a_d1, a_d2;

    always @(posedge clk) begin
        if (rst) begin
            v_d1 <= 1'b0; v_d2 <= 1'b0;
            a_d1 <= 7'd0; a_d2 <= 7'd0;
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