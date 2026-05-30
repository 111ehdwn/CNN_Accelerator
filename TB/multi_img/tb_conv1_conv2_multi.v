`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_conv1_conv2_multi.v
// Conv1 + Conv2 multi-image integration TB (N_IMAGES image bit-exact check)
//
//   3 process 병렬 (tb_conv2_engine_multi.v 패턴 차용):
//     main_process    : reset → init_weight1 → init_weight2 → conv2_start (1회) → wait all_done → report
//     conv1_process   : per-image input write (bram_input bank (i&1)) →
//                       conv1_start → wait conv1_done → pulse conv2.prior_wdone
//                       (bank 은 conv1 내부 toggle FF 가 관리)
//     compare_process : @posedge conv2_wdone 마다 c2pool BMG bank (i&1) read + expected 비교 + succ_rdone
//
//   5 BMG IP (Vivado 프로젝트에 미리 생성):
//     bram_input         (Port A 32b × 512, Port B 8b × 2048, asymmetric, L=1)
//     conv1_weight_bram  (32b × 64,  L=2, REGCEB 노출)
//     bram_c1_to_c2      (64b × 2048, L=2, byte-write 8-bit)
//     conv2_weight_bram  (32b × 1024, L=2, REGCEB 노출)
//     bram_c2_to_pool    (128b × 2048, L=1)
//   상세 spec: docs/ip_spec/block_memory_generator.md
//
//   Sequential per-image:
//     image i 의 input write → conv1 처리 → prior_wdone → conv2 처리 → compare → succ_rdone
//     bank_sel = i & 1 (ping-pong, 2-bank 활용은 하지만 동시 처리 X)
//////////////////////////////////////////////////////////////////////////////////

`define ALL_INPUT_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_input.hex"
`define ALL_C2POOL_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_c2pool.hex"
`define WEIGHT1_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_weights_simd.hex"
`define WEIGHT2_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_weights_simd.hex"


module tb_conv1_conv2_multi;

    parameter N_IMAGES = 40;

    //==========================================================================
    // Clock / reset (100 MHz)
    //   Conv1/Conv2 모두 active-high rst (= ~rst_n) 사용 (시스템 통일).
    //==========================================================================
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    wire rst = ~rst_n;
    always #5 clk = ~clk;

    //==========================================================================
    // Top-level control
    //==========================================================================
    reg          conv1_start = 1'b0;
    reg          conv2_start = 1'b0;
    wire         conv1_done;
    wire         conv2_wdone;
    wire         conv2_rdone;

    // ping-pong bank 은 conv1 내부 toggle FF 가 관리 (rdone/wdone count[0]).
    // TB 의 input write bank (i&1) 과 자동 sync (sequential 처리).

    //==========================================================================
    // BMG signals
    //==========================================================================
    // bram_input — TB writes Port A, conv1 reads Port B
    reg          in_ena   = 1'b0;
    reg          in_wea   = 1'b0;
    reg  [8:0]   in_addra = 9'd0;
    reg  [31:0]  in_dina  = 32'd0;
    wire [10:0]  in_addrb;
    wire         in_enb;
    wire signed [7:0] in_doutb;

    // conv1_weight_bram — TB writes Port A
    reg          w1_ena   = 1'b0;
    reg          w1_wea   = 1'b0;
    reg  [5:0]   w1_addra = 6'd0;
    reg  [31:0]  w1_dina  = 32'd0;
    wire [5:0]   w1_addrb;
    wire         w1_enb;
    wire [31:0]  w1_doutb;

    // bram_c1_to_c2 — conv1 writes Port A, conv2 reads Port B
    wire         c1c2_we_a;
    wire [7:0]   c1c2_wea_a;
    wire [10:0]  c1c2_addr_a;
    wire [63:0]  c1c2_din_a;
    wire         c1c2_re_b;
    wire [10:0]  c1c2_addr_b;
    wire [63:0]  c1c2_doutb_b;

    // conv2_weight_bram — TB writes Port A
    reg          c2w_ena   = 1'b0;
    reg  [9:0]   c2w_addra = 10'd0;
    reg  [31:0]  c2w_dina  = 32'd0;

    // bram_c2_to_pool — conv2 writes Port A, TB reads Port B
    wire         c2pool_we_a;
    wire [10:0]  c2pool_addr_a;
    wire [127:0] c2pool_din_a;
    reg          c2pool_enb_b   = 1'b0;
    reg  [10:0]  c2pool_addr_b  = 11'd0;
    wire [127:0] c2pool_doutb_b;

    // Conv2 handshake
    reg          conv2_prior_wdone = 1'b0;
    reg          conv2_succ_rdone  = 1'b0;

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
        .clkb  (clk), .enb (c2pool_enb_b),
        .addrb (c2pool_addr_b), .doutb (c2pool_doutb_b)
    );

    //==========================================================================
    // DUT 1: Conv1 engine
    //==========================================================================
    conv1_engine conv1 (
        .clk          (clk),
        .rst          (rst),
        .start        (conv1_start),
        .done         (conv1_done),

        .prior_wdone  (1'b0),         // conv1 은 start 로 트리거 (legacy backup)
        .succ_rdone   (conv2_rdone),  // conv2 의 c1c2 read 완료 → output bank 여유 (after_diff 관리)
        .rdone        (),             // 미사용
        .wdone        (),             // 미사용 (done 으로 완료 감지 → conv2 prior_wdone 수동 pulse)

        .in_bram_addr (in_addrb),
        .in_bram_en   (in_enb),
        .in_bram_dout (in_doutb),

        .w_bram_addr  (w1_addrb),
        .w_bram_en    (w1_enb),
        .w_bram_dout  (w1_doutb),

        .c1c2_we      (c1c2_we_a),
        .c1c2_wea     (c1c2_wea_a),
        .c1c2_addr    (c1c2_addr_a),
        .c1c2_din     (c1c2_din_a)
    );

    //==========================================================================
    // DUT 2: Conv2 engine
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

        .prior_wdone (conv2_prior_wdone),
        .rdone       (conv2_rdone),
        .succ_rdone  (conv2_succ_rdone),
        .wdone       (conv2_wdone)
    );

    //==========================================================================
    // TB-local memory
    //==========================================================================
    reg [7:0]   input_data      [0:N_IMAGES*784-1];     // raw 28×28 byte
    reg [127:0] c2pool_expected [0:N_IMAGES*576-1];
    reg [31:0]  weight1_mem     [0:35];
    reg [31:0]  weight2_mem     [0:575];

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

    always @(posedge clk) if (rst_n) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Tasks: init weights / input write / pulses / compare
    //==========================================================================
    task init_weight1;
        integer wi;
        begin
            $display("[TB] @ cycle %0d : init_weight1 start (36 cycle)", cycle_cnt);
            for (wi = 0; wi < 36; wi = wi + 1) begin
                @(negedge clk);
                w1_ena   = 1'b1; w1_wea = 1'b1;
                w1_addra = wi[5:0]; w1_dina = weight1_mem[wi];
            end
            @(negedge clk); w1_ena = 1'b0; w1_wea = 1'b0;
            $display("[TB] @ cycle %0d : init_weight1 done", cycle_cnt);
        end
    endtask

    task init_weight2;
        integer wi;
        begin
            $display("[TB] @ cycle %0d : init_weight2 start (576 cycle)", cycle_cnt);
            for (wi = 0; wi < 576; wi = wi + 1) begin
                @(negedge clk);
                c2w_ena   = 1'b1;
                c2w_addra = wi[9:0]; c2w_dina = weight2_mem[wi];
            end
            @(negedge clk); c2w_ena = 1'b0;
            $display("[TB] @ cycle %0d : init_weight2 done", cycle_cnt);
        end
    endtask

    // Write image img_idx 784 byte → bram_input bank (img_idx & 1) Port A (32-bit × 196 word)
    task write_input;
        input integer img_idx;
        integer k;
        reg     bank;
        begin
            bank = img_idx[0];
            for (k = 0; k < 196; k = k + 1) begin
                @(negedge clk);
                in_ena   = 1'b1; in_wea = 1'b1;
                in_addra = {bank, k[7:0]};
                in_dina  = {input_data[img_idx*784 + k*4 + 3],
                            input_data[img_idx*784 + k*4 + 2],
                            input_data[img_idx*784 + k*4 + 1],
                            input_data[img_idx*784 + k*4 + 0]};
            end
            @(negedge clk); in_ena = 1'b0; in_wea = 1'b0;
        end
    endtask

    task pulse_conv1_start;
        begin
            @(negedge clk); conv1_start = 1'b1;
            @(negedge clk); conv1_start = 1'b0;
        end
    endtask

    task pulse_prior_wdone;
        begin
            @(negedge clk); conv2_prior_wdone = 1'b1;
            @(negedge clk); conv2_prior_wdone = 1'b0;
        end
    endtask

    task pulse_succ_rdone;
        begin
            @(negedge clk); conv2_succ_rdone = 1'b1;
            @(negedge clk); conv2_succ_rdone = 1'b0;
        end
    endtask

    // Read c2pool BMG bank (img_idx & 1), compare 576 entry. L=1 pipelined read.
    task compare_image;
        input  integer img_idx;
        integer i, mm;
        reg     bank;
        reg [127:0] got, exp;
        begin
            bank = img_idx[0];
            mm   = 0;

            for (i = 0; i < 577; i = i + 1) begin
                @(negedge clk);
                if (i < 576) begin
                    c2pool_enb_b  = 1'b1;
                    c2pool_addr_b = {bank, i[9:0]};
                end else begin
                    c2pool_enb_b  = 1'b0;
                end

                if (i > 0) begin
                    got = c2pool_doutb_b;
                    exp = c2pool_expected[img_idx * 576 + (i - 1)];
                    if (got !== exp) begin
                        mm = mm + 1;
                        if (mm <= 3)
                            $display("    MM img=%0d addr=%0d : got=%h exp=%h",
                                     img_idx, i - 1, got, exp);
                    end
                end
            end
            @(negedge clk); c2pool_enb_b = 1'b0;

            per_image_mm[img_idx] = mm;
            total_mismatches      = total_mismatches + mm;
            if (mm == 0) images_pass = images_pass + 1;
        end
    endtask

    //==========================================================================
    // Cross-process sync
    //==========================================================================
    reg     weight_loaded_flag = 1'b0;
    reg     all_done_flag      = 1'b0;
    integer rdone_count        = 0;

    always @(posedge clk) begin
        if (!rst_n)             rdone_count <= 0;
        else if (conv2_rdone)   rdone_count <= rdone_count + 1;
    end

    //==========================================================================
    // PROCESS 1: Main — reset + init weights + conv2 start + final report
    //==========================================================================
    integer i_main;
    initial begin : main_process
        $display("\n==========================================");
        $display("  Conv1 + Conv2 multi-image integration TB (N=%0d)", N_IMAGES);
        $display("==========================================");
        $display("  ALL_INPUT_HEX  = %s", `ALL_INPUT_HEX);
        $display("  ALL_C2POOL_HEX = %s", `ALL_C2POOL_HEX);
        $display("  WEIGHT1_HEX    = %s", `WEIGHT1_HEX);
        $display("  WEIGHT2_HEX    = %s", `WEIGHT2_HEX);
        $display("");

        // Load all data
        $readmemh(`ALL_INPUT_HEX,  input_data);
        $readmemh(`ALL_C2POOL_HEX, c2pool_expected);
        $readmemh(`WEIGHT1_HEX,    weight1_mem);
        $readmemh(`WEIGHT2_HEX,    weight2_mem);
        $display("[TB] Loaded input (%0d), c2pool exp (%0d), w1 (36), w2 (576)",
                 N_IMAGES * 784, N_IMAGES * 576);

        // Init statistics
        for (i_main = 0; i_main < N_IMAGES; i_main = i_main + 1) begin
            per_image_mm[i_main]      = 0;
            cycle_at_img_start[i_main] = 0;
            cycle_at_wdone[i_main]    = 0;
        end

        // Reset
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        // Init both weight BMGs (sequential)
        init_weight1();
        init_weight2();
        weight_loaded_flag = 1'b1;
        $display("[TB] @ cycle %0d : both weights loaded", cycle_cnt);

        // Pulse conv2 start (LOAD_WEIGHTS 진입, 1회만 — 이후 image-by-image prior_wdone 로 진행)
        @(negedge clk); conv2_start = 1'b1;
        @(negedge clk); conv2_start = 1'b0;
        cycle_at_start_pulse = cycle_cnt;
        $display("[TB] @ cycle %0d : conv2_start pulsed", cycle_at_start_pulse);

        // Wait for compare_process completion
        wait (all_done_flag == 1'b1);

        // Final report
        $display("\n=========================================");
        $display("  FINAL RESULT");
        $display("=========================================");
        $display("  images PASS    : %0d / %0d", images_pass, N_IMAGES);
        $display("  total compare  : %0d", N_IMAGES * 576);
        $display("  total mismatch : %0d", total_mismatches);
        $display("  total cycles   : %0d (start → last wdone)",
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
    // PROCESS 2: Conv1 dispatcher — per-image input write + conv1_start + prior_wdone
    //   Sequential: 한 image 처리 끝나야 다음 시작. ping-pong overlap 미사용 (단순성).
    //==========================================================================
    integer i_conv1;
    initial begin : conv1_process
        wait (weight_loaded_flag == 1'b1);
        @(negedge clk);

        for (i_conv1 = 0; i_conv1 < N_IMAGES; i_conv1 = i_conv1 + 1) begin
            // Backpressure: conv2 가 너무 처지면 대기 (현재 sequential 이라 사실상 무필요)
            wait ((i_conv1 - rdone_count) < 2);

            // bank 은 conv1 내부 toggle FF 가 관리 (rdone/wdone count[0]).
            // TB 는 input 을 bank (i&1) 에 write → conv1 read bank 와 자동 sync.
            write_input(i_conv1);

            // Pulse conv1_start
            cycle_at_img_start[i_conv1] = cycle_cnt;
            pulse_conv1_start();

            // Wait Conv1 done
            @(posedge conv1_done);

            // Settle for BMG (Conv1 last write → mem)
            repeat (3) @(posedge clk);

            // Notify Conv2: Conv1 data ready
            pulse_prior_wdone();
        end
    end

    //==========================================================================
    // PROCESS 3: Compare — @wdone 마다 c2pool BMG bank (i&1) read + expected 비교 + succ_rdone
    //==========================================================================
    integer i_max;
    initial begin : compare_process
        wait (rst_n == 1'b1);
        @(negedge clk);

        for (i_max = 0; i_max < N_IMAGES; i_max = i_max + 1) begin
            @(posedge conv2_wdone);
            cycle_at_wdone[i_max] = cycle_cnt;

            repeat (3) @(posedge clk);

            compare_image(i_max);
            pulse_succ_rdone();

            if (per_image_mm[i_max] == 0)
                $display("[TB] img %3d : PASS  @ wdone cycle %0d", i_max, cycle_at_wdone[i_max]);
            else
                $display("[TB] img %3d : FAIL  @ wdone cycle %0d  (%0d mm)",
                         i_max, cycle_at_wdone[i_max], per_image_mm[i_max]);
        end

        all_done_flag = 1'b1;
    end

    //==========================================================================
    // Timeout
    //   sequential: per image ≈ (196 input + 1617 conv1 + 1801 conv2 + 577 compare) ≈ 4191 cycle
    //   40 images × 4191 ≈ 167,640 cycle + init ≈ 170,000 cycle. 안전 위해 1,000,000 cycle.
    //==========================================================================
    initial begin
        #10000000;
        $display("\n[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
        $finish;
    end

endmodule
