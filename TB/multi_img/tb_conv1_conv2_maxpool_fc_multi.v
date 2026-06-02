`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_conv1_conv2_maxpool_fc_multi.v
// Full-pipeline multi-image 통합 TB: Conv1 + Conv2 + Maxpool + FC
//
//   Pipeline:
//     PS → bram_input → Conv1 → bram_c1_to_c2 → Conv2 → bram_c2_to_pool
//        → Maxpool → poolfc(behavioral) → FC → class_idx
//
//   Handshake chain (전부 direct wire — TB bridge 없음):
//     conv1.wdone   → conv2.prior_wdone     (c1c2 write 완료)
//     conv2.rdone   → conv1.succ_rdone      (c1c2 read 완료)
//     conv2.wdone   → maxpool.prior_wdone   (c2pool write 완료)
//     maxpool.rdone → conv2.succ_rdone      (c2pool read 완료)
//     maxpool.wdone → fc.prior_wdone        (poolfc write 완료 = FC image trigger)
//     fc.rdone      → maxpool.succ_rdone    (poolfc bank read 완료 = bank 비움)
//     conv1.prior_wdone : TB pulse per image (입력 image ready)
//     FC = terminal layer — class_idx / class_valid 직출 (output handshake 없음)
//
//   ping-pong bank: 모든 engine 내부 toggle FF 가 관리 (TB driving 없음).
//     poolfc 는 dumb 2-bank behavioral mem (maxpool write Port A + FC read Port B).
//
//   검증 (CHECK_LABEL):
//     1 (기본): logit bit-exact (fc.logit_reg vs all_fc_logit.hex) + class_idx(argmax).
//     0       : weight 없이 handshake/bank 흐름만 검증 (class_valid N회).
//
//   ★ Vivado 이관 체크리스트:
//     1. TB/models/dsp48e1_model.v, TB/models/bmg_sim_models.v 를 시뮬 소스에서 제외
//        (실제 BMG IP + DSP48E1 unisim 과 module 중복 정의 충돌).
//     2. hex 경로는 아래 `ifdef __ICARUS__ 로 자동 분기 — `else(Vivado) 블록 경로를
//        VM 실제 위치로 조정하고, data/ 의 hex 들을 VM 으로 복사/공유.
//     3. 필요 BMG IP (Vivado 생성):
//        - TB 인스턴스        : bram_input, bram_c1_to_c2, bram_c2_to_pool
//        - engine 내부 인스턴스 : conv1_weight_bram(conv1), conv2_weight_bram(conv2), fc_weight_bram(fc)
//        (poolfc 는 본 TB 의 behavioral mem — IP 불필요)
//////////////////////////////////////////////////////////////////////////////////

//   경로: iverilog(__ICARUS__ 자동 정의)=로컬 상대(cwd=프로젝트 루트),
//         Vivado=Windows 절대경로. Vivado VM 의 실제 data 위치에 맞게 `else 조정.
`ifdef __ICARUS__
  `define ALL_INPUT_HEX    "data/multi_img/all_input.hex"
  `define CONV1_WEIGHT_HEX "data/weights_simd/conv1_weights_simd.hex"
  `define CONV2_WEIGHT_HEX "data/weights_simd/conv2_weights_simd.hex"
  `define FCW_HEX          "data/weights_simd/fc_weights_simd.hex"
  `define FC_LOGIT_HEX     "data/multi_img/all_fc_logit.hex"
`else
  // Vivado (Windows) — 기존 단위 TB 와 동일 베이스. VM 실제 경로로 조정할 것.
  `define ALL_INPUT_HEX    "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_input.hex"
  `define CONV1_WEIGHT_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_weights_simd.hex"
  `define CONV2_WEIGHT_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_weights_simd.hex"
  `define FCW_HEX          "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/fc_weights_simd.hex"
  `define FC_LOGIT_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_fc_logit.hex"
`endif


module tb_conv1_conv2_maxpool_fc_multi;

    parameter N_IMAGES   = 40;
    parameter ACC_W      = 24;

    // weight + expected logit 준비됨 → class_idx + logit bit-exact 검증 활성화.
    //   0 으로 두면 handshake/bank/흐름(class_valid N회)만 검증.
    parameter CHECK_LABEL = 1;

    //==========================================================================
    // Clock / reset (100 MHz, all-DUT active-high rst 통일)
    //==========================================================================
    reg clk = 1'b0;
    reg rst = 1'b1;       // active-high, initial asserted
    always #5 clk = ~clk;

    //==========================================================================
    // Top-level control
    //==========================================================================
    reg          conv1_start    = 1'b0;          // legacy (사용 X — prior_wdone 트리거)
    reg          conv2_start    = 1'b0;          // LOAD_WEIGHTS 1회 진입용
    reg          maxpool_start  = 1'b0;          // legacy (사용 X)
    reg          fc_start       = 1'b0;          // legacy (사용 X — prior_wdone 트리거)
    wire         conv1_done;
    wire         maxpool_done;                   // legacy

    // Direct-wire handshake signals (conv1→conv2→maxpool→fc chain)
    wire         conv1_rdone, conv1_wdone;
    wire         conv2_rdone, conv2_wdone;
    wire         maxpool_rdone, maxpool_wdone;
    wire         fc_rdone;
    reg          conv1_prior_wdone = 1'b0;       // TB pulses per image (Conv1 trigger)

    // FC result (terminal)
    wire [3:0]   class_idx;
    wire         class_valid;

    //==========================================================================
    // BMG signal nets
    //==========================================================================
    // bram_input
    reg          in_ena   = 1'b0;
    reg  [3:0]   in_wea   = 4'd0;
    reg  [8:0]   in_addra = 9'd0;
    reg  [31:0]  in_dina  = 32'd0;
    wire [10:0]  in_addrb;
    wire         in_enb;
    wire signed [7:0] in_doutb;

    // conv1 weight Port A (conv1_engine 내부 BMG)
    reg          c1w_ena    = 1'b0;
    reg  [3:0]   c1w_wea    = 4'd0;
    reg  [5:0]   c1w_addra  = 6'd0;
    reg  [31:0]  c1w_dina   = 32'd0;

    // bram_c1_to_c2 (conv1 write A, conv2 read B)
    wire         c1c2_we_a;
    wire [7:0]   c1c2_wea_a;
    wire [10:0]  c1c2_addr_a;
    wire [63:0]  c1c2_din_a;
    wire         c1c2_re_b;
    wire [10:0]  c1c2_addr_b;
    wire [63:0]  c1c2_doutb_b;

    // conv2_weight_bram (Port A write, conv2_engine 내부에서 read)
    reg          c2w_ena   = 1'b0;
    reg  [3:0]   c2w_wea   = 4'd0;
    reg  [9:0]   c2w_addra = 10'd0;
    reg  [31:0]  c2w_dina  = 32'd0;

    // bram_c2_to_pool (conv2 write A, maxpool read B)
    wire         c2pool_we_a;
    wire [10:0]  c2pool_addr_a;
    wire [127:0] c2pool_din_a;
    wire [10:0]  maxpool_c2pool_rd_addr;        // 11-bit physical {input_bank_sel, local}
    wire         c2pool_re_b;
    wire [127:0] c2pool_doutb_b;

    // poolfc (maxpool write side)
    wire [8:0]   poolfc_wr_addr;                // {output_bank_sel, out_addr[7:0]}
    wire         poolfc_wr_en;
    wire [127:0] poolfc_wr_data;

    // poolfc (FC read side)
    wire         fc_poolfc_re;
    wire [8:0]   fc_poolfc_addr;                // {input_bank_sel, s_cnt[7:0]}
    reg  [127:0] fc_poolfc_dout = 128'd0;

    // fc_weight_bram (Port A write, fc_engine 내부에서 read)
    reg          fcw_ena   = 1'b0;
    reg  [31:0]  fcw_wea   = 32'd0;
    reg  [9:0]   fcw_addra = 10'd0;
    reg  [255:0] fcw_dina  = 256'd0;

    //==========================================================================
    // Counters (handshake-tracked, backpressure + 통계용)
    //==========================================================================
    integer conv1_rdone_count = 0;              // conv1 dispatcher backpressure
    integer conv2_rdone_count = 0;
    integer maxpool_wdone_count = 0;
    integer fc_rdone_count = 0;

    always @(posedge clk) begin
        if (rst) begin
            conv1_rdone_count   <= 0;
            conv2_rdone_count   <= 0;
            maxpool_wdone_count <= 0;
            fc_rdone_count      <= 0;
        end else begin
            if (conv1_rdone)   conv1_rdone_count   <= conv1_rdone_count   + 1;
            if (conv2_rdone)   conv2_rdone_count   <= conv2_rdone_count   + 1;
            if (maxpool_wdone) maxpool_wdone_count <= maxpool_wdone_count + 1;
            if (fc_rdone)      fc_rdone_count      <= fc_rdone_count      + 1;
        end
    end

    //==========================================================================
    // BMG IP instances (poolfc 제외 — poolfc 는 behavioral mem)
    //==========================================================================
    bram_input in_bmg (
        .clka  (clk), .ena (in_ena), .wea (in_wea),
        .addra (in_addra), .dina (in_dina),
        .clkb  (clk), .enb (in_enb),
        .addrb (in_addrb), .doutb (in_doutb)
    );

    // conv1_weight_bram 은 conv1_engine 내부 인스턴스로 이동 (TB 외부 인스턴스 제거)

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
        .addrb (maxpool_c2pool_rd_addr),         // maxpool physical addr 직접 출력 (11-bit)
        .doutb (c2pool_doutb_b),
        .regceb (1'b1)                           // 출력 reg always-follow (마지막 read p11 전파)
    );

    //==========================================================================
    // DUT 1: Conv1
    //==========================================================================
    conv1_engine conv1 (
        .clk            (clk),
        .rst            (rst),
        .start          (conv1_start),
        .done           (conv1_done),

        .prior_wdone    (conv1_prior_wdone),
        .succ_rdone     (conv2_rdone),           // direct wire
        .rdone          (conv1_rdone),
        .wdone          (conv1_wdone),

        .in_bram_addr   (in_addrb),
        .in_bram_en     (in_enb),
        .in_bram_dout   (in_doutb),

        .c1w_ena        (c1w_ena),
        .c1w_wea        (c1w_wea),
        .c1w_addra      (c1w_addra),
        .c1w_dina       (c1w_dina),

        .c1c2_we        (c1c2_we_a),
        .c1c2_wea       (c1c2_wea_a),
        .c1c2_addr      (c1c2_addr_a),
        .c1c2_din       (c1c2_din_a)
    );

    //==========================================================================
    // DUT 2: Conv2
    //==========================================================================
    conv2_engine conv2 (
        .clk         (clk),
        .rst         (rst),
        .start       (conv2_start),

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

        .prior_wdone (conv1_wdone),               // direct wire from conv1
        .rdone       (conv2_rdone),
        .succ_rdone  (maxpool_rdone),             // direct wire from maxpool
        .wdone       (conv2_wdone)
    );

    //==========================================================================
    // DUT 3: Maxpool
    //   succ_rdone : fc.rdone direct wire (poolfc bank 비움)
    //==========================================================================
    maxpool_engine maxpool (
        .clk             (clk),
        .rst             (rst),
        .start           (maxpool_start),
        .done            (maxpool_done),

        .prior_wdone     (conv2_wdone),           // direct wire
        .succ_rdone      (fc_rdone),              // direct wire from FC
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
    // DUT 4: FC (terminal)
    //   prior_wdone : maxpool.wdone direct wire (poolfc image ready)
    //   rdone       : → maxpool.succ_rdone direct wire
    //   weight      : fcw_* (fc_engine 내부 fc_weight_bram) — TODO weight
    //==========================================================================
    fc_engine #(.ACC_W(ACC_W)) fc (
        .clk         (clk),
        .rst         (rst),
        .start       (fc_start),

        .fcw_ena     (fcw_ena),
        .fcw_wea     (fcw_wea),
        .fcw_addra   (fcw_addra),
        .fcw_dina    (fcw_dina),

        .poolfc_re   (fc_poolfc_re),
        .poolfc_addr (fc_poolfc_addr),
        .poolfc_dout (fc_poolfc_dout),

        .prior_wdone (maxpool_wdone),             // direct wire from maxpool
        .rdone       (fc_rdone),

        .class_idx   (class_idx),
        .class_valid (class_valid)
    );

    //==========================================================================
    // poolfc dumb 2-bank behavioral mem (128-bit × 512 = 2 bank × 256)
    //   Port A (write) : maxpool — physical addr {output_bank_sel, out_addr[7:0]}
    //   Port B (read)  : FC      — physical addr {input_bank_sel,  s_cnt[7:0]}, L=1
    //   maxpool/fc 가 자기 bank 를 prepend 하므로 buffer 는 단순 RAM.
    //==========================================================================
    reg [127:0] poolfc_mem [0:511];

    always @(posedge clk) begin
        if (poolfc_wr_en)
            poolfc_mem[poolfc_wr_addr] <= poolfc_wr_data;
    end

    // L=2: core read register (ENB) + output primitive register (REGCEB tied 1).
    //   ★ 출력 reg 는 ENB 게이팅 금지 — 마지막 read (pair4 sp143) 직후 ENB=0 이 되어도
    //   REGCEB=1 (항상 follow) 이라야 doutb 까지 전파 (bram_c2_to_pool / 실 IP 와 동일).
    reg [127:0] fc_poolfc_dout_i;
    always @(posedge clk) begin
        if (fc_poolfc_re) fc_poolfc_dout_i <= poolfc_mem[fc_poolfc_addr];  // core: ENB gated
        fc_poolfc_dout <= fc_poolfc_dout_i;                                // output reg: 항상 follow
    end

    //==========================================================================
    // TB-local memory
    //==========================================================================
    reg [7:0]   input_data      [0:N_IMAGES*784-1];
    reg [31:0]  weight1_mem     [0:35];
    reg [31:0]  weight2_mem     [0:575];
    reg [31:0]  fc_weight_simd  [0:11519];        // FC SIMD-packed weight (720*16 line)
    reg signed [23:0] exp_logit [0:N_IMAGES*10-1]; // expected logit (argmax→class), CHECK_LABEL=1

    //==========================================================================
    // Statistics
    //==========================================================================
    integer cycle_cnt = 0;
    integer images_pass = 0;
    integer results_seen = 0;
    integer cycle_at_img_start [0:N_IMAGES-1];
    integer cycle_at_result    [0:N_IMAGES-1];
    integer captured_class     [0:N_IMAGES-1];
    integer cycle_at_start_pulse = 0;

    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Tasks
    //==========================================================================
    // Conv1 weight (36 entry, 32-bit) — PS-style Port A write
    task init_weight1;
        integer wi;
        begin
            $display("[TB] @ cyc %0d : init_weight1 start (36)", cycle_cnt);
            for (wi = 0; wi < 36; wi = wi + 1) begin
                @(negedge clk);
                c1w_ena = 1'b1;
                c1w_wea = 4'hF;
                c1w_addra = wi[5:0]; c1w_dina = weight1_mem[wi];
            end
            @(negedge clk); c1w_ena = 1'b0; c1w_wea = 4'd0;
            $display("[TB] @ cyc %0d : init_weight1 done", cycle_cnt);
        end
    endtask

    // Conv2 weight (576 entry, 32-bit) — PS-style Port A write
    task init_weight2;
        integer wi;
        begin
            $display("[TB] @ cyc %0d : init_weight2 start (576)", cycle_cnt);
            for (wi = 0; wi < 576; wi = wi + 1) begin
                @(negedge clk);
                c2w_ena = 1'b1;
                c2w_wea = 4'hF;
                c2w_addra = wi[9:0]; c2w_dina = weight2_mem[wi];
            end
            @(negedge clk); c2w_ena = 1'b0; c2w_wea = 4'd0;
            $display("[TB] @ cyc %0d : init_weight2 done", cycle_cnt);
        end
    endtask

    // FC weight (720 entry × 256-bit) — SIMD unpack 후 Port A write.
    //   fc_weights_simd.hex : 11520 line × 32-bit (W1*2^17 + W0), line = pair*144*16 + s*16 + c
    //   dina = {w_odd_concat[127:0](16ch), w_even_concat[127:0](16ch)}
    //   ★ TODO: weight 생성 코드 확정 후 packing/unpack 포맷 재확인.
    task load_fc_weights;
        integer pair, s, c, k, line_idx;
        reg signed [7:0]  w0, w1;
        reg signed [16:0] w0_packed_17;
        reg signed [7:0]  w1_packed_8;
        reg [127:0]       w_even_concat, w_odd_concat;
        reg [255:0]       word;
        begin
            $display("[TB] @ cyc %0d : load_fc_weights start (720)", cycle_cnt);
            for (pair = 0; pair < 5; pair = pair + 1) begin
                for (s = 0; s < 144; s = s + 1) begin
                    w_even_concat = 128'd0;
                    w_odd_concat  = 128'd0;
                    for (c = 0; c < 16; c = c + 1) begin
                        line_idx     = pair*144*16 + s*16 + c;
                        w0_packed_17 = $signed(fc_weight_simd[line_idx][16:0]);
                        w1_packed_8  = $signed(fc_weight_simd[line_idx][24:17]);
                        w0 = w0_packed_17[7:0];
                        w1 = w1_packed_8 + (w0_packed_17[16] ? 8'sd1 : 8'sd0);   // carry correction
                        w_even_concat[c*8 +: 8] = w0;
                        w_odd_concat [c*8 +: 8] = w1;
                    end
                    word = {w_odd_concat, w_even_concat};
                    @(negedge clk);
                    fcw_ena   = 1'b1;
                    fcw_wea   = 32'hFFFF_FFFF;       // 256-bit full-word write
                    fcw_addra = pair*144 + s;
                    fcw_dina  = word;
                end
            end
            @(negedge clk); fcw_ena = 1'b0; fcw_wea = 32'd0; fcw_addra = 10'd0; fcw_dina = 256'd0;
            $display("[TB] @ cyc %0d : load_fc_weights done", cycle_cnt);
        end
    endtask

    // 입력 image (784 byte → bram_input bank (i&1), 196 word × 32-bit)
    task write_input;
        input integer img_idx;
        integer k;
        reg     bank;
        begin
            bank = img_idx[0];
            for (k = 0; k < 196; k = k + 1) begin
                @(negedge clk);
                in_ena = 1'b1; in_wea = 4'hF;
                in_addra = {bank, k[7:0]};
                in_dina  = {input_data[img_idx*784 + k*4 + 3],
                            input_data[img_idx*784 + k*4 + 2],
                            input_data[img_idx*784 + k*4 + 1],
                            input_data[img_idx*784 + k*4 + 0]};
            end
            @(negedge clk); in_ena = 1'b0; in_wea = 4'd0;
        end
    endtask

    task pulse_conv1_prior_wdone;
        begin
            @(negedge clk); conv1_prior_wdone = 1'b1;
            @(negedge clk); conv1_prior_wdone = 1'b0;
        end
    endtask

    //==========================================================================
    // Cross-process sync
    //==========================================================================
    reg weight_loaded_flag = 1'b0;
    reg all_done_flag      = 1'b0;

    //==========================================================================
    // PROCESS 1: Main — reset → weights(TODO) → conv2 start → wait → report
    //==========================================================================
    integer i_main;
    initial begin : main_process
        $display("\n==========================================");
        $display("  Conv1+Conv2+Maxpool+FC full-pipeline TB (N=%0d)", N_IMAGES);
        $display("  CHECK_LABEL=%0d  %s", CHECK_LABEL,
                 CHECK_LABEL ? "(class_idx vs label)" : "(flow-only: weight TODO)");
        $display("==========================================");

        $readmemh(`ALL_INPUT_HEX, input_data);

        // --- WEIGHT / LABEL (TODO) -------------------------------------------
        //   weight 생성 코드 완료 후: 아래 $readmemh 들이 실제 값을 채우고,
        //   CHECK_LABEL=1 로 두면 class_idx 검증이 활성화된다.
        $readmemh(`CONV1_WEIGHT_HEX, weight1_mem);
        $readmemh(`CONV2_WEIGHT_HEX, weight2_mem);
        $readmemh(`FCW_HEX,          fc_weight_simd);
        if (CHECK_LABEL)
            $readmemh(`FC_LOGIT_HEX, exp_logit);
        // ---------------------------------------------------------------------

        for (i_main = 0; i_main < N_IMAGES; i_main = i_main + 1) begin
            cycle_at_img_start[i_main] = 0;
            cycle_at_result[i_main]    = 0;
            captured_class[i_main]     = 0;
        end

        // Reset (active-high)
        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        $display("[TB] @ cyc %0d : reset released", cycle_cnt);

        // Weight load (conv1/conv2/fc) — TODO weight 면 0-weight 로 흐름만.
        init_weight1();
        init_weight2();
        load_fc_weights();
        weight_loaded_flag = 1'b1;
        $display("[TB] @ cyc %0d : all weights loaded", cycle_cnt);

        // Conv2 start pulse (LOAD_WEIGHTS 1회). conv1/maxpool/fc 는 prior_wdone 트리거.
        @(negedge clk); conv2_start = 1'b1;
        @(negedge clk); conv2_start = 1'b0;
        cycle_at_start_pulse = cycle_cnt;
        $display("[TB] @ cyc %0d : conv2_start pulsed", cycle_at_start_pulse);

        wait (all_done_flag == 1'b1);

        // Final report
        $display("\n=========================================");
        $display("  FINAL RESULT");
        $display("=========================================");
        $display("  results seen   : %0d / %0d", results_seen, N_IMAGES);
        if (CHECK_LABEL) begin
            $display("  images PASS    : %0d / %0d", images_pass, N_IMAGES);
            if (images_pass == N_IMAGES && results_seen == N_IMAGES)
                $display("  *** PASS *** (all %0d class_idx == label)", N_IMAGES);
            else
                $display("  *** FAIL ***");
        end else begin
            $display("  (label check off — weight TODO)");
            if (results_seen == N_IMAGES)
                $display("  *** FLOW PASS *** (FC produced %0d results, handshake/bank OK)", N_IMAGES);
            else
                $display("  *** FLOW FAIL *** (only %0d/%0d results)", results_seen, N_IMAGES);
        end
        $display("  total cycles   : %0d (start → last result)",
                 cycle_at_result[N_IMAGES-1] - cycle_at_start_pulse);
        $display("=========================================");

        $finish;
    end

    //==========================================================================
    // PROCESS 2: Conv1 dispatcher — per-image input write + prior_wdone pulse
    //   conv1.wdone → conv2.prior_wdone (direct wire) 로 chain 자동 진행.
    //==========================================================================
    integer i_conv1;
    initial begin : conv1_dispatcher
        wait (weight_loaded_flag == 1'b1);
        @(negedge clk);

        for (i_conv1 = 0; i_conv1 < N_IMAGES; i_conv1 = i_conv1 + 1) begin
            // Backpressure: input bram 2-bank ping-pong — conv1 read 1개 뒤까지만.
            wait ((i_conv1 - conv1_rdone_count) < 2);

            // bram_input bank (i&1) write → conv1 내부 input_bank_sel 과 자동 sync.
            write_input(i_conv1);

            cycle_at_img_start[i_conv1] = cycle_cnt;
            pulse_conv1_prior_wdone();
        end
    end

    //==========================================================================
    // PROCESS 3: FC result collector — @class_valid 마다 class_idx 캡처
    //   fc.rdone → maxpool.succ_rdone 은 direct wire 라 TB pulse 불필요.
    //==========================================================================
    // expected logit 10개에서 argmax (fc_argmax 와 동일 규칙: strict >, 첫 최댓값)
    function [3:0] exp_argmax;
        input integer base;
        integer j;
        reg signed [23:0] best;
        reg [3:0] bi;
        begin
            best = exp_logit[base];
            bi   = 4'd0;
            for (j = 1; j < 10; j = j + 1)
                if (exp_logit[base + j] > best) begin
                    best = exp_logit[base + j];
                    bi   = j[3:0];
                end
            exp_argmax = bi;
        end
    endfunction

    integer i_fc, j_fc, logit_mm;
    reg [3:0] exp_cls;
    initial begin : fc_result_process
        wait (rst == 1'b0);

        for (i_fc = 0; i_fc < N_IMAGES; i_fc = i_fc + 1) begin
            @(posedge class_valid);
            cycle_at_result[i_fc] = cycle_cnt;
            captured_class[i_fc]  = class_idx;
            results_seen          = results_seen + 1;

            if (CHECK_LABEL) begin
                // 1) logit bit-exact : fc 내부 logit_reg 10개 vs expected
                logit_mm = 0;
                for (j_fc = 0; j_fc < 10; j_fc = j_fc + 1)
                    if (fc.logit_reg[j_fc][23:0] !== exp_logit[i_fc*10 + j_fc])
                        logit_mm = logit_mm + 1;
                // 2) class_idx (= argmax of expected logit)
                exp_cls = exp_argmax(i_fc*10);

                if (logit_mm == 0 && class_idx == exp_cls) begin
                    images_pass = images_pass + 1;
                    $display("[TB] img %3d : PASS  class=%0d  @cyc %0d",
                             i_fc, class_idx, cycle_at_result[i_fc]);
                end else begin
                    $display("[TB] img %3d : FAIL  class=%0d exp=%0d  logit_mm=%0d/10  @cyc %0d",
                             i_fc, class_idx, exp_cls, logit_mm, cycle_at_result[i_fc]);
                end
            end else begin
                $display("[TB] img %3d : class=%0d  @cyc %0d  (label check off)",
                         i_fc, class_idx, cycle_at_result[i_fc]);
            end
        end

        all_done_flag = 1'b1;
    end

    //==========================================================================
    // Timeout
    //==========================================================================
    initial begin
        #20000000;
        $display("\n[TB] !!! TIMEOUT @ cyc %0d (results_seen=%0d/%0d) !!!",
                 cycle_cnt, results_seen, N_IMAGES);
        $finish;
    end

    //==========================================================================
    // VCD dump (디버그용 — 필요 없으면 주석)
    //==========================================================================
    initial begin
        $dumpfile("tb_conv1_conv2_maxpool_fc_multi.vcd");
        $dumpvars(0, tb_conv1_conv2_maxpool_fc_multi);
    end

endmodule
