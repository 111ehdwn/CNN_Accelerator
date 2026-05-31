`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_maxpool_engine_multi.v
// Multi-image maxpool TB (N_IMAGES image bit-exact check, real bram_c2_to_pool BMG IP)
//
//   3 process 병렬 (tb_conv2_engine_multi.v 패턴 차용):
//     main_process       : reset → wait all_done → final report
//     c2pool_writer_proc : per-image write c2pool bank (i&1) → pulse prior_wdone (가상 conv2)
//     compare_process    : @posedge wdone → compare poolfc bank (i&1) vs expected → pulse succ_rdone
//
//   필요한 BMG IP:
//     bram_c2_to_pool : 128-bit × 2048, L=1, byte-write disable
//
//   ping-pong logic:
//     c2pool BMG Port A 쓰기 bank = i & 1 (가상 conv2 writer)
//     c2pool BMG Port B 읽기 bank = maxpool 내부 input_bank_sel (rdone toggle, RTL 표준화)
//     poolfc write bank          = maxpool 내부 output_bank_sel (wdone toggle, RTL 표준화)
//
//   Backpressure: c2pool_writer 가 (i - rdone_count) < 2 일 때 만 진행 → 2-bank 충돌 방지
//
//   Reference 형식:
//     all_maxpool.hex (100 × 144 lines × 128-bit packed, OC0=LSB)
//     all_c2pool.hex  (100 × 576 lines × 128-bit packed)
//////////////////////////////////////////////////////////////////////////////////

`define ALL_C2POOL_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_c2pool.hex"
`define ALL_MAXPOOL_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_maxpool.hex"


module tb_maxpool_engine_multi;

    parameter N_IMAGES = 40;

    //==========================================================================
    // Clock / reset (100 MHz, active-high rst)
    //==========================================================================
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    //==========================================================================
    // DUT signals
    //==========================================================================
    reg          start         = 1'b0;
    wire         done;

    reg          prior_wdone   = 1'b0;
    reg          succ_rdone    = 1'b0;
    wire         rdone;
    wire         wdone;

    // c2pool BMG (Port A: TB writer, Port B: maxpool reader)
    reg          c2pool_ena_a  = 1'b0;
    reg          c2pool_wea_a  = 1'b0;
    reg  [10:0]  c2pool_addra  = 11'd0;
    reg  [127:0] c2pool_dina   = 128'd0;

    wire [10:0]  c2pool_rd_addr;            // physical addr {input_bank_sel, local} (11-bit)
    wire         c2pool_rd_en;
    wire signed [127:0] c2pool_rd_data;

    // poolfc 측 (behavioral capture mem)
    wire [8:0]   poolfc_wr_addr;
    wire         poolfc_wr_en;
    wire [127:0] poolfc_wr_data;

    //==========================================================================
    // Counters (rdone / wdone)
    //==========================================================================
    integer rdone_count;
    integer wdone_count;

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
    // ping-pong bank: maxpool 내부에서 관리 (RTL 표준화 후 TB driving 불필요).
    //   c2pool read  bank = maxpool input_bank_sel  (rdone toggle = rdone_count[0])
    //   poolfc write bank = maxpool output_bank_sel (wdone toggle = wdone_count[0])
    //   rdone_count 는 backpressure 에 계속 사용, wdone_count 는 통계용.
    //==========================================================================

    //==========================================================================
    // BMG IP: bram_c2_to_pool (Port B addrb = {read_bank, local_10b})
    //==========================================================================
    bram_c2_to_pool c2pool_bmg (
        .clka  (clk),
        .ena   (c2pool_ena_a),
        .wea   (c2pool_wea_a),
        .addra (c2pool_addra),
        .dina  (c2pool_dina),

        .clkb  (clk),
        .enb   (c2pool_rd_en),
        .addrb (c2pool_rd_addr),                 // maxpool 이 physical addr 직접 출력 (11-bit)
        .doutb (c2pool_rd_data)
    );

    //==========================================================================
    // DUT
    //==========================================================================
    maxpool_engine dut (
        .clk             (clk),
        .rst             (rst),
        .start           (start),
        .done            (done),

        .prior_wdone     (prior_wdone),
        .succ_rdone      (succ_rdone),
        .rdone           (rdone),
        .wdone           (wdone),

        .c2pool_rd_addr  (c2pool_rd_addr),
        .c2pool_rd_en    (c2pool_rd_en),
        .c2pool_rd_data  (c2pool_rd_data),

        .poolfc_wr_addr  (poolfc_wr_addr),
        .poolfc_wr_en    (poolfc_wr_en),
        .poolfc_wr_data  (poolfc_wr_data)
    );

    //==========================================================================
    // poolfc behavioral capture mem (2 bank × 256 = 512 entry; depth 512)
    //==========================================================================
    reg [127:0] poolfc_mem [0:511];

    always @(posedge clk) begin
        if (poolfc_wr_en)
            poolfc_mem[poolfc_wr_addr] <= poolfc_wr_data;
    end

    //==========================================================================
    // TB-local data
    //==========================================================================
    reg [127:0] c2pool_data    [0:N_IMAGES*576-1];
    reg [127:0] maxpool_expect [0:N_IMAGES*144-1];

    //==========================================================================
    // Statistics
    //==========================================================================
    integer per_image_mm [0:N_IMAGES-1];
    integer total_mismatches = 0;
    integer images_pass = 0;
    integer cycle_cnt = 0;
    integer cycle_at_img_start [0:N_IMAGES-1];
    integer cycle_at_wdone     [0:N_IMAGES-1];
    integer cycle_at_first_prior;

    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Task: write_image — 576 entry × 128-bit → c2pool BMG Port A bank (img&1)
    //==========================================================================
    task write_image;
        input integer img_idx;
        integer k;
        reg     bank;
        begin
            bank = img_idx[0];
            for (k = 0; k < 576; k = k + 1) begin
                @(negedge clk);
                c2pool_ena_a = 1'b1;
                c2pool_wea_a = 1'b1;
                c2pool_addra = {bank, k[9:0]};
                c2pool_dina  = c2pool_data[img_idx * 576 + k];
            end
            @(negedge clk);
            c2pool_ena_a = 1'b0;
            c2pool_wea_a = 1'b0;
        end
    endtask

    //==========================================================================
    // Task pulses
    //==========================================================================
    task pulse_prior_wdone;
        begin
            @(negedge clk); prior_wdone = 1'b1;
            @(negedge clk); prior_wdone = 1'b0;
        end
    endtask

    task pulse_succ_rdone;
        begin
            @(negedge clk); succ_rdone = 1'b1;
            @(negedge clk); succ_rdone = 1'b0;
        end
    endtask

    //==========================================================================
    // Task: compare_image — read poolfc bank (img&1) 144 entry × 128-bit, compare
    //==========================================================================
    task compare_image;
        input integer img_idx;
        integer pixel, mm;
        reg     bank;
        reg [127:0] got, exp;
        begin
            bank = img_idx[0];
            mm   = 0;

            // poolfc_wr_addr = {output_bank_sel, out_addr[7:0]} → bank*256 + pixel
            for (pixel = 0; pixel < 144; pixel = pixel + 1) begin
                got = poolfc_mem[{bank, pixel[7:0]}];
                exp = maxpool_expect[img_idx * 144 + pixel];
                if (got !== exp) begin
                    mm = mm + 1;
                    if (mm <= 3)
                        $display("    MM img=%0d pixel=%0d : got=%h exp=%h",
                                 img_idx, pixel, got, exp);
                end
            end

            per_image_mm[img_idx] = mm;
            total_mismatches      = total_mismatches + mm;
            if (mm == 0) images_pass = images_pass + 1;
        end
    endtask

    //==========================================================================
    // Cross-process sync
    //==========================================================================
    reg     all_done_flag = 1'b0;

    //==========================================================================
    // PROCESS 1: Main — reset + load + wait + report
    //==========================================================================
    integer i_main;
    initial begin : main_process
        $display("\n==========================================");
        $display("  Maxpool multi-image TB (N=%0d, real BMG IP)", N_IMAGES);
        $display("==========================================");
        $display("  ALL_C2POOL_HEX  = %s", `ALL_C2POOL_HEX);
        $display("  ALL_MAXPOOL_HEX = %s", `ALL_MAXPOOL_HEX);
        $display("");

        $readmemh(`ALL_C2POOL_HEX,  c2pool_data);
        $readmemh(`ALL_MAXPOOL_HEX, maxpool_expect);
        $display("[TB] Loaded c2pool (%0d) + maxpool ref (%0d)",
                 N_IMAGES * 576, N_IMAGES * 144);

        // Init statistics
        for (i_main = 0; i_main < N_IMAGES; i_main = i_main + 1) begin
            per_image_mm[i_main]       = 0;
            cycle_at_img_start[i_main] = 0;
            cycle_at_wdone[i_main]     = 0;
        end
        cycle_at_first_prior = 0;

        // Reset
        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        // Wait for all images processed
        wait (all_done_flag == 1'b1);

        // Final report
        $display("\n=========================================");
        $display("  FINAL RESULT");
        $display("=========================================");
        $display("  images PASS    : %0d / %0d", images_pass, N_IMAGES);
        $display("  total compare  : %0d", N_IMAGES * 144);
        $display("  total mismatch : %0d", total_mismatches);
        $display("  total cycles   : %0d (first prior → last wdone)",
                 cycle_at_wdone[N_IMAGES-1] - cycle_at_first_prior);
        $display("  avg cycle/img  : %0d",
                 (cycle_at_wdone[N_IMAGES-1] - cycle_at_first_prior) / N_IMAGES);
        if (total_mismatches == 0 && images_pass == N_IMAGES)
            $display("  *** PASS *** (all %0d images bit-exact)", N_IMAGES);
        else
            $display("  *** FAIL ***");
        $display("=========================================");

        $finish;
    end

    //==========================================================================
    // PROCESS 2: Virtual conv2 (c2pool_writer) — per-image write + prior_wdone
    //==========================================================================
    integer i_w;
    initial begin : c2pool_writer_process
        wait (rst == 1'b0); @(negedge clk);

        for (i_w = 0; i_w < N_IMAGES; i_w = i_w + 1) begin
            // Backpressure: 2-bank ping-pong, maxpool 처리 1개 뒤까지만 허용
            wait ((i_w - rdone_count) < 2);

            cycle_at_img_start[i_w] = cycle_cnt;
            write_image(i_w);
            pulse_prior_wdone();

            if (i_w == 0) cycle_at_first_prior = cycle_cnt;
        end
    end

    //==========================================================================
    // PROCESS 3: Virtual fc (compare) — @wdone → compare → succ_rdone
    //==========================================================================
    integer i_cmp;
    initial begin : compare_process
        wait (rst == 1'b0); @(negedge clk);

        for (i_cmp = 0; i_cmp < N_IMAGES; i_cmp = i_cmp + 1) begin
            @(posedge wdone);
            cycle_at_wdone[i_cmp] = cycle_cnt;

            repeat (3) @(posedge clk);

            compare_image(i_cmp);
            pulse_succ_rdone();

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
    //   per image ~ (576 init + 870 maxpool + 144 compare) ≈ 1600 cycle
    //   40 images × 1600 ≈ 64,000 + init ≈ 70,000 cycle. 안전 위해 1M cycle.
    //==========================================================================
    initial begin
        #10000000;
        $display("\n[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
        $finish;
    end

endmodule
