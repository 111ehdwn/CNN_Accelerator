`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_conv1_conv2.v
// Conv1 + Conv2 integration testbench (single image, real BMG IPs)
//
//   Pipeline:
//     PS → bram_input   → Conv1 engine → bram_c1_to_c2 → Conv2 engine
//                                                                ↓
//                                                       bram_c2_to_pool
//                                                                ↓
//                                                       TB read + compare
//
//   Conv1 의 done → Conv2 의 prior_wdone 펄스 (handshake)
//   bank_sel = 0 (single image, ping-pong 미사용)
//
//   필요한 BMG IP (Vivado 프로젝트에 미리 생성):
//     bram_input           (Port A 32b × 512, Port B 8b × 2048, asymmetric, L=1)
//     conv1_weight_bram    (32b × 64,  L=2, REGCEB 노출)
//     bram_c1_to_c2        (64b × 2048, L=2, byte-write 8-bit)
//     conv2_weight_bram    (32b × 1024, L=2, REGCEB 노출)
//     bram_c2_to_pool      (128b × 2048, L=1)
//   상세 spec: docs/ip_spec/block_memory_generator.md
//////////////////////////////////////////////////////////////////////////////////

`define CONV1_INPUT_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_input.hex"
`define CONV1_WEIGHT_HEX    "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_weights_simd.hex"
`define CONV2_WEIGHT_HEX    "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_weights_simd.hex"
`define CONV2_EXPECTED_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_output_c2pool.hex"


module tb_conv1_conv2;

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

    // ping-pong bank 은 각 engine 내부 toggle FF (single image → 0 고정).

    //==========================================================================
    // BMG signal nets
    //==========================================================================
    // bram_input (asymmetric: Port A 32-bit × 512, Port B 8-bit × 2048)
    reg          in_ena   = 1'b0;
    reg          in_wea   = 1'b0;
    reg  [8:0]   in_addra = 9'd0;             // word addr
    reg  [31:0]  in_dina  = 32'd0;            // 4 bytes packed
    wire [10:0]  in_addrb;                    // byte addr
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

    // bram_c1_to_c2 (Conv1 write A, Conv2 read B)
    wire         c1c2_we_a;
    wire [7:0]   c1c2_wea_a;
    wire [10:0]  c1c2_addr_a;
    wire [63:0]  c1c2_din_a;
    wire         c1c2_re_b;
    wire [10:0]  c1c2_addr_b;
    wire [63:0]  c1c2_doutb_b;

    // conv2_weight_bram (TB write A, Conv2 read B)
    reg          c2w_ena   = 1'b0;
    reg  [9:0]   c2w_addra = 10'd0;
    reg  [31:0]  c2w_dina  = 32'd0;

    // bram_c2_to_pool (Conv2 write A, TB read B)
    wire         c2pool_we_a;
    wire [10:0]  c2pool_addr_a;
    wire [127:0] c2pool_din_a;
    reg          c2pool_enb_b   = 1'b0;
    reg  [10:0]  c2pool_addr_b  = 11'd0;
    wire [127:0] c2pool_doutb_b;

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

        .prior_wdone  (1'b0),       // conv1 은 start 로 트리거 (legacy backup)
        .succ_rdone   (1'b0),       // single image — tie low
        .rdone        (),           // 미사용
        .wdone        (),           // 미사용 (done 으로 완료 감지 → conv2 prior_wdone 수동 pulse)

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
    //   handshake: Conv1.done (1 cycle pulse) → Conv2.prior_wdone
    //              Conv2.rdone → 무시 (Conv1 은 한 번만 실행)
    //              Conv2.wdone → wait for compare
    //              Conv2.succ_rdone = 0 (Maxpool 없음, after_diff < 2 자연 충족)
    //==========================================================================
    reg conv2_prior_wdone = 1'b0;
    reg conv2_succ_rdone  = 1'b0;        // tie low (no downstream consumer)

    conv2_engine conv2 (
        .clk         (clk),
        .rst         (rst),                // active-high
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
    // TB-local data
    //==========================================================================
    reg [7:0]   input_mem      [0:783];
    reg [31:0]  weight1_mem    [0:35];
    reg [31:0]  weight2_mem    [0:575];
    reg [127:0] expected_c2pool [0:575];

    //==========================================================================
    // Cycle counter
    //==========================================================================
    integer cycle_cnt;
    integer cycle_at_conv1_start, cycle_at_conv1_done;
    integer cycle_at_conv2_start, cycle_at_conv2_wdone;

    initial cycle_cnt = 0;
    always @(posedge clk) if (rst_n) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Tasks: init_* and pulse_*
    //==========================================================================
    task init_input;
        integer k;
        begin
            $display("[TB] @ %0d : init_input (196 word × 32-bit, bank 0)", cycle_cnt);
            for (k = 0; k < 196; k = k + 1) begin
                @(negedge clk);
                in_ena = 1'b1; in_wea = 1'b1;
                in_addra = {1'b0, k[7:0]};         // bank 0, word addr 0..195
                in_dina  = {input_mem[k*4 + 3], input_mem[k*4 + 2],
                            input_mem[k*4 + 1], input_mem[k*4 + 0]};
            end
            @(negedge clk); in_ena = 1'b0; in_wea = 1'b0;
        end
    endtask

    task init_weight1;
        integer wi;
        begin
            $display("[TB] @ %0d : init_weight1 (36)", cycle_cnt);
            for (wi = 0; wi < 36; wi = wi + 1) begin
                @(negedge clk);
                w1_ena = 1'b1; w1_wea = 1'b1;
                w1_addra = wi[5:0]; w1_dina = weight1_mem[wi];
            end
            @(negedge clk); w1_ena = 1'b0; w1_wea = 1'b0;
        end
    endtask

    task init_weight2;
        integer wi;
        begin
            $display("[TB] @ %0d : init_weight2 (576)", cycle_cnt);
            for (wi = 0; wi < 576; wi = wi + 1) begin
                @(negedge clk);
                c2w_ena = 1'b1;
                c2w_addra = wi[9:0]; c2w_dina = weight2_mem[wi];
            end
            @(negedge clk); c2w_ena = 1'b0;
        end
    endtask

    task pulse_conv1_start;
        begin
            @(negedge clk); conv1_start = 1'b1;
            cycle_at_conv1_start = cycle_cnt;
            @(negedge clk); conv1_start = 1'b0;
        end
    endtask

    task pulse_conv2_start;
        begin
            @(negedge clk); conv2_start = 1'b1;
            cycle_at_conv2_start = cycle_cnt;
            @(negedge clk); conv2_start = 1'b0;
        end
    endtask

    task pulse_conv2_prior_wdone;
        begin
            @(negedge clk); conv2_prior_wdone = 1'b1;
            @(negedge clk); conv2_prior_wdone = 1'b0;
        end
    endtask

    //==========================================================================
    // Compare task: c2pool BMG bank 0 vs expected (576 entries, L=1 pipelined read)
    //==========================================================================
    integer total_mm;
    task compare_c2pool;
        integer i;
        reg [127:0] got, exp;
        begin
            total_mm = 0;
            $display("[TB] Comparing c2pool BMG bank 0 vs expected ...");
            for (i = 0; i < 577; i = i + 1) begin
                @(negedge clk);
                if (i < 576) begin
                    c2pool_enb_b  = 1'b1;
                    c2pool_addr_b = {1'b0, i[9:0]};   // bank 0
                end else begin
                    c2pool_enb_b  = 1'b0;
                end

                if (i > 0) begin
                    got = c2pool_doutb_b;
                    exp = expected_c2pool[i - 1];
                    if (got !== exp) begin
                        total_mm = total_mm + 1;
                        if (total_mm <= 10)
                            $display("  MM @ addr %0d : got=%h, exp=%h",
                                     i - 1, got, exp);
                    end
                end
            end
            @(negedge clk); c2pool_enb_b = 1'b0;
        end
    endtask

    //==========================================================================
    // Main stimulus
    //==========================================================================
    initial begin
        $display("[TB] === Conv1 + Conv2 integration test ===");
        $readmemh(`CONV1_INPUT_HEX,     input_mem);
        $readmemh(`CONV1_WEIGHT_HEX,    weight1_mem);
        $readmemh(`CONV2_WEIGHT_HEX,    weight2_mem);
        $readmemh(`CONV2_EXPECTED_HEX,  expected_c2pool);

        // Reset
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        $display("[TB] @ %0d : reset released", cycle_cnt);

        // Initialize all BMG (parallel-able but sequential 으로 단순화)
        init_input();
        init_weight1();
        init_weight2();

        // Start Conv2 first (LOAD_WEIGHTS 거치며 대기 상태) — prior_wdone 받기까지 IDLE/DONE
        pulse_conv2_start();
        $display("[TB] @ %0d : conv2_start pulsed (enters LOAD_WEIGHTS)", cycle_at_conv2_start);

        // Start Conv1 (input/weight 다 준비 후)
        pulse_conv1_start();
        $display("[TB] @ %0d : conv1_start pulsed", cycle_at_conv1_start);

        // Wait Conv1 done
        @(posedge conv1_done);
        cycle_at_conv1_done = cycle_cnt;
        $display("[TB] @ %0d : conv1_done received (Conv1 cycle: %0d)",
                 cycle_at_conv1_done, cycle_at_conv1_done - cycle_at_conv1_start);

        // BMG settle (Conv1 의 마지막 write 가 mem 에 반영) — 약간 여유.
        // 또한 conv2 의 LOAD_WEIGHTS (576 cycle) 가 끝나 prior_wdone 을 latch 할 수 있는
        // 상태가 되었음을 보장. Conv1 compute (~1617 cycle) >> conv2 LOAD_WEIGHTS (576) 이므로
        // 현 design 에서는 항상 safe; conv1 가 짧아지면 여기 추가 wait 필요.
        repeat (3) @(posedge clk);

        // Pulse Conv2 prior_wdone (= Conv1 데이터 ready 알림)
        pulse_conv2_prior_wdone();
        $display("[TB] @ %0d : conv2 prior_wdone pulsed", cycle_cnt);

        // Wait Conv2 wdone
        @(posedge conv2_wdone);
        cycle_at_conv2_wdone = cycle_cnt;
        $display("[TB] @ %0d : conv2_wdone received (Conv2 compute: %0d)",
                 cycle_at_conv2_wdone, cycle_at_conv2_wdone - cycle_at_conv1_done);

        // c2pool settle
        repeat (3) @(posedge clk);

        // Compare
        compare_c2pool();

        // Report
        $display("");
        $display("================================================");
        $display("  Conv1 + Conv2 integration test result");
        $display("================================================");
        $display("  conv1_start   @ cycle %0d", cycle_at_conv1_start);
        $display("  conv1_done    @ cycle %0d", cycle_at_conv1_done);
        $display("  conv2_wdone   @ cycle %0d", cycle_at_conv2_wdone);
        $display("  Conv1 cycles  : %0d", cycle_at_conv1_done - cycle_at_conv1_start);
        $display("  Conv2 cycles  : %0d", cycle_at_conv2_wdone - cycle_at_conv1_done);
        $display("  Total cycles  : %0d", cycle_at_conv2_wdone - cycle_at_conv1_start);
        $display("  mismatches    : %0d / 576", total_mm);
        if (total_mm == 0)
            $display("  *** PASS *** (bit-exact match)");
        else
            $display("  *** FAIL ***");
        $display("================================================");

        $finish;
    end

    initial begin
        #2000000;   // 200,000 cycle @ 100 MHz — conv1+conv2 전체 + 여유
        $display("[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
        $finish;
    end

endmodule
