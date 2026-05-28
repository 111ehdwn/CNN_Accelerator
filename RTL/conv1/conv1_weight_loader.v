`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: weight_loader
// Description:
//   - Conv1 weight BRAM → pe_cell 18개 weight register 적재
//   - BRAM Primitives Output Register 사용으로 인해 Latency = 2 clk 대응 수정
//
//   타이밍 (Latency = 2):
//     T+0: load_start 수신 → req_cnt=0, active=1
//     T+1: bram_addr=0 요청, latch_valid=1
//     T+2: BRAM 1st 파이프 단계, latch_valid_d=1
//     T+3: BRAM output register 캡처 → bram_dout=data[0] 유효, latch_valid_dd=1로 SET
//     T+4: latch_valid_dd 읽힘 → latch_cnt=0 적재 (bram_dout=data[0])
//     ...
//     T+39: latch_cnt=35 처리, load_done=1
//////////////////////////////////////////////////////////////////////////////////

module conv1_weight_loader #(
    parameter integer NUM_PE = 18,
    parameter integer ADDR_W = 6
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        load_start,
    output reg         load_done,

    output reg  [ADDR_W-1:0] bram_addr,
    output reg               bram_en,
    input  wire [31:0]       bram_dout,

    output reg  [24:0]       pe_packed_w,
    output reg  [NUM_PE-1:0] pe_load_en,
    output reg               pe_load_idx
);

    reg        active;
    reg [5:0]  req_cnt;
    reg [5:0]  latch_cnt;
    reg        latch_valid;
    reg        latch_valid_d;
    reg        latch_valid_dd; // ★ 추가: 2사이클 지연을 위한 레지스터

    // pe 인덱스 계산 식 (이전 피드백을 반영하여 직관적으로 가독성 최적화)
    wire [5:0] pe_idx_g1_r0 = latch_cnt;           // 0~8
    wire [5:0] pe_idx_g2_r0 = latch_cnt - 6'd9;    // 9~17
    wire [5:0] pe_idx_g1_r1 = latch_cnt - 6'd18;   // 18~26
    wire [5:0] pe_idx_g2_r1 = latch_cnt - 6'd27;   // 27~35

    always @(posedge clk) begin
        if (rst) begin
            active        <= 1'b0;
            req_cnt       <= 6'd0;
            latch_cnt     <= 6'd0;
            latch_valid   <= 1'b0;
            latch_valid_d <= 1'b0;
            latch_valid_dd<= 1'b0; // ★ 추가
            bram_en       <= 1'b0;
            bram_addr     <= {ADDR_W{1'b0}};
            load_done     <= 1'b0;
            pe_packed_w   <= 25'd0;
            pe_load_en    <= {NUM_PE{1'b0}};
            pe_load_idx   <= 1'b0;
        end else begin
            //------------------------------------------------------------------
            // 기본값
            //------------------------------------------------------------------
            load_done      <= 1'b0;
            pe_load_en     <= {NUM_PE{1'b0}};
            latch_valid_d  <= latch_valid;
            latch_valid_dd <= latch_valid_d; // ★ 추가: 쉬프트 시켜서 2 clk 지연 생성

            //------------------------------------------------------------------
            // load_start
            //------------------------------------------------------------------
            if (load_start) begin
                active    <= 1'b1;
                req_cnt   <= 6'd0;
                latch_cnt <= 6'd0;
            end

            //------------------------------------------------------------------
            // BRAM 읽기 요청
            //------------------------------------------------------------------
            if (active && req_cnt <= 6'd35) begin
                bram_en     <= 1'b1;
                bram_addr   <= req_cnt;
                req_cnt     <= req_cnt + 1'b1;
                latch_valid <= 1'b1;
            end else begin
                bram_en     <= 1'b0;
                latch_valid <= 1'b0;
            end

            //------------------------------------------------------------------
            // 래치: latch_valid_dd=1 일 때 bram_dout이 최종 유효함
            //------------------------------------------------------------------
            if (latch_valid_dd) begin // ★ 변경: latch_valid_d -> latch_valid_dd
                pe_packed_w <= bram_dout[24:0];

                if (latch_cnt <= 6'd8) begin
                    // addr 0~8 → pe[0~8].w_regs[0]
                    pe_load_en  <= ({NUM_PE{1'b0}} | (18'd1 << pe_idx_g1_r0));
                    pe_load_idx <= 1'b0;
                end else if (latch_cnt <= 6'd17) begin
                    // addr 9~17 → pe[9~17].w_regs[0]
                    pe_load_en  <= ({NUM_PE{1'b0}} | (18'd1 << (pe_idx_g2_r0 + 6'd9)));
                    pe_load_idx <= 1'b0;
                end else if (latch_cnt <= 6'd26) begin
                    // addr 18~26 → pe[0~8].w_regs[1]
                    pe_load_en  <= ({NUM_PE{1'b0}} | (18'd1 << pe_idx_g1_r1));
                    pe_load_idx <= 1'b1;
                end else begin
                    // addr 27~35 → pe[9~17].w_regs[1]
                    pe_load_en  <= ({NUM_PE{1'b0}} | (18'd1 << (pe_idx_g2_r1 + 6'd9)));
                    pe_load_idx <= 1'b1;
                end

                if (latch_cnt == 6'd35) begin
                    load_done <= 1'b1;
                    active    <= 1'b0;
                    latch_cnt <= 6'd0;
                end else begin
                    latch_cnt <= latch_cnt + 1'b1;
                end
            end
        end
    end

endmodule