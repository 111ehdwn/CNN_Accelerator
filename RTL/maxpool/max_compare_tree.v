`timescale 1ns / 1ps
module max_compare_tree (
    input  wire         clk,
    input  wire         rst,
    input  wire         en,
    input  wire signed [7:0] p00 [0:15],
    input  wire signed [7:0] p01 [0:15],
    input  wire signed [7:0] p10 [0:15],
    input  wire signed [7:0] p11 [0:15],
    output reg signed [7:0] max_out [0:15]
);
    // Stage 1 결과 레지스터
    reg signed [7:0] max_top [0:15];
    reg signed [7:0] max_bot [0:15];  // max_bottom → max_bot 통일

    // Stage 2 구동용 1클럭 지연 활성화 신호
    reg en_d1;
    always @(posedge clk) begin
        if (rst) en_d1 <= 1'b0;
        else     en_d1 <= en;
    end

    genvar i;
    // Stage 1
    generate
        for (i = 0; i < 16; i = i+1) begin : stage1
            always @(posedge clk) begin
                if (rst) begin
                    max_top[i] <= 8'sd0;
                    max_bot[i] <= 8'sd0;  // 수정: max_bottom → max_bot
                end else if (en) begin
                    max_top[i] <= (p00[i] > p01[i]) ? p00[i] : p01[i];
                    max_bot[i] <= (p10[i] > p11[i]) ? p10[i] : p11[i];
                end
            end
        end
    endgenerate

    // Stage 2
    generate
        for (i = 0; i < 16; i = i+1) begin : stage2
            always @(posedge clk) begin
                if (rst)
                    max_out[i] <= 8'sd0;
                else if (en_d1)  // 1클럭 지연된 en 사용
                    max_out[i] <= (max_top[i] > max_bot[i]) ? max_top[i] : max_bot[i];
            end
        end
    endgenerate

endmodule
