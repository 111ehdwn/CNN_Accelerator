`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: cnn_accelerator  (PL core, Team Assignment 2)
//
//   Pipeline (검증된 통합 TB 배선 그대로):
//     Input BRAM → Conv1 → c1c2 → Conv2 → c2pool → Maxpool → poolfc → FC → class
//
//   ★★ 클럭 도메인 (300MHz overclock):
//     clk  = 300MHz : datapath (전 engine + inter-stage/weight BMG Port B). 같은 MMCM(clk_wiz).
//     aclk = 100MHz : CSR·AXI BRAM Ctrl·CDMA 도메인. 제어 pulse CDC 의 100측 + bram_output Port B.
//     - 제어 pulse(start/img_ready: 100→300, img_done/input_consumed: 300→100)는 본 모듈 내부
//       cdc_pulse_sync(toggle) + cdc_bit_sync(enable level)로 도메인 횡단. CSR/firmware 무변경.
//     - inter-stage(c1c2/c2pool/poolfc)·weight·bram_input BMG 는 clka=clkb=clk(300) common-clock 유지
//       (regen 불필요). AXI BRAM Ctrl(100) → Port A write 버스의 100→300 횡단은 XDC
//       set_multicycle_path(같은 MMCM 위상정렬) 로 처리. bram_output 만 independent-clock
//       (clka=clk write / clkb=aclk read). 상세: docs/overclock_300mhz.md.
//
//   제어 인터페이스 (CSR_AXI ↔ PL):
//     resetn    : 외부 보드 reset 버튼 (active-low, 100MHz peripheral_aresetn). rst(300)/rst_a(100) 도메인 동기화.
//     enable    : 1 이면 가동 (trigger qualify). 0 이면 start/img_ready 무시. (aclk→clk 2-FF 동기)
//     start     : aclk(100) 1-cycle pulse → cdc_pulse_sync → clk(300) 1-cycle. conv2 LOAD_WEIGHTS 진입.
//     img_ready : aclk(100) 1-cycle pulse → cdc_pulse_sync → clk(300) 1-cycle. PS 가 Input BRAM 에
//                 새 image write 완료 알림 → conv1 prior_wdone (image-by-image trigger).
//     result    : 4-bit, 현재 완료 image 의 분류 결과 (class_valid 시 latch).
//     img_done  : clk(300) image 완료 pulse(=fc.class_valid 지연) → cdc_pulse_sync → aclk(100) 1-cycle.
//     input_consumed : clk(300) conv1 input read 완료(=conv1_rdone) → cdc_pulse_sync → aclk(100) 1-cycle.
//                      PS 가 같은 bank 에 다음 image 적재 가능 시점 (overlap backpressure, CSR can_load).
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
    input  wire        clk,           // ★ 300MHz datapath clock (overclock). 모든 engine + BMG Port B.
    input  wire        aclk,          // ★ 100MHz 제어/AXI-side clock (CSR·AXI BRAM Ctrl 와 동일 MMCM 출력).
                                       //    제어 pulse CDC 의 100MHz 측 + bram_output Port B(PS read) clkb.
    input  wire        resetn,        // 외부 보드 reset 버튼 (active-low)

    //==========================================================================
    // CSR_AXI 제어/상태
    //==========================================================================
    input  wire        enable,        // 가동 (trigger qualify)
    input  wire        start,         // 1-cycle pulse: weight load + timer 시작
    input  wire        img_ready,     // 1-cycle pulse: 새 image 준비 → conv1 trigger
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
    //   512b × 1024 (720 used) = 16ch × 32b SIMD-A/word. 32-bit MicroBlaze 는
    //   32→512 datawidth converter + 512-bit AXI BRAM Controller 경유로 write
    //   (firmware 는 11520 × 32b SIMD 를 변환 없이 그대로).
    //==========================================================================
    input  wire         fcw_ena,
    input  wire [63:0]  fcw_wea,
    input  wire [9:0]   fcw_addra,
    input  wire [511:0] fcw_dina,

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
    // Reset (도메인별 active-high 동기화) — 300MHz overclock
    //   resetn = peripheral_aresetn (proc_sys_reset 출력, 100MHz=aclk 에 이미 동기, active-low).
    //   rst_a : aclk(100) 도메인 reset — resetn 이 이미 100 동기라 직결.
    //   rst   : clk(300) 도메인 reset — resetn 이 300 에 비동기이므로 async-assert /
    //           sync-deassert 재동기화 (reset-removal 메타스테이블 방지). 하류 datapath 는
    //           기존처럼 동기 `if(rst)` 로 사용.
    //==========================================================================
    wire rst_a = ~resetn;

    (* ASYNC_REG = "TRUE" *) reg rst_meta, rst_sync;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin rst_meta <= 1'b1; rst_sync <= 1'b1; end
        else         begin rst_meta <= 1'b0; rst_sync <= rst_meta; end
    end

    //==========================================================================
    // Reset 분배 트리 (300MHz fanout 완화)
    //   기존: rst_sync 단일 net 이 datapath 전 register(~41k load)로 직접 fanout
    //         → BUFG + die 전역 route 로 300MHz 최대 WNS 경로(−1.94, route 85%).
    //   변경: async-assert / sync-deassert 를 유지한 채 registered 복제 트리로 분배.
    //         rst_sync(1) → rst_l1[~11] → rst(leaf ~323) → datapath. max_fanout 으로
    //         합성이 각 단을 자동 복제하고, 각 leaf 가 자기 cluster 근처에 배치되어
    //         high-fanout net 이 짧은 local net 다수로 쪼개짐 (BUFG 불필요).
    //   ★ 기능 불변: 모든 하류 register 가 동일하게 reset 됨. deassert 만 +2 clk 더
    //     지연(전체 idle-start 라 무해), assertion 은 각 단이 negedge resetn 으로 즉시.
    //==========================================================================
    (* max_fanout = 32 *)  reg rst_l1;     // L1: trunk (few copies)
    always @(posedge clk or negedge resetn)
        if (!resetn) rst_l1 <= 1'b1;
        else         rst_l1 <= rst_sync;

    (* max_fanout = 128 *) reg rst_leaf;   // L2: leaf (heavily replicated → datapath)
    always @(posedge clk or negedge resetn)
        if (!resetn) rst_leaf <= 1'b1;
        else         rst_leaf <= rst_l1;

    wire rst = rst_leaf;

    //==========================================================================
    // 제어 pulse CDC (CSR aclk=100MHz → datapath clk=300MHz) — ★ 300MHz overclock 핵심
    //   start / img_ready : CSR 의 1-cycle@100 pulse 가 300MHz 에서 3 cycle 로 보여
    //                       "3배 카운트"(conv1 prior_diff -=3 등) 위험 → toggle 동기화기로
    //                       정확히 1-cycle@300 pulse 복원.
    //   enable            : level → 2-FF 동기화.
    //   (img_done / input_consumed 의 300→100 CDC 는 출력부에서 처리.)
    //==========================================================================
    wire enable_q;       // clk(300) 동기 enable level
    wire start_q;        // clk(300) 1-cycle start pulse
    wire img_ready_q;    // clk(300) 1-cycle img_ready pulse

    cdc_bit_sync u_enable_sync (
        .dst_clk(clk), .dst_rst(rst), .d_in(enable), .d_out(enable_q)
    );
    cdc_pulse_sync u_start_sync (
        .src_clk(aclk), .src_rst(rst_a), .pulse_in(start),
        .dst_clk(clk),  .dst_rst(rst),   .pulse_out(start_q)
    );
    cdc_pulse_sync u_imgready_sync (
        .src_clk(aclk), .src_rst(rst_a), .pulse_in(img_ready),
        .dst_clk(clk),  .dst_rst(rst),   .pulse_out(img_ready_q)
    );

    wire conv2_start_q = start_q     & enable_q;   // weight load 1회 진입
    wire conv1_prior   = img_ready_q & enable_q;   // image-by-image trigger

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

    // result 출력 포트 제거 — result_r 은 아래 result-writer 가 bram_output 에 쓰는 데만 사용.
    // img_done_r (1-cycle@300) 은 (1) 아래 result-writer 와 (2) CSR 로 가는 CDC 의 source.

    //==========================================================================
    // 제어 pulse CDC (datapath clk=300MHz → CSR aclk=100MHz) — ★ 300MHz overclock
    //   img_done / input_consumed : 1-cycle@300 pulse(3.33ns)는 100MHz 가 놓칠 수 있음
    //     → toggle 동기화기로 1-cycle@100 pulse 복원. CSR(img_cnt / inflight) 는 무변경.
    //   input-consumed: conv1 이 input BRAM read 완료(RUN2 끝) 1-cycle pulse(= conv1_rdone).
    //     PS 가 같은 bank 에 다음 image(i+2) 적재 가능 backpressure (CSR can_load).
    //==========================================================================
    cdc_pulse_sync u_imgdone_sync (
        .src_clk(clk),  .src_rst(rst),   .pulse_in(img_done_r),
        .dst_clk(aclk), .dst_rst(rst_a), .pulse_out(img_done)
    );
    cdc_pulse_sync u_inputcons_sync (
        .src_clk(clk),  .src_rst(rst),   .pulse_in(conv1_rdone),
        .dst_clk(aclk), .dst_rst(rst_a), .pulse_out(input_consumed)
    );

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
        // Port B — PS read (32-bit) via AXI BRAM Ctrl @100MHz (aclk) — independent-clock IP
        .clkb  (aclk),
        .enb   (res_rd_en),
        .addrb (res_rd_addr),            // 12-bit word addr
        .doutb (res_rd_data)             // 32-bit = 4 results
    );

endmodule
