`timescale 1ns / 1ps

module maxpool_engine (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    output wire         done,

    // C2Pool ping-pong buffer 읽기 (Port B)
    output wire [9:0]   c2pool_rd_addr,
    output wire         c2pool_rd_en,
    input  wire signed [127:0] c2pool_rd_data,  // 16채널 packed
    input  wire         c2pool_bank_sel,        // 입력 버퍼 핑퐁 뱅크 선택

    // PoolFC buffer 쓰기 (Port A) - 핑퐁 구조 반영
    output wire [7:0]   poolfc_wr_addr,   // 8비트 확장 (MSB: 뱅크선택, LSB: 0~143 내부주소)
    output wire         poolfc_wr_en,
    output wire [127:0] poolfc_wr_data,  // 16채널 packed
    input  wire         poolfc_bank_sel   // ★ 추가: 출력 버퍼 핑퐁 뱅크 선택 신호
);

    //==========================================================================
    // 내부 시그널 선언
    //==========================================================================
    wire         mc_en;
    wire signed [7:0] p00 [0:15];
    wire signed [7:0] p01 [0:15];
    wire signed [7:0] p10 [0:15];
    wire signed [7:0] p11 [0:15];
    wire         out_valid;
    wire [6:0]   out_addr;
    wire signed [7:0] max_out [0:15];

    //==========================================================================
    // 1. MaxPool FSM (제어부)
    //==========================================================================
    maxpool_fsm fsm (
        .clk        (clk),
        .rst        (rst),
        .start      (start),
        .done       (done),
        .rd_addr    (c2pool_rd_addr),
        .rd_en      (c2pool_rd_en),
        .rd_data    (c2pool_rd_data),
        .bank_sel   (c2pool_bank_sel), // 명확성을 위해 포트 맵핑 이름 보정
        .mc_en      (mc_en),
        .p00        (p00),
        .p01        (p01),
        .p10        (p10),
        .p11        (p11),
        .out_valid  (out_valid),
        .out_addr   (out_addr)
    );

    //==========================================================================
    // 2. Max Compare Tree (연산부)
    //==========================================================================
    max_compare_tree mct (
        .clk     (clk),
        .rst     (rst),
        .en      (mc_en),
        .p00     (p00),
        .p01     (p01),
        .p10     (p10),
        .p11     (p11),
        .max_out (max_out)
    );

    //==========================================================================
    // 3. Output Stream Packing & Bank Address Generation
    //==========================================================================
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi+1) begin : pack
            assign poolfc_wr_data[gi*8 +: 8] = max_out[gi];
        end
    endgenerate

    // ★ 핵심 수정: 1비트 뱅크 선택선과 7비트 내부 주소를 결합하여 최종 8비트 물리 주소 생성
    // poolfc_bank_sel이 0이면 물리 주소 0 ~ 143 (Bank 0)
    // poolfc_bank_sel이 1이면 물리 주소 128 + (0~143) = 128 ~ 271 (Bank 1) 영역으로 분리됨
    assign poolfc_wr_addr = {poolfc_bank_sel, out_addr};
    assign poolfc_wr_en   = out_valid;

endmodule