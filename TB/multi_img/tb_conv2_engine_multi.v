`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Multi-image bit-exact testbench for conv2_engine
//
//   - 100 image 순차 처리 (ping-pong bank toggle 검증)
//   - 실제 Vivado BMG IP 직접 인스턴스:
//       bram_c1_to_c2   (Conv1→Conv2, L=2, depth 2048, 64-bit)
//       bram_c2_to_pool (Conv2→Maxpool, L=1, depth 2048, 128-bit)
//   - Virtual Conv1: BMG Port A 직접 write (TB code 가 pack + bank_sel 처리)
//   - Virtual Maxpool: BMG Port B 직접 read + expected 비교
//   - 각 image 별 PASS/FAIL + 종합 통계
//
//   주의:
//     - 이 TB 는 사용자가 만든 BMG IP 두 개 (bram_c1_to_c2, bram_c2_to_pool) 가
//       Vivado 프로젝트에 존재해야 작동.
//     - conv2_weight_bram 은 sim only behavioral 모델 사용 (single_img TB 와 동일).
//     - hex 파일들이 HEX_DIR 경로에 있어야 함 (200 files: imgXXX_c1c2.hex / imgXXX_c2pool.hex).
//
//   Path override 예시:
//     xelab -d HEX_DIR=\"C:/path/to/multi_img\" -d WEIGHT_HEX=\"C:/.../weights.hex\" ...
//////////////////////////////////////////////////////////////////////////////////

// V2001 호환 — 단일 big hex 파일 사용 (per-image 가 아닌 concatenated).
// Hex 파일 위치 변경 시 아래 3 define 만 수정.
`define CONV1_ALL_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_c1c2.hex"
`define CONV2_ALL_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_c2pool.hex"
`define WEIGHT_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_weights_simd.hex"


//////////////////////////////////////////////////////////////////////////////////
// Behavioral conv2_weight_bram (sim only — 사용자가 BMG IP 안 만들었을 경우 대체)
// 만약 실제 BMG IP `conv2_weight_bram` 이 프로젝트에 있으면 본 모듈 제거.
//////////////////////////////////////////////////////////////////////////////////
module conv2_weight_bram (
    input  wire        clka,
    input  wire        wea,
    input  wire [9:0]  addra,
    input  wire [31:0] dina,
    input  wire        clkb,
    input  wire        enb,
    input  wire        regceb,
    input  wire [9:0]  addrb,
    output reg  [31:0] doutb
);
    reg [31:0] mem [0:1023];
    reg [31:0] core;
    initial begin core = 32'h0; doutb = 32'h0; end
    always @(posedge clka) if (wea) mem[addra] <= dina;
    always @(posedge clkb) begin
        if (enb)    core  <= mem[addrb];
        if (regceb) doutb <= core;
    end
endmodule


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
    // BMG IP: bram_c1_to_c2 (사용자가 만든 IP)
    //   Port A : Virtual Conv1 write (TB 가 구동)
    //   Port B : Conv2 read (DUT 가 구동)
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
    // BMG IP: bram_c2_to_pool (사용자가 만든 IP)
    //   Port A : Conv2 write (DUT 가 구동)
    //   Port B : Virtual Maxpool read (TB 가 구동)
    //   wea : Byte Write Disable → 1-bit (1'b1 고정)
    //==========================================================================
    bram_c2_to_pool c2pool_bram (
        .clka  (clk),
        .ena   (c2pool_we_a),
        .wea   (1'b1),                // 1-bit, 항상 write all
        .addra (c2pool_addr_a),
        .dina  (c2pool_din_a),

        .clkb  (clk),
        .enb   (c2pool_enb_b),
        .addrb (c2pool_addr_b),
        .doutb (c2pool_doutb_b)
    );

    //==========================================================================
    // DUT
    //==========================================================================
    conv2_engine dut (
        .clk         (clk),
        .rst         (rst),
        .start       (start),

        // Conv2 weight BMG (behavioral, sim only)
        .c2w_ena     (1'b0),
        .c2w_addra   (10'd0),
        .c2w_dina    (32'd0),

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
    //   c1c2_data  [img_idx * 1024 + (h*32 + w)] = 64-bit   (padded BMG bank format)
    //   c2pool_data[img_idx * 576  + (h*24 + w)] = 128-bit  (compact write_addr 순)
    //
    //   c1c2 padded 1024 entry/image (32×32, 26×26 valid + zero padding) — Python
    //   에서 이미 padded 로 생성되어 BMG addr {bank, h[4:0], w[4:0]} 와 직접 매핑.
    //==========================================================================
    reg [63:0]  c1c2_data   [0:N_IMAGES*1024-1];  // 102,400 entries
    reg [127:0] c2pool_data [0:N_IMAGES*576-1];   //  57,600 entries

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
    // Task: Virtual Conv1 — write image to bram_c1_to_c2 Port A
    //
    //   bank = img_idx % 2
    //   c1c2 data 는 이미 padded format (1024 entry, h*32+w 순서) 으로 저장됨.
    //   → bank local addr k = 0..1023 그대로 BMG addr 의 하위 10-bit 로 사용.
    //   → padding entry (h≥26 또는 w≥26) 는 0 이므로 BMG 에도 0 write (무해).
    //==========================================================================
    task write_image;
        input integer img_idx;
        integer k, bank;
        begin
            bank = img_idx & 1;
            for (k = 0; k < 1024; k = k + 1) begin
                @(negedge clk);
                c1c2_ena_a   = 1'b1;
                c1c2_wea_a   = 8'hFF;             // 모든 byte write
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
    //
    //   bank = img_idx % 2
    //   addr = {bank, write_addr[9:0]} = bank*1024 + i  (i = 0..575)
    //   L=1 latency: addr@T → dout@T+1 → TB reads at iteration i+1
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
                // Issue read for addr i
                if (i < 576) begin
                    c2pool_enb_b  = 1'b1;
                    c2pool_addr_b = (bank << 10) | i[9:0];
                end else begin
                    c2pool_enb_b  = 1'b0;
                end

                // Collect data from previous addr (i-1), L=1 lag
                if (i > 0) begin
                    got = c2pool_doutb_b;
                    exp = c2pool_data[img_idx * 576 + (i - 1)];
                    if (got !== exp) begin
                        mm = mm + 1;
                        if (mm <= 3)  // 처음 3개만 상세 출력
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
    //   rdone_count : Conv2 가 c1c2 bank 비운 횟수 → conv1_process backpressure
    //   wdone_count : Conv2 가 c2pool bank 채운 횟수 → maxpool_process 동기
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
    //==========================================================================
    reg     all_done_flag       = 1'b0;
    integer cycle_at_start_pulse = 0;

    //==========================================================================
    // PROCESS 1: Main — reset, start, wait for completion, report
    //==========================================================================
    integer i_main;
    initial begin : main_process
        $display("\n==========================================");
        $display("  Conv2 multi-image testbench (N=%0d, parallel)", N_IMAGES);
        $display("==========================================");
        $display("  CONV1_ALL_HEX = %s", `CONV1_ALL_HEX);
        $display("  CONV2_ALL_HEX = %s", `CONV2_ALL_HEX);
        $display("  WEIGHT_HEX    = %s", `WEIGHT_HEX);
        $display("");

        // Load data
        $readmemh(`CONV1_ALL_HEX, c1c2_data);
        $readmemh(`CONV2_ALL_HEX, c2pool_data);
        $readmemh(`WEIGHT_HEX, dut.c2w_bmg_inst.mem);
        $display("[TB] Loaded c1c2 (%0d) + c2pool (%0d) + weight (576)",
                 N_IMAGES * 676, N_IMAGES * 576);

        // Init statistics
        for (i_main = 0; i_main < N_IMAGES; i_main = i_main + 1) begin
            per_image_mm[i_main]      = 0;
            cycle_at_img_start[i_main] = 0;
            cycle_at_wdone[i_main]    = 0;
        end

        // Init driving signals (defensive)
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
    //
    //   Backpressure: 동시 in-flight image 수 ≤ 2 (ping-pong bank 한계).
    //     pending = i - rdone_count  (image 까지 wrote 했으나 Conv2 가 아직 안 끝낸 수)
    //     쓸 수 있는 조건: pending < 2
    //==========================================================================
    integer i_conv1;
    initial begin : conv1_process
        // wait reset 해제
        wait (rst == 1'b0);
        @(negedge clk);

        for (i_conv1 = 0; i_conv1 < N_IMAGES; i_conv1 = i_conv1 + 1) begin
            // Backpressure
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

            // settle a few cycles for c2pool mem 안정화
            repeat (3) @(posedge clk);

            compare_image(i_max);
            pulse_succ_rdone();

            if (per_image_mm[i_max] == 0)
                $display("[TB] img %3d : PASS  @ wdone cycle %0d", i_max, cycle_at_wdone[i_max]);
            else
                $display("[TB] img %3d : FAIL  @ wdone cycle %0d  (%0d mm)",
                         i_max, cycle_at_wdone[i_max], per_image_mm[i_max]);
        end

        // Main 에게 종료 알림
        all_done_flag = 1'b1;
    end

    //==========================================================================
    // Timeout
    //==========================================================================
    initial begin
        #20000000;   // 20 ms = 약 3.6M cycle, 100 image × ~30K cycle 여유
        $display("\n[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
        $finish;
    end

endmodule
