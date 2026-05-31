`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_conv1_conv2_maxpool_multi.v
// Conv1 + Conv2 + Maxpool integration multi-image TB (N_IMAGES bit-exact)
//
//   Pipeline:
//     PS → bram_input → Conv1 → bram_c1_to_c2 → Conv2 → bram_c2_to_pool → Maxpool
//                                                                            ↓
//                                                                     poolfc behavioral mem
//                                                                            ↓
//                                                                        TB compare
//
//   3 process 병렬:
//     main_process       : reset → init w1/w2 → conv2 start (1회) → wait all_done → report
//     conv1_dispatcher   : per-image input write + bank toggle + conv1_start + done →
//                          TB pulse conv2.prior_wdone (conv1 측 handshake bridge)
//     compare_process    : @posedge maxpool.wdone → compare poolfc bank (i&1) → pulse maxpool.succ_rdone
//
//   Handshake wiring (4-way, 직접 wire 가능한 부분):
//     conv1.wdone   → conv2.prior_wdone     (direct wire — c1c2 write 완료 알림)
//     conv2.rdone   → conv1.succ_rdone      (direct wire — c1c2 read 완료 알림)
//     conv2.wdone   → maxpool.prior_wdone   (direct wire — c2pool write 완료 알림)
//     maxpool.rdone → conv2.succ_rdone      (direct wire — c2pool read 완료 알림)
//     conv1.prior_wdone : TB pulses per image (input image ready 신호)
//     maxpool.wdone → TB wait → compare → maxpool.succ_rdone (가상 FC 역할)
//
//   ping-pong bank (모두 race-free):
//     conv1 input/output bank = conv1 내부 toggle FF (옵션 B 적용 후 RTL 측에서 관리)
//     conv2 자체 bank         = 자동 (fsm_input_bank_sel, fsm_output_bank_sel — 내부 counter)
//     c2pool read bank        = maxpool 내부 input_bank_sel toggle FF (RTL 표준화)
//     poolfc write bank       = maxpool 내부 output_bank_sel toggle FF (RTL 표준화)
//     bram_input write bank   = write_input task 내부 local `bank = img_idx[0]`
//                               (conv1 의 input_bank_sel reset 후 0 부터 1씩 toggle 과 sync)
//
//   필요한 BMG IP:
//     bram_input, conv1_weight_bram, bram_c1_to_c2, conv2_weight_bram, bram_c2_to_pool
//////////////////////////////////////////////////////////////////////////////////

`define ALL_INPUT_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_input.hex"
`define ALL_MAXPOOL_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_maxpool.hex"
`define CONV1_WEIGHT_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_weights_simd.hex"
`define CONV2_WEIGHT_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_weights_simd.hex"


module tb_conv1_conv2_maxpool_multi;

    parameter N_IMAGES = 40;

    //==========================================================================
    // Clock / reset (100 MHz, all-DUT active-high rst 통일)
    //==========================================================================
    reg clk = 1'b0;
    reg rst = 1'b1;       // active-high, initial asserted
    always #5 clk = ~clk;

    //==========================================================================
    // Top-level control
    //==========================================================================
    reg          conv1_start    = 1'b0;
    reg          conv2_start    = 1'b0;
    reg          maxpool_start  = 1'b0;          // legacy (사용 X — prior_wdone 으로 trigger)
    wire         conv1_done;
    wire         maxpool_done;                   // legacy

    // Direct-wire handshake signals (conv1→conv2→maxpool chain)
    wire         conv1_rdone, conv1_wdone;
    wire         conv2_rdone, conv2_wdone;
    wire         maxpool_rdone, maxpool_wdone;
    reg          conv1_prior_wdone   = 1'b0;     // TB pulses per image (Conv1 trigger)
    reg          maxpool_succ_rdone  = 1'b0;     // TB pulses (after compare, 가상 FC)

    // ping-pong bank for conv1 측 — 이제 conv1 내부 toggle FF (옵션 B) 로 관리.
    //   conv1_engine_2.v 가 rdone / wdone 에 자체 토글하므로 TB driving 불필요.
    //   bram_input write bank 는 write_input 내부에서 local `bank = img_idx[0]` 사용.

    //==========================================================================
    // BMG signal nets
    //==========================================================================
    // bram_input
    reg          in_ena   = 1'b0;
    reg          in_wea   = 1'b0;
    reg  [8:0]   in_addra = 9'd0;
    reg  [31:0]  in_dina  = 32'd0;
    wire [10:0]  in_addrb;
    wire         in_enb;
    wire signed [7:0] in_doutb;

    // conv1_weight_bram
    reg          w1_ena   = 1'b0;
    reg          w1_wea   = 1'b0;
    reg  [5:0]   w1_addra = 6'd0;
    reg  [31:0]  w1_dina  = 32'd0;
    wire [5:0]   w1_addrb;
    wire         w1_enb;
    wire [31:0]  w1_doutb;

    // bram_c1_to_c2 (conv1 write A, conv2 read B)
    wire         c1c2_we_a;
    wire [7:0]   c1c2_wea_a;
    wire [10:0]  c1c2_addr_a;
    wire [63:0]  c1c2_din_a;
    wire         c1c2_re_b;
    wire [10:0]  c1c2_addr_b;
    wire [63:0]  c1c2_doutb_b;

    // conv2_weight_bram
    reg          c2w_ena   = 1'b0;
    reg  [9:0]   c2w_addra = 10'd0;
    reg  [31:0]  c2w_dina  = 32'd0;

    // bram_c2_to_pool (conv2 write A, maxpool read B)
    wire         c2pool_we_a;
    wire [10:0]  c2pool_addr_a;
    wire [127:0] c2pool_din_a;
    wire [10:0]  maxpool_c2pool_rd_addr;       // 11-bit physical {input_bank_sel, local} from maxpool
    wire         c2pool_re_b;
    wire [127:0] c2pool_doutb_b;

    // poolfc 측 (behavioral mem)
    wire [8:0]   poolfc_wr_addr;
    wire         poolfc_wr_en;
    wire [127:0] poolfc_wr_data;

    //==========================================================================
    // Counters (handshake-tracked, used for ping-pong bank derivation + backpressure)
    //==========================================================================
    integer conv1_rdone_count    = 0;          // dispatcher backpressure (옵션 B 후 bank derive 용도 제거)
    integer conv1_wdone_count    = 0;          // 통계/debug 용 — 옵션 B 후 bank derive 미사용
    integer conv2_rdone_count    = 0;
    integer maxpool_rdone_count  = 0;          // 통계/debug (bank derive 는 maxpool 내부로 이동)
    integer maxpool_wdone_count  = 0;          // 통계/debug (bank derive 는 maxpool 내부로 이동)

    always @(posedge clk) begin
        if (rst) begin
            conv1_rdone_count    <= 0;
            conv1_wdone_count    <= 0;
            conv2_rdone_count    <= 0;
            maxpool_rdone_count  <= 0;
            maxpool_wdone_count  <= 0;
        end else begin
            if (conv1_rdone)   conv1_rdone_count   <= conv1_rdone_count   + 1;
            if (conv1_wdone)   conv1_wdone_count   <= conv1_wdone_count   + 1;
            if (conv2_rdone)   conv2_rdone_count   <= conv2_rdone_count   + 1;
            if (maxpool_rdone) maxpool_rdone_count <= maxpool_rdone_count + 1;
            if (maxpool_wdone) maxpool_wdone_count <= maxpool_wdone_count + 1;
        end
    end

    //==========================================================================
    // Bank derivation
    //==========================================================================
    //   모든 레이어가 RTL 내부에서 자기 bank 를 관리한다 (TB driving 없음):
    //     conv1   : 내부 input_bank_sel / bank_sel toggle FF
    //     conv2   : 내부 fsm_input_bank_sel / fsm_output_bank_sel
    //     maxpool : 내부 input_bank_sel (c2pool read) / output_bank_sel (poolfc write)
    //               — 표준화 후 maxpool 이 physical addr 을 직접 내보냄.
    //   따라서 c2pool / poolfc BMG 는 dumb 2-bank memory 로만 동작.

    //==========================================================================
    // BMG IP instances
    //==========================================================================
    bram_input in_bmg (
        .clka  (clk), .ena (in_ena), .wea (in_wea),
        .addra (in_addra), .dina (in_dina),
        .clkb  (clk), .enb (in_enb),
        .addrb (in_addrb), .doutb (in_doutb)
    );

    conv1_weight_bram w1_bmg (
        .clka  (clk), .ena (w1_ena), .wea (w1_wea),
        .addra (w1_addra), .dina (w1_dina),
        .clkb  (clk), .enb (w1_enb),
        .addrb (w1_addrb), .doutb (w1_doutb),
        .regceb(1'b1)
    );

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
        .addrb (maxpool_c2pool_rd_addr),     // maxpool 이 physical addr 직접 출력 (11-bit)
        .doutb (c2pool_doutb_b)
    );

    //==========================================================================
    // DUT 1: Conv1 (active-high rst, 4-way handshake)
    //   prior_wdone : TB pulse per image (image-by-image trigger)
    //   succ_rdone  : conv2.rdone direct wire (c1c2 read 완료 알림)
    //   rdone       : conv1.rdone (input read 완료) — TB monitors for backpressure
    //   wdone       : conv1.wdone → conv2.prior_wdone direct wire (NO TB bridge)
    //==========================================================================
    conv1_engine conv1 (
        .clk            (clk),
        .rst            (rst),                   // active-high
        .start          (conv1_start),           // legacy, 사용 X
        .done           (conv1_done),

        .prior_wdone    (conv1_prior_wdone),
        .succ_rdone     (conv2_rdone),           // direct wire
        .rdone          (conv1_rdone),
        .wdone          (conv1_wdone),

        // input_bank_sel / bank_sel 은 conv1 내부 toggle FF (옵션 B) — port 제거됨

        .in_bram_addr   (in_addrb),
        .in_bram_en     (in_enb),
        .in_bram_dout   (in_doutb),

        .w_bram_addr    (w1_addrb),
        .w_bram_en      (w1_enb),
        .w_bram_dout    (w1_doutb),

        .c1c2_we        (c1c2_we_a),
        .c1c2_wea       (c1c2_wea_a),
        .c1c2_addr      (c1c2_addr_a),
        .c1c2_din       (c1c2_din_a)
    );

    //==========================================================================
    // DUT 2: Conv2
    //   prior_wdone : conv1.wdone direct wire (NO TB bridge)
    //   succ_rdone  : maxpool.rdone direct wire
    //==========================================================================
    conv2_engine conv2 (
        .clk         (clk),
        .rst         (rst),
        .start       (conv2_start),

        .c2w_ena     (c2w_ena),
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
    //   prior_wdone : conv2.wdone (direct wire)
    //   succ_rdone  : TB pulse (after compare)
    //==========================================================================
    maxpool_engine maxpool (
        .clk             (clk),
        .rst             (rst),
        .start           (maxpool_start),         // legacy (사용 X)
        .done            (maxpool_done),

        .prior_wdone     (conv2_wdone),           // direct wire
        .succ_rdone      (maxpool_succ_rdone),
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
    // poolfc behavioral capture mem (FC 미구현 — 2 bank × 256 = 512 depth)
    //==========================================================================
    reg [127:0] poolfc_mem [0:511];

    always @(posedge clk) begin
        if (poolfc_wr_en)
            poolfc_mem[poolfc_wr_addr] <= poolfc_wr_data;
    end

    //==========================================================================
    // TB-local memory
    //==========================================================================
    reg [7:0]   input_data       [0:N_IMAGES*784-1];
    reg [127:0] maxpool_expected [0:N_IMAGES*144-1];
    reg [31:0]  weight1_mem      [0:35];
    reg [31:0]  weight2_mem      [0:575];

    //==========================================================================
    // Statistics
    //==========================================================================
    integer per_image_mm [0:N_IMAGES-1];
    integer total_mismatches = 0;
    integer images_pass = 0;
    integer cycle_cnt = 0;
    integer cycle_at_img_start [0:N_IMAGES-1];
    integer cycle_at_wdone     [0:N_IMAGES-1];
    integer cycle_at_start_pulse = 0;

    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Tasks
    //==========================================================================
    task init_weight1;
        integer wi;
        begin
            $display("[TB] @ cycle %0d : init_weight1 start (36)", cycle_cnt);
            for (wi = 0; wi < 36; wi = wi + 1) begin
                @(negedge clk);
                w1_ena = 1'b1; w1_wea = 1'b1;
                w1_addra = wi[5:0]; w1_dina = weight1_mem[wi];
            end
            @(negedge clk); w1_ena = 1'b0; w1_wea = 1'b0;
            $display("[TB] @ cycle %0d : init_weight1 done", cycle_cnt);
        end
    endtask

    task init_weight2;
        integer wi;
        begin
            $display("[TB] @ cycle %0d : init_weight2 start (576)", cycle_cnt);
            for (wi = 0; wi < 576; wi = wi + 1) begin
                @(negedge clk);
                c2w_ena = 1'b1;
                c2w_addra = wi[9:0]; c2w_dina = weight2_mem[wi];
            end
            @(negedge clk); c2w_ena = 1'b0;
            $display("[TB] @ cycle %0d : init_weight2 done", cycle_cnt);
        end
    endtask

    task write_input;
        input integer img_idx;
        integer k;
        reg     bank;
        begin
            bank = img_idx[0];
            for (k = 0; k < 196; k = k + 1) begin
                @(negedge clk);
                in_ena = 1'b1; in_wea = 1'b1;
                in_addra = {bank, k[7:0]};
                in_dina  = {input_data[img_idx*784 + k*4 + 3],
                            input_data[img_idx*784 + k*4 + 2],
                            input_data[img_idx*784 + k*4 + 1],
                            input_data[img_idx*784 + k*4 + 0]};
            end
            @(negedge clk); in_ena = 1'b0; in_wea = 1'b0;
        end
    endtask

    task pulse_conv1_prior_wdone;
        begin
            @(negedge clk); conv1_prior_wdone = 1'b1;
            @(negedge clk); conv1_prior_wdone = 1'b0;
        end
    endtask

    task pulse_maxpool_succ_rdone;
        begin
            @(negedge clk); maxpool_succ_rdone = 1'b1;
            @(negedge clk); maxpool_succ_rdone = 1'b0;
        end
    endtask

    // Read poolfc bank (img&1), compare 144 entry × 128-bit
    //   Bug fix: capture first/last mismatch pixel into separate vars (pixel quirk 회피)
    task compare_image;
        input integer img_idx;
        integer pixel, mm;
        integer first_mm_pixel, last_mm_pixel;
        reg     bank;
        reg [127:0] got, exp;
        reg [127:0] first_mm_got, first_mm_exp;
        begin
            bank = img_idx[0];
            mm = 0;
            first_mm_pixel = -1;
            last_mm_pixel  = -1;
            first_mm_got   = 128'd0;
            first_mm_exp   = 128'd0;

            for (pixel = 0; pixel < 144; pixel = pixel + 1) begin
                got = poolfc_mem[{bank, pixel[7:0]}];
                exp = maxpool_expected[img_idx * 144 + pixel];
                if (got !== exp) begin
                    mm = mm + 1;
                    if (mm == 1) begin
                        first_mm_pixel = pixel;
                        first_mm_got   = got;
                        first_mm_exp   = exp;
                    end
                    last_mm_pixel = pixel;
                end
            end

            if (mm > 0)
                $display("    MM-summary img=%0d : first_pixel=%0d (got=%h, exp=%h) last_pixel=%0d total=%0d/144",
                         img_idx, first_mm_pixel, first_mm_got, first_mm_exp, last_mm_pixel, mm);

            per_image_mm[img_idx] = mm;
            total_mismatches      = total_mismatches + mm;
            if (mm == 0) images_pass = images_pass + 1;
        end
    endtask

    //==========================================================================
    // Cross-process sync
    //==========================================================================
    reg weight_loaded_flag = 1'b0;
    reg all_done_flag      = 1'b0;

    //==========================================================================
    // PROCESS 1: Main
    //==========================================================================
    integer i_main;
    initial begin : main_process
        $display("\n==========================================");
        $display("  Conv1 + Conv2 + Maxpool multi-image TB (N=%0d)", N_IMAGES);
        $display("==========================================");
        $display("  ALL_INPUT_HEX     = %s", `ALL_INPUT_HEX);
        $display("  ALL_MAXPOOL_HEX   = %s", `ALL_MAXPOOL_HEX);
        $display("  CONV1_WEIGHT_HEX  = %s", `CONV1_WEIGHT_HEX);
        $display("  CONV2_WEIGHT_HEX  = %s", `CONV2_WEIGHT_HEX);
        $display("");

        $readmemh(`ALL_INPUT_HEX,    input_data);
        $readmemh(`ALL_MAXPOOL_HEX,  maxpool_expected);
        $readmemh(`CONV1_WEIGHT_HEX, weight1_mem);
        $readmemh(`CONV2_WEIGHT_HEX, weight2_mem);
        $display("[TB] Loaded input (%0d), maxpool exp (%0d), w1 (36), w2 (576)",
                 N_IMAGES * 784, N_IMAGES * 144);

        for (i_main = 0; i_main < N_IMAGES; i_main = i_main + 1) begin
            per_image_mm[i_main]       = 0;
            cycle_at_img_start[i_main] = 0;
            cycle_at_wdone[i_main]     = 0;
        end

        // Reset (active-high, initial asserted)
        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        // Init weights
        init_weight1();
        init_weight2();
        weight_loaded_flag = 1'b1;
        $display("[TB] @ cycle %0d : both weights loaded", cycle_cnt);

        // Conv2 start pulse (LOAD_WEIGHTS 1회)
        @(negedge clk); conv2_start = 1'b1;
        @(negedge clk); conv2_start = 1'b0;
        cycle_at_start_pulse = cycle_cnt;
        $display("[TB] @ cycle %0d : conv2_start pulsed", cycle_at_start_pulse);

        wait (all_done_flag == 1'b1);

        // Final report
        $display("\n=========================================");
        $display("  FINAL RESULT");
        $display("=========================================");
        $display("  images PASS    : %0d / %0d", images_pass, N_IMAGES);
        $display("  total compare  : %0d", N_IMAGES * 144);
        $display("  total mismatch : %0d", total_mismatches);
        $display("  total cycles   : %0d (start → last maxpool.wdone)",
                 cycle_at_wdone[N_IMAGES-1] - cycle_at_start_pulse);
        $display("  avg cycle/img  : %0d",
                 (cycle_at_wdone[N_IMAGES-1] - cycle_at_start_pulse) / N_IMAGES);
        if (total_mismatches == 0 && images_pass == N_IMAGES)
            $display("  *** PASS *** (all %0d images bit-exact)", N_IMAGES);
        else
            $display("  *** FAIL ***");
        $display("=========================================");

        $finish;
    end

    //==========================================================================
    // PROCESS 2: Conv1 dispatcher
    //   per-image input write + bank toggle + pulse conv1.prior_wdone
    //   conv1.wdone → conv2.prior_wdone (direct wire, NO TB bridge)
    //   conv2.rdone → conv1.succ_rdone (direct wire)
    //==========================================================================
    integer i_conv1;
    initial begin : conv1_dispatcher
        wait (weight_loaded_flag == 1'b1);
        @(negedge clk);

        for (i_conv1 = 0; i_conv1 < N_IMAGES; i_conv1 = i_conv1 + 1) begin
            // Backpressure: input bram ping-pong 2-bank — conv1 의 image i-2 read 완료 후 i 시작
            wait ((i_conv1 - conv1_rdone_count) < 2);

            // Write input to bram_input bank (bank = i_conv1[0])
            //   conv1 내부 toggle FF (옵션 B) 가 reset 후 0 부터 rdone 마다 토글하므로,
            //   TB 가 i_conv1[0] 으로 write 하면 conv1 의 read bank 와 자동 sync.
            write_input(i_conv1);

            // Pulse conv1 prior_wdone — image trigger (자동 handshake chain)
            cycle_at_img_start[i_conv1] = cycle_cnt;
            pulse_conv1_prior_wdone();
        end
    end

    //==========================================================================
    // PROCESS 3: Compare (가상 FC) — @maxpool.wdone → compare → pulse maxpool.succ_rdone
    //==========================================================================
    integer i_cmp;
    initial begin : compare_process
        wait (rst == 1'b0);
        @(negedge clk);

        for (i_cmp = 0; i_cmp < N_IMAGES; i_cmp = i_cmp + 1) begin
            @(posedge maxpool_wdone);
            cycle_at_wdone[i_cmp] = cycle_cnt;

            repeat (3) @(posedge clk);          // poolfc mem settle

            compare_image(i_cmp);
            pulse_maxpool_succ_rdone();

            if (per_image_mm[i_cmp] == 0)
                $display("[TB] img %3d : PASS  @ wdone cycle %0d", i_cmp, cycle_at_wdone[i_cmp]);
            else
                $display("[TB] img %3d : FAIL  @ wdone cycle %0d  (%0d mm)",
                         i_cmp, cycle_at_wdone[i_cmp], per_image_mm[i_cmp]);
        end

        all_done_flag = 1'b1;
    end

    //==========================================================================
    // Timeout
    //==========================================================================
    initial begin
        #10000000;
        $display("\n[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
        $finish;
    end

endmodule
