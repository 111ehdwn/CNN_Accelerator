`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: cnn_accelerator  (PL core, Team Assignment 2)
//
//   Pipeline (검증된 통합 TB 배선 그대로):
//     Input BRAM → Conv1 → c1c2 → Conv2 → c2pool → Maxpool → poolfc → FC → class
//
//   제어 인터페이스 (CSR_AXI ↔ PL):
//     resetn    : 외부 보드 reset 버튼 (active-low). 내부 rst = ~resetn (active-high).
//     enable    : 1 이면 가동 (trigger qualify). 0 이면 start/img_ready 무시.
//     start     : 1-cycle pulse (CSR 변환). conv2 LOAD_WEIGHTS 진입 (weight 적재 1회).
//     img_ready : 1-cycle pulse. PS 가 Input BRAM 에 새 image write 완료 알림
//                 → conv1 prior_wdone (image-by-image trigger).
//     result    : 4-bit, 현재 완료 image 의 분류 결과 (class_valid 시 latch).
//     img_done  : 1-cycle pulse, image 처리 완료 (= fc.class_valid 1-cycle 지연).
//     input_consumed : 1-cycle pulse, conv1 이 input BRAM read 완료 (= conv1_rdone).
//                      PS 가 같은 bank 에 다음 image 적재 가능 시점 (overlap backpressure).
//
//   ping-pong bank: 모든 engine 내부 toggle FF 가 관리.
//     Input BRAM 2-bank: PS 가 write 하는 bank 와 conv1 internal input_bank_sel 이
//     image index LSB 로 자동 sync (TB 검증과 동일 전제).
//
//   ★ 필요한 BMG IP (Vivado):
//     [본 모듈 직접 인스턴스]
//     bram_input        (PS write Port A 32b×512 / conv1 read Port B 8b×2048, L=2)  ★ 300MHz: L=1→L=2 + conv1_fsm OUT_DELAY/adder 4-stage
//     bram_c1_to_c2     (conv1 write / conv2 read, 64b×2048, byte-write, L=2)
//     bram_c2_to_pool   (conv2 write / maxpool read, 128b×2048, L=2)  ★ 300MHz: L=1→L=2 + maxpool_fsm 7-phase
//     bram_pool_to_fc   (maxpool write / fc read, 128b×512, L=1)   ★ 신규 IP
//     [engine 내부 인스턴스 — Port A 만 외부 passthrough]
//     conv1_weight_bram (conv1_engine) / conv2_weight_bram (conv2_engine) / fc_weight_bram (fc_engine)
//   PS-write BMG 4종(Input/Conv1w/Conv2w/FCw)의 Port A 는 외부 포트로 노출 →
//   block design 에서 AXI BRAM Controller 연결.
//////////////////////////////////////////////////////////////////////////////////

module cnn_accelerator (
    input  wire        clk,
    input  wire        resetn,        // 외부 보드 reset 버튼 (active-low)

    //==========================================================================
    // CSR_AXI 제어/상태
    //==========================================================================
    input  wire        enable,        // 가동 (trigger qualify)
    input  wire        start,         // 1-cycle pulse: weight load + timer 시작
    input  wire        img_ready,     // 1-cycle pulse: 새 image 준비 → conv1 trigger
    output wire [3:0]  result,        // 분류 결과 digit (0~9)
    output wire        img_done,      // image 처리 완료 pulse (fc.class_valid 지연)
    output wire        input_consumed,// conv1 input read 완료 (= conv1_rdone) — PS overlap backpressure

    //==========================================================================
    // Input BRAM Port A  (PS write via AXI BRAM Ctrl)
    //==========================================================================
    input  wire        in_ena,
    input  wire [3:0]  in_wea,
    input  wire [8:0]  in_addra,
    input  wire [31:0] in_dina,

    //==========================================================================
    // Conv1 weight BRAM Port A  (PS write)
    //==========================================================================
    input  wire        c1w_ena,
    input  wire [3:0]  c1w_wea,
    input  wire [5:0]  c1w_addra,
    input  wire [31:0] c1w_dina,

    //==========================================================================
    // Conv2 weight BRAM Port A  (PS write, conv2_engine 내부 BMG)
    //==========================================================================
    input  wire        c2w_ena,
    input  wire [3:0]  c2w_wea,
    input  wire [9:0]  c2w_addra,
    input  wire [31:0] c2w_dina,

    //==========================================================================
    // FC weight BRAM Port A  (PS write, fc_engine 내부 BMG)
    //   256b × 1024 (720 used). 32-bit MicroBlaze 는 32→256 datawidth converter +
    //   256-bit AXI BRAM Controller 경유로 write (firmware 는 5760 × 32b 그대로).
    //==========================================================================
    input  wire         fcw_ena,
    input  wire [31:0]  fcw_wea,
    input  wire [9:0]   fcw_addra,
    input  wire [255:0] fcw_dina,

    //==========================================================================
    // Output result BRAM Port B  (PS read via AXI BRAM Ctrl — bram_output)
    //   PL 이 img_done 마다 result 1 byte 누적(Port A, 내부) / PS 가 32b burst read(Port B).
    //   word k = image 4k..4k+3 의 result (little-endian: img4k = res_rd_data[7:0]).
    //   res_rd_addr = word 주소 (AXI byte addr >> 2 — block design 에서 slice).
    //==========================================================================
    input  wire        res_rd_en,
    input  wire [11:0] res_rd_addr,
    output wire [31:0] res_rd_data
);

    //==========================================================================
    // Reset (active-high 내부 통일)
    //==========================================================================
    wire rst = ~resetn;

    //==========================================================================
    // Trigger (enable 으로 qualify)
    //   start / img_ready 는 CSR 가 만든 1-cycle pulse.
    //==========================================================================
    wire conv2_start_q = start     & enable;   // weight load 1회 진입
    wire conv1_prior   = img_ready & enable;   // image-by-image trigger

    //==========================================================================
    // Handshake chain (direct wire — 통합 TB 검증 배선)
    //==========================================================================
    wire conv1_done;
    wire conv1_rdone, conv1_wdone;
    wire conv2_rdone, conv2_wdone;
    wire maxpool_done;
    wire maxpool_rdone, maxpool_wdone;
    wire fc_rdone;
    wire [3:0] class_idx;
    wire       class_valid;

    //==========================================================================
    // BMG nets
    //==========================================================================
    // Input BRAM Port B (conv1 read)
    wire [10:0]  in_addrb;
    wire         in_enb;
    wire signed [7:0] in_doutb;

    // c1c2 (conv1 write A / conv2 read B)
    wire         c1c2_we_a;
    wire [7:0]   c1c2_wea_a;
    wire [10:0]  c1c2_addr_a;
    wire [63:0]  c1c2_din_a;
    wire         c1c2_re_b;
    wire [10:0]  c1c2_addr_b;
    wire [63:0]  c1c2_doutb_b;

    // c2pool (conv2 write A / maxpool read B)
    wire         c2pool_we_a;
    wire [10:0]  c2pool_addr_a;
    wire [127:0] c2pool_din_a;
    wire [10:0]  maxpool_c2pool_rd_addr;   // 11-bit physical {input_bank_sel, local}
    wire         c2pool_re_b;
    wire [127:0] c2pool_doutb_b;

    // poolfc (maxpool write A / fc read B)
    wire [8:0]   poolfc_wr_addr;
    wire         poolfc_wr_en;
    wire [127:0] poolfc_wr_data;
    wire         fc_poolfc_re;
    wire [8:0]   fc_poolfc_addr;
    wire [127:0] fc_poolfc_dout;

    //==========================================================================
    // BMG instances (PS-write 4종 + inter-layer 3종 = 본 모듈 내부)
    //==========================================================================
    bram_input in_bmg (
        .clka  (clk), .ena (in_ena), .wea (in_wea),
        .addra (in_addra), .dina (in_dina),
        .clkb  (clk), .enb (in_enb),
        .addrb (in_addrb), .doutb (in_doutb)
    );

    // conv1 weight BRAM 은 conv1_engine 내부 인스턴스 (conv2/fc 와 일관) — c1w Port A passthrough

    bram_c1_to_c2 c1c2_bmg (
        .clka  (clk), .ena (c1c2_we_a), .wea (c1c2_wea_a),
        .addra (c1c2_addr_a), .dina (c1c2_din_a),
        .clkb  (clk), .enb (c1c2_re_b),
        .addrb (c1c2_addr_b), .doutb (c1c2_doutb_b)
    );

    bram_c2_to_pool c2pool_bmg (
        .clka  (clk), .ena (c2pool_we_a), .wea (c2pool_we_a),
        .addra (c2pool_addr_a), .dina (c2pool_din_a),
        .clkb  (clk), .enb (c2pool_re_b),
        .addrb (maxpool_c2pool_rd_addr),
        .doutb (c2pool_doutb_b),
        .regceb (1'b1)                          // 출력 reg always-follow (마지막 read p11 전파)
    );

    // poolfc: maxpool write(Port A, physical {output_bank_sel,addr}) / fc read(Port B)
    bram_pool_to_fc poolfc_bmg (
        .clka  (clk), .ena (poolfc_wr_en), .wea (poolfc_wr_en),
        .addra (poolfc_wr_addr), .dina (poolfc_wr_data),
        .clkb  (clk), .enb (fc_poolfc_re),
        .addrb (fc_poolfc_addr), .doutb (fc_poolfc_dout),
        .regceb (1'b1)                          // 출력 reg always-follow (FC 마지막 read sp143 전파)
    );

    //==========================================================================
    // DUT 1: Conv1
    //==========================================================================
    conv1_engine conv1 (
        .clk          (clk),
        .rst          (rst),
        .start        (1'b0),                 // legacy (사용 X)
        .done         (conv1_done),

        .prior_wdone  (conv1_prior),          // image trigger (img_ready & enable)
        .succ_rdone   (conv2_rdone),
        .rdone        (conv1_rdone),
        .wdone        (conv1_wdone),

        .in_bram_addr (in_addrb),
        .in_bram_en   (in_enb),
        .in_bram_dout (in_doutb),

        .c1w_ena      (c1w_ena),
        .c1w_wea      (c1w_wea),
        .c1w_addra    (c1w_addra),
        .c1w_dina     (c1w_dina),

        .c1c2_we      (c1c2_we_a),
        .c1c2_wea     (c1c2_wea_a),
        .c1c2_addr    (c1c2_addr_a),
        .c1c2_din     (c1c2_din_a)
    );

    //==========================================================================
    // DUT 2: Conv2  (weight BMG 내부, Port A 외부 패스through)
    //==========================================================================
    conv2_engine conv2 (
        .clk         (clk),
        .rst         (rst),
        .start       (conv2_start_q),         // LOAD_WEIGHTS 1회

        .c2w_ena     (c2w_ena),
        .c2w_wea     (c2w_wea),
        .c2w_addra   (c2w_addra),
        .c2w_dina    (c2w_dina),

        .c1c2_re     (c1c2_re_b),
        .c1c2_addr   (c1c2_addr_b),
        .c1c2_dout   (c1c2_doutb_b),

        .c2pool_we   (c2pool_we_a),
        .c2pool_addr (c2pool_addr_a),
        .c2pool_din  (c2pool_din_a),

        .prior_wdone (conv1_wdone),
        .rdone       (conv2_rdone),
        .succ_rdone  (maxpool_rdone),
        .wdone       (conv2_wdone)
    );

    //==========================================================================
    // DUT 3: Maxpool
    //==========================================================================
    maxpool_engine maxpool (
        .clk             (clk),
        .rst             (rst),
        .start           (1'b0),
        .done            (maxpool_done),

        .prior_wdone     (conv2_wdone),
        .succ_rdone      (fc_rdone),
        .rdone           (maxpool_rdone),
        .wdone           (maxpool_wdone),

        .c2pool_rd_addr  (maxpool_c2pool_rd_addr),
        .c2pool_rd_en    (c2pool_re_b),
        .c2pool_rd_data  (c2pool_doutb_b),

        .poolfc_wr_addr  (poolfc_wr_addr),
        .poolfc_wr_en    (poolfc_wr_en),
        .poolfc_wr_data  (poolfc_wr_data)
    );

    //==========================================================================
    // DUT 4: FC (terminal, weight BMG 내부)
    //==========================================================================
    fc_engine #(.ACC_W(24)) fc (
        .clk         (clk),
        .rst         (rst),
        .start       (1'b0),                  // prior_wdone 트리거 (start 미사용)

        .fcw_ena     (fcw_ena),
        .fcw_wea     (fcw_wea),
        .fcw_addra   (fcw_addra),
        .fcw_dina    (fcw_dina),

        .poolfc_re   (fc_poolfc_re),
        .poolfc_addr (fc_poolfc_addr),
        .poolfc_dout (fc_poolfc_dout),

        .prior_wdone (maxpool_wdone),
        .rdone       (fc_rdone),

        .class_idx   (class_idx),
        .class_valid (class_valid)
    );

    //==========================================================================
    // Result / img_done  (class_valid 시 latch → CSR 가 안정적으로 read)
    //==========================================================================
    reg [3:0] result_r;
    reg       img_done_r;
    always @(posedge clk) begin
        if (rst) begin
            result_r   <= 4'd0;
            img_done_r <= 1'b0;
        end else begin
            img_done_r <= class_valid;
            if (class_valid)
                result_r <= class_idx;
        end
    end

    assign result   = result_r;
    assign img_done = img_done_r;

    // input-consumed: conv1 이 input BRAM read 를 끝낸 시점(RUN2 끝) 의 1-cycle pulse.
    //   PS 가 같은 bank 에 다음 image(i+2) 를 안전하게 write 할 수 있는 backpressure 신호.
    assign input_consumed = conv1_rdone;

    //==========================================================================
    // Output result store (bram_output) — per-image 결과 누적  [작업순서 1]
    //   img_done 마다 result_r(4-bit) 를 1 byte 로 res_wr_ptr(=image index) 에 write.
    //   res_wr_ptr 은 CSR img_cnt 와 동일 이벤트(img_done)·동일 cap(10000) → 자동 동기.
    //   PS 는 Port B(res_rd_*)로 종료 후 일괄 read → 파이프라이닝(overlap) 중에도 결과
    //   손실 없음 (단일 CSR result_latch 가 다음 image 에 덮이는 문제 해소).
    //   bram_output: SDP 비대칭 8(write)/32(read), independent-clock IP 를 clka=clkb=clk
    //   로 묶어 현재 common 동작 (overclock 시 clkb 만 AXI 로 분리; 재생성 불필요).
    //==========================================================================
    reg  [13:0] res_wr_ptr;
    wire        res_we  = img_done_r && (res_wr_ptr < 14'd10000);  // image 0..9999
    wire [7:0]  res_din = {4'b0000, result_r};                     // {pad, digit}

    always @(posedge clk) begin
        if (rst)         res_wr_ptr <= 14'd0;
        else if (res_we) res_wr_ptr <= res_wr_ptr + 14'd1;
    end

    bram_output res_bmg (
        // Port A — PL write (8-bit), result-writer
        .clka  (clk),
        .ena   (res_we),                 // ENA = WEA = img_done (cap 10000)
        .wea   (res_we),                 // 1-bit (Byte Write Disable)
        .addra (res_wr_ptr),             // 14-bit image index
        .dina  (res_din),                // 8-bit {pad, result}
        // Port B — PS read (32-bit) via AXI BRAM Ctrl
        .clkb  (clk),
        .enb   (res_rd_en),
        .addrb (res_rd_addr),            // 12-bit word addr
        .doutb (res_rd_data)             // 32-bit = 4 results
    );

endmodule
