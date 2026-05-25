`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: weight_loader
// Description:
//   - Conv1 weight BRAM에서 packed_a를 읽어 pe_cell 18개의 reg1, reg2에 적재
//   - FSM 없이 카운터만 사용
//   - 최초 1회 실행, 이후 BRAM 접근 없음
//
//   BRAM 레이아웃:
//     addr  0~ 8 → pe_cell[0~8].reg1  (oc0,oc1 k0~k8)
//     addr  9~17 → pe_cell[9~17].reg1 (oc2,oc3 k0~k8)
//     addr 18~26 → pe_cell[0~8].reg2  (oc4,oc5 k0~k8)
//     addr 27~35 → pe_cell[9~17].reg2 (oc6,oc7 k0~k8)
//
//   타이밍:
//     load_start → cnt 0~35 순차 증가
//     BRAM 레이턴시 1사이클 → cnt+1 위치에 래치
//     cnt=36 → load_done 펄스
//////////////////////////////////////////////////////////////////////////////////

module weight_loader #(
    parameter integer NUM_PE = 18,
    parameter integer ADDR_W = 6
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        load_start,   // 1사이클 펄스: 적재 시작
    output reg         load_done,    // 1사이클 펄스: 적재 완료

    // BRAM 인터페이스
    output reg  [ADDR_W-1:0] bram_addr,
    output reg               bram_en,
    input  wire [24:0]       bram_dout,

    // pe_cell 18개 제어
    output reg  [24:0]       pe_packed_a,
    output reg  [NUM_PE-1:0] pe_weight_load1,
    output reg  [NUM_PE-1:0] pe_weight_load2
);

    //==========================================================================
    // 카운터 (0~36)
    // 0~35: BRAM 읽기 요청
    // 36  : 마지막 데이터 래치 + load_done
    //==========================================================================
    reg        active;      // load_start 후 동작 중
    reg [5:0]  req_cnt;     // BRAM 요청 카운터 (0~35)
    reg [5:0]  latch_cnt;   // 래치 카운터 (req_cnt보다 1사이클 뒤)
    reg        latch_valid; // 래치 유효 구간

    always @(posedge clk) begin
        if (rst) begin
            active          <= 1'b0;
            req_cnt         <= 6'd0;
            latch_cnt       <= 6'd0;
            latch_valid     <= 1'b0;
            bram_en         <= 1'b0;
            bram_addr       <= 6'd0;
            load_done       <= 1'b0;
            pe_packed_a     <= 25'd0;
            pe_weight_load1 <= {NUM_PE{1'b0}};
            pe_weight_load2 <= {NUM_PE{1'b0}};
        end else begin
            // 기본값
            load_done       <= 1'b0;
            pe_weight_load1 <= {NUM_PE{1'b0}};
            pe_weight_load2 <= {NUM_PE{1'b0}};
            latch_valid     <= 1'b0;

            // load_start → 동작 시작
            if (load_start) begin
                active  <= 1'b1;
                req_cnt <= 6'd0;
            end

            // BRAM 읽기 요청 (active 구간, req_cnt=0~35)
            if (active && req_cnt <= 6'd35) begin
                bram_en   <= 1'b1;
                bram_addr <= req_cnt;
                req_cnt   <= req_cnt + 1'b1;
                latch_valid <= 1'b1;  // 다음 사이클에 결과 나옴
            end else begin
                bram_en <= 1'b0;
            end

            // BRAM 레이턴시 1사이클 → 래치
            // req_cnt=1일 때 addr=0 결과 유효 → latch_cnt=0에 저장
            if (latch_valid) begin
                pe_packed_a <= bram_dout;

                // latch_cnt 기준으로 어떤 pe_cell의 어떤 reg에 쓸지 결정
                if (latch_cnt <= 6'd8) begin
                    pe_weight_load1[latch_cnt] <= 1'b1;
                end else if (latch_cnt <= 6'd17) begin
                    pe_weight_load1[latch_cnt] <= 1'b1;
                end else if (latch_cnt <= 6'd26) begin
                    pe_weight_load2[latch_cnt - 6'd18] <= 1'b1;
                end else begin
                    pe_weight_load2[latch_cnt - 6'd27 + 6'd9] <= 1'b1;
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
