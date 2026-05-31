`timescale 1ns / 1ps

module maxpool_engine (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,           // one-shot system init (legacy)
    output wire         done,            // image 처리 완료 pulse (legacy/debug)

    // 4-way handshake (conv2 패턴 차용)
    //   prior_wdone : Conv2 의 wdone (외부, c2pool buffer 에 새 image 도착 알림)
    //   succ_rdone  : FC 의 rdone (외부, poolfc 의 한 bank 비움 알림)
    //   rdone       : Maxpool 의 c2pool read 완료 (외부 c2pool_pingpong_buffer.maxpool_rdone 으로 연결)
    //   wdone       : Maxpool 의 poolfc write 완료 (외부 poolfc 측 buffer 로)
    input  wire         prior_wdone,
    input  wire         succ_rdone,
    output wire         rdone,
    output wire         wdone,

    // C2Pool ping-pong buffer 읽기 (Port B). physical addr = {input_bank_sel, local[9:0]}.
    // conv2 패턴: maxpool 내부 bank_sel 을 prepend (dumb 2-bank BMG 전제).
    output wire [10:0]  c2pool_rd_addr,
    output wire         c2pool_rd_en,
    input  wire signed [127:0] c2pool_rd_data,  // 16채널 packed

    // PoolFC buffer 쓰기 (Port A). physical addr = {output_bank_sel, out_addr[7:0]}.
    output wire [8:0]   poolfc_wr_addr,
    output wire         poolfc_wr_en,
    output wire [127:0] poolfc_wr_data
);

    //==========================================================================
    // 내부 시그널 선언
    //==========================================================================
    wire         mc_en;

    wire [9:0]   fsm_rd_addr;          // local read addr (0~575), engine 이 bank prepend
    wire         fsm_input_bank_sel;   // c2pool read bank
    wire         fsm_output_bank_sel;  // poolfc write bank

    // Verilog 호환을 위해 unpacked array port 제거
    wire signed [127:0] p00_flat;
    wire signed [127:0] p01_flat;
    wire signed [127:0] p10_flat;
    wire signed [127:0] p11_flat;

    wire         out_valid;
    wire [7:0]   out_addr;

    wire signed [127:0] max_out_flat;

    //==========================================================================
    // 1. MaxPool FSM
    //==========================================================================
    maxpool_fsm fsm (
        .clk        (clk),
        .rst        (rst),
        .start      (start),
        .done       (done),

        .prior_wdone(prior_wdone),
        .succ_rdone (succ_rdone),
        .rdone      (rdone),
        .wdone      (wdone),
        .input_bank_sel (fsm_input_bank_sel),
        .output_bank_sel(fsm_output_bank_sel),

        .rd_addr    (fsm_rd_addr),
        .rd_en      (c2pool_rd_en),
        .rd_data    (c2pool_rd_data),

        .mc_en      (mc_en),
        .p00_flat   (p00_flat),
        .p01_flat   (p01_flat),
        .p10_flat   (p10_flat),
        .p11_flat   (p11_flat),

        .out_valid  (out_valid),
        .out_addr   (out_addr)
    );

    //==========================================================================
    // 2. Max Compare Tree
    //==========================================================================
    max_compare_tree mct (
        .clk          (clk),
        .rst          (rst),
        .en           (mc_en),
        .p00_flat     (p00_flat),
        .p01_flat     (p01_flat),
        .p10_flat     (p10_flat),
        .p11_flat     (p11_flat),
        .max_out_flat (max_out_flat)
    );

    //==========================================================================
    // 3. Output Stream Packing & Bank Address Generation
    //   conv2 패턴: c2pool read / poolfc write 의 bank_sel 을 maxpool 내부에서
    //   관리하고 physical addr 에 prepend (dumb 2-bank BMG 전제).
    //==========================================================================
    assign c2pool_rd_addr = {fsm_input_bank_sel, fsm_rd_addr};

    assign poolfc_wr_data = max_out_flat;
    assign poolfc_wr_addr = {fsm_output_bank_sel, out_addr};
    assign poolfc_wr_en   = out_valid;

endmodule