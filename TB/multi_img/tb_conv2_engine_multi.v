`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_conv2_engine_multi.v
// Multi-image testbench for conv2_engine (100 image bit-exact check, real BMG IPs)
//
//   3 process 병렬:
//     main_process    : reset → init_weight → start → wait all_done → report
//     conv1_process   : ping-pong backpressure 로 image write + prior_wdone
//     maxpool_process : wdone 마다 c2pool BMG read + expected 비교 + succ_rdone
//
//   Weight init: init_weight() task 가 576 cycle 동안 Port A 의 c2w_ena/addra/dina 를
//                driving 하여 실제 PS 동작 emulation (옛 hierarchical $readmemh 방식 제거).
//
//   필요한 BMG IP (Vivado 프로젝트에 미리 생성):
//     bram_c1_to_c2     (Conv1→Conv2, L=2, depth 2048, 64-bit, byte-write 8-bit)
//     bram_c2_to_pool   (Conv2→Maxpool, L=1, depth 2048, 128-bit, byte-write disable)
//     conv2_weight_bram (PS→Conv2 weight, L=2, depth 1024, 32-bit, REGCEB pin 노출)
//   상세: docs/ip_spec/block_memory_generator.md
//////////////////////////////////////////////////////////////////////////////////

`define CONV1_ALL_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_c1c2.hex"
`define CONV2_ALL_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_c2pool.hex"
`define WEIGHT_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_weights_simd.hex"


//////////////////////////////////////////////////////////////////////////////////
// Main testbench
//////////////////////////////////////////////////////////////////////////////////
module tb_conv2_engine_multi;

    parameter N_IMAGES = 100;

    //==========================================================================
    // Clock / reset (180 MHz)
    //==========================================================================
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #2.78 clk = ~clk;

    //==========================================================================
    // DUT signals
    //==========================================================================
    reg          start          = 1'b0;

    // Conv2 weight Port A — TB 가 init_weight task 로 driving (실제 PS 동작 emulation)
    reg          c2w_ena        = 1'b0;
    reg  [9:0]   c2w_addra      = 10'd0;
    reg  [31:0]  c2w_dina       = 32'd0;

    // c1c2 Port B (Conv2 read)
    wire         c1c2_re;
    wire [10:0]  c1c2_addr_b;
    wire [63:0]  c1c2_dout_b;

    // c1c2 Port A (Virtual Conv1 write)
    reg          c1c2_ena_a     = 1'b0;
    reg  [7:0]   c1c2_wea_a     = 8'h00;
    reg  [10:0]  c1c2_addr_a    = 11'd0;
    reg  [63:0]  c1c2_din_a     = 64'd0;

    // c2pool Port A (Conv2 write)
    wire         c2pool_we_a;
    wire [10:0]  c2pool_addr_a;
    wire [127:0] c2pool_din_a;

    // c2pool Port B (Virtual Maxpool read)
    reg          c2pool_enb_b   = 1'b0;
    reg  [10:0]  c2pool_addr_b  = 11'd0;
    wire [127:0] c2pool_doutb_b;

    // Handshake
    reg          prior_wdone    = 1'b0;
    wire         rdone;
    reg          succ_rdone     = 1'b0;
    wire         wdone;

    //==========================================================================
    // BMG IP: bram_c1_to_c2 (Conv1→Conv2 ping-pong, L=2)
    //==========================================================================
    bram_c1_to_c2 c1c2_bram (
        .clka  (clk),
        .ena   (c1c2_ena_a),
        .wea   (c1c2_wea_a),
        .addra (c1c2_addr_a),
        .dina  (c1c2_din_a),

        .clkb  (clk),
        .enb   (c1c2_re),
        .addrb (c1c2_addr_b),
        .doutb (c1c2_dout_b)
    );

    //==========================================================================
    // BMG IP: bram_c2_to_pool (Conv2→Maxpool ping-pong, L=1)
    //==========================================================================
    bram_c2_to_pool c2pool_bram (
        .clka  (clk),
        .ena   (c2pool_we_a),
        .wea   (1'b1),
        .addra (c2pool_addr_a),
        .dina  (c2pool_din_a),

        .clkb  (clk),
        .enb   (c2pool_enb_b),
        .addrb (c2pool_addr_b),
        .doutb (c2pool_doutb_b)
    );

    //==========================================================================
    // DUT — 실제 conv2_weight_bram BMG IP 사용
    //   c2w_ena/addra/dina 가 TB reg 로 연결되어 init_weight task 가 구동.
    //==========================================================================
    conv2_engine dut (
        .clk         (clk),
        .rst         (rst),
        .start       (start),

        // Conv2 weight BMG Port A (TB 가 init_weight 로 driving)
        .c2w_ena     (c2w_ena),
        .c2w_addra   (c2w_addra),
        .c2w_dina    (c2w_dina),

        // c1c2 BMG Port B (DUT reads)
        .c1c2_re     (c1c2_re),
        .c1c2_addr   (c1c2_addr_b),
        .c1c2_dout   (c1c2_dout_b),

        // c2pool BMG Port A (DUT writes)
        .c2pool_we   (c2pool_we_a),
        .c2pool_addr (c2pool_addr_a),
        .c2pool_din  (c2pool_din_a),

        // Handshake
        .prior_wdone (prior_wdone),
        .rdone       (rdone),
        .succ_rdone  (succ_rdone),
        .wdone       (wdone)
    );

    //==========================================================================
    // Pre-loaded image data (1D flat for V2001 호환)
    //==========================================================================
    reg [63:0]  c1c2_data   [0:N_IMAGES*1024-1];  // 102,400 entries
    reg [127:0] c2pool_data [0:N_IMAGES*576-1];   //  57,600 entries

    //==========================================================================
    // TB-local weight memory (init_weight 가 사용)
    //==========================================================================
    reg [31:0]  weight_mem  [0:575];

    //==========================================================================
    // Statistics
    //==========================================================================
    integer per_image_mm [0:N_IMAGES-1];
    integer total_mismatches = 0;
    integer images_pass = 0;
    integer cycle_cnt = 0;
    integer cycle_at_img_start [0:N_IMAGES-1];
    integer cycle_at_wdone     [0:N_IMAGES-1];

    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Task: init_weight — Port A 로 576 cycle 동안 weight write
    //==========================================================================
    task init_weight;
        integer wi;
        begin
            $display("[TB] @ cycle %0d : init_weight start (576 cycle)", cycle_cnt);
            for (wi = 0; wi < 576; wi = wi + 1) begin
                @(negedge clk);
                c2w_ena   = 1'b1;
                c2w_addra = wi[9:0];
                c2w_dina  = weight_mem[wi];
            end
            @(negedge clk);
            c2w_ena   = 1'b0;
            c2w_addra = 10'd0;
            c2w_dina  = 32'd0;
            $display("[TB] @ cycle %0d : init_weight done", cycle_cnt);
        end
    endtask

    //==========================================================================
    // Task: Virtual Conv1 — write image to bram_c1_to_c2 Port A
    //==========================================================================
    task write_image;
        input integer img_idx;
        integer k, bank;
        begin
            bank = img_idx & 1;
            for (k = 0; k < 1024; k = k + 1) begin
                @(negedge clk);
                c1c2_ena_a   = 1'b1;
                c1c2_wea_a   = 8'hFF;
                c1c2_addr_a  = (bank << 10) | k;
                c1c2_din_a   = c1c2_data[img_idx * 1024 + k];
            end
            @(negedge clk);
            c1c2_ena_a = 1'b0;
            c1c2_wea_a = 8'h00;
        end
    endtask

    //==========================================================================
    // Task: 1-cycle pulse on prior_wdone
    //==========================================================================
    task pulse_prior_wdone;
        begin
            @(negedge clk);
            prior_wdone = 1'b1;
            @(negedge clk);
            prior_wdone = 1'b0;
        end
    endtask

    //==========================================================================
    // Task: Virtual Maxpool — read c2pool BMG Port B and compare
    //==========================================================================
    task compare_image;
        input  integer img_idx;
        integer i, bank, mm;
        reg [127:0] got, exp;
        begin
            bank = img_idx & 1;
            mm   = 0;

            for (i = 0; i < 577; i = i + 1) begin
                @(negedge clk);
                if (i < 576) begin
                    c2pool_enb_b  = 1'b1;
                    c2pool_addr_b = (bank << 10) | i[9:0];
                end else begin
                    c2pool_enb_b  = 1'b0;
                end

                if (i > 0) begin
                    got = c2pool_doutb_b;
                    exp = c2pool_data[img_idx * 576 + (i - 1)];
                    if (got !== exp) begin
                        mm = mm + 1;
                        if (mm <= 3)
                            $display("    MM img=%0d addr=%0d : got=%h exp=%h",
                                     img_idx, i - 1, got, exp);
                    end
                end
            end

            per_image_mm[img_idx] = mm;
            total_mismatches = total_mismatches + mm;
            if (mm == 0) images_pass = images_pass + 1;
        end
    endtask

    //==========================================================================
    // Task: 1-cycle pulse on succ_rdone
    //==========================================================================
    task pulse_succ_rdone;
        begin
            @(negedge clk);
            succ_rdone = 1'b1;
            @(negedge clk);
            succ_rdone = 1'b0;
        end
    endtask

    //==========================================================================
    // Inter-process counters (auto-update)
    //==========================================================================
    integer rdone_count = 0;
    integer wdone_count = 0;

    always @(posedge clk) begin
        if (rst) begin
            rdone_count <= 0;
            wdone_count <= 0;
        end else begin
            if (rdone) rdone_count <= rdone_count + 1;
            if (wdone) wdone_count <= wdone_count + 1;
        end
    end

    //==========================================================================
    // Sync between processes
    //   weight_loaded_flag: init_weight 완료 후 set. conv1_process 가 첫 write 전에 wait.
    //                       (conv1 BMG 와 weight BMG 는 독립이라 race 없지만, sim
    //                        시작 시 weight 가 정상 로딩 됐는지 명시적으로 보장)
    //==========================================================================
    reg     weight_loaded_flag  = 1'b0;
    reg     all_done_flag       = 1'b0;
    integer cycle_at_start_pulse = 0;

    //==========================================================================
    // PROCESS 1: Main — reset, init_weight, start, wait for completion, report
    //==========================================================================
    integer i_main;
    initial begin : main_process
        $display("\n==========================================");
        $display("  Conv2 multi-image testbench (N=%0d, real BMG IP)", N_IMAGES);
        $display("==========================================");
        $display("  CONV1_ALL_HEX = %s", `CONV1_ALL_HEX);
        $display("  CONV2_ALL_HEX = %s", `CONV2_ALL_HEX);
        $display("  WEIGHT_HEX    = %s", `WEIGHT_HEX);
        $display("");

        // Load data (no hierarchical access to BMG)
        $readmemh(`CONV1_ALL_HEX, c1c2_data);
        $readmemh(`CONV2_ALL_HEX, c2pool_data);
        $readmemh(`WEIGHT_HEX, weight_mem);
        $display("[TB] Loaded c1c2 (%0d) + c2pool (%0d) + weight (576) to TB mem",
                 N_IMAGES * 1024, N_IMAGES * 576);

        // Init statistics
        for (i_main = 0; i_main < N_IMAGES; i_main = i_main + 1) begin
            per_image_mm[i_main]      = 0;
            cycle_at_img_start[i_main] = 0;
            cycle_at_wdone[i_main]    = 0;
        end

        // Init driving signals (defensive)
        c2w_ena       = 1'b0;
        c2w_addra     = 10'd0;
        c2w_dina      = 32'd0;
        c1c2_ena_a    = 1'b0;
        c1c2_wea_a    = 8'h00;
        c2pool_enb_b  = 1'b0;
        c2pool_addr_b = 11'd0;
        prior_wdone   = 1'b0;
        succ_rdone    = 1'b0;
        start         = 1'b0;

        // Reset
        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        // init_weight (Port A 로 576 cycle 동안 weight write)
        init_weight();
        weight_loaded_flag = 1'b1;

        // Start pulse (LOAD_WEIGHTS 진입, 1회만)
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        cycle_at_start_pulse = cycle_cnt;
        $display("[TB] @ cycle %0d : start pulsed", cycle_at_start_pulse);

        // 다른 process 들이 알아서 끝낼 때까지 대기
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
    // PROCESS 2: Virtual Conv1 — image 별 write + prior_wdone, ping-pong backpressure
    //   weight_loaded_flag 대기 후 시작 (weight 로딩 완료 보장 — race 방지)
    //==========================================================================
    integer i_conv1;
    initial begin : conv1_process
        wait (weight_loaded_flag == 1'b1);
        @(negedge clk);

        for (i_conv1 = 0; i_conv1 < N_IMAGES; i_conv1 = i_conv1 + 1) begin
            wait ((i_conv1 - rdone_count) < 2);

            cycle_at_img_start[i_conv1] = cycle_cnt;
            write_image(i_conv1);
            pulse_prior_wdone();
        end
    end

    //==========================================================================
    // PROCESS 3: Virtual Maxpool — wdone 마다 compare + succ_rdone
    //==========================================================================
    integer i_max;
    initial begin : maxpool_process
        wait (rst == 1'b0);
        @(negedge clk);

        for (i_max = 0; i_max < N_IMAGES; i_max = i_max + 1) begin
            @(posedge wdone);
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
    //==========================================================================
    initial begin
        #20000000;
        $display("\n[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
        $finish;
    end

endmodule
