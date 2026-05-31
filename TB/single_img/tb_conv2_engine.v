`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_conv2_engine.v
// Single-image bit-exact testbench for conv2_engine (통과 표준: 공유 BMG, 100MHz)
//
//   Pipeline:
//     TB write bram_c1_to_c2 Port A (가상 Conv1) → Conv2 read Port B →
//     Conv2 write bram_c2_to_pool Port A → TB read Port B + compare
//   Weight: init_weight() task 가 conv2_weight_bram Port A driving (DUT 내부 BMG).
//   자극: reset → init_weight → write_c1c2(bank 0) → start → prior_wdone → wdone → compare.
//
//   공유 BMG 모델: TB/models/bmg_sim_models.v (iverilog) / 실제 BMG IP (Vivado).
//     bram_c1_to_c2     (64b × 2048, byte-write 8b, L=2)
//     bram_c2_to_pool   (128b × 2048, L=1)
//     conv2_weight_bram (32b × 1024, L=2, regceb — DUT 내부 인스턴스)
//////////////////////////////////////////////////////////////////////////////////

`ifdef __ICARUS__
  `define CONV1_HEX   "data/single_img/conv1_output_c1c2.hex"
  `define CONV2_HEX   "data/single_img/conv2_output_c2pool.hex"
  `define WEIGHT_HEX  "data/weights_simd/conv2_weights_simd.hex"
`else
  `define CONV1_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_output_c1c2.hex"
  `define CONV2_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_output_c2pool.hex"
  `define WEIGHT_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_weights_simd.hex"
`endif


module tb_conv2_engine;

    //==========================================================================
    // Clock / reset (100 MHz, active-high rst)
    //==========================================================================
    parameter CLK_PERIOD = 10;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(CLK_PERIOD/2) clk = ~clk;

    //==========================================================================
    // DUT signals
    //==========================================================================
    reg          start       = 1'b0;

    // Conv2 weight Port A — TB init_weight driving (DUT 내부 conv2_weight_bram)
    reg          c2w_ena     = 1'b0;
    reg  [3:0]   c2w_wea     = 4'd0;
    reg  [9:0]   c2w_addra   = 10'd0;
    reg  [31:0]  c2w_dina    = 32'd0;

    // c1c2 BMG Port B (Conv2 read)
    wire         c1c2_re;
    wire [10:0]  c1c2_addr_b;
    wire [63:0]  c1c2_dout_b;

    // c1c2 BMG Port A (가상 Conv1 write)
    reg          c1c2_ena_a  = 1'b0;
    reg  [7:0]   c1c2_wea_a  = 8'h00;
    reg  [10:0]  c1c2_addr_a = 11'd0;
    reg  [63:0]  c1c2_din_a  = 64'd0;

    // c2pool BMG Port A (Conv2 write)
    wire         c2pool_we_a;
    wire [10:0]  c2pool_addr_a;
    wire [127:0] c2pool_din_a;

    // c2pool BMG Port B (TB read, compare)
    reg          c2pool_enb_b  = 1'b0;
    reg  [10:0]  c2pool_addr_b = 11'd0;
    wire [127:0] c2pool_doutb_b;

    // Handshake
    reg          prior_wdone = 1'b0;
    wire         rdone;
    reg          succ_rdone  = 1'b0;
    wire         wdone;

    //==========================================================================
    // BMG: bram_c1_to_c2 (Conv1→Conv2, L=2)
    //==========================================================================
    bram_c1_to_c2 c1c2_bmg (
        .clka  (clk), .ena (c1c2_ena_a), .wea (c1c2_wea_a),
        .addra (c1c2_addr_a), .dina (c1c2_din_a),
        .clkb  (clk), .enb (c1c2_re),
        .addrb (c1c2_addr_b), .doutb (c1c2_dout_b)
    );

    //==========================================================================
    // BMG: bram_c2_to_pool (Conv2→Maxpool, L=1)
    //==========================================================================
    bram_c2_to_pool c2pool_bmg (
        .clka  (clk), .ena (c2pool_we_a), .wea (1'b1),
        .addra (c2pool_addr_a), .dina (c2pool_din_a),
        .clkb  (clk), .enb (c2pool_enb_b),
        .addrb (c2pool_addr_b), .doutb (c2pool_doutb_b)
    );

    //==========================================================================
    // DUT — 실제 conv2_weight_bram BMG IP 사용 (DUT 내부)
    //==========================================================================
    conv2_engine dut (
        .clk         (clk),
        .rst         (rst),
        .start       (start),

        .c2w_ena     (c2w_ena),
        .c2w_wea     (c2w_wea),
        .c2w_addra   (c2w_addra),
        .c2w_dina    (c2w_dina),

        .c1c2_re     (c1c2_re),
        .c1c2_addr   (c1c2_addr_b),
        .c1c2_dout   (c1c2_dout_b),

        .c2pool_we   (c2pool_we_a),
        .c2pool_addr (c2pool_addr_a),
        .c2pool_din  (c2pool_din_a),

        .prior_wdone (prior_wdone),
        .rdone       (rdone),
        .succ_rdone  (succ_rdone),
        .wdone       (wdone)
    );

    //==========================================================================
    // TB-local data
    //==========================================================================
    reg [63:0]  c1c2_data       [0:1023];   // conv1 output (= c1c2 input), bank 0
    reg [31:0]  weight_mem      [0:575];
    reg [127:0] expected_c2pool [0:575];

    //==========================================================================
    // Cycle counter
    //==========================================================================
    integer cycle_cnt;
    integer cycle_at_init_done, cycle_at_start, cycle_at_prior_wdone, cycle_at_wdone;
    initial cycle_cnt = 0;
    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Task: init_weight — conv2_weight_bram Port A 576 cycle write
    //==========================================================================
    task init_weight;
        integer wi;
        begin
            $display("[TB] @ cycle %0d : init_weight start (576 cycle)", cycle_cnt);
            for (wi = 0; wi < 576; wi = wi + 1) begin
                @(negedge clk);
                c2w_ena   = 1'b1;
                c2w_wea   = 4'hF;
                c2w_addra = wi[9:0];
                c2w_dina  = weight_mem[wi];
            end
            @(negedge clk);
            c2w_ena = 1'b0; c2w_wea = 4'd0; c2w_addra = 10'd0; c2w_dina = 32'd0;
            cycle_at_init_done = cycle_cnt;
            $display("[TB] @ cycle %0d : init_weight done", cycle_at_init_done);
        end
    endtask

    //==========================================================================
    // Task: write_c1c2 — 가상 Conv1: bram_c1_to_c2 Port A bank 0 (1024 entry)
    //==========================================================================
    task write_c1c2;
        integer k;
        begin
            $display("[TB] @ cycle %0d : write_c1c2 start (1024 entry, bank 0)", cycle_cnt);
            for (k = 0; k < 1024; k = k + 1) begin
                @(negedge clk);
                c1c2_ena_a  = 1'b1;
                c1c2_wea_a  = 8'hFF;
                c1c2_addr_a = {1'b0, k[9:0]};   // bank 0
                c1c2_din_a  = c1c2_data[k];
            end
            @(negedge clk);
            c1c2_ena_a = 1'b0; c1c2_wea_a = 8'h00;
        end
    endtask

    //==========================================================================
    // Task: compare_c2pool — bram_c2_to_pool Port B bank 0 (576, L=1) vs expected
    //==========================================================================
    integer total_mm;
    task compare_c2pool;
        integer i;
        reg [127:0] got, exp;
        begin
            total_mm = 0;
            $display("[TB] Comparing c2pool BMG bank 0 (576 entries, L=1) vs expected ...");
            for (i = 0; i < 577; i = i + 1) begin
                @(negedge clk);
                if (i < 576) begin
                    c2pool_enb_b  = 1'b1;
                    c2pool_addr_b = {1'b0, i[9:0]};   // bank 0
                end else begin
                    c2pool_enb_b  = 1'b0;
                end
                if (i > 0) begin                       // L=1: i-1 데이터 비교
                    got = c2pool_doutb_b;
                    exp = expected_c2pool[i - 1];
                    if (got !== exp) begin
                        total_mm = total_mm + 1;
                        if (total_mm <= 10)
                            $display("  MM @ addr %0d (h=%0d w=%0d) : got=%h, exp=%h",
                                     i-1, (i-1)/24, (i-1)%24, got, exp);
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
        $display("[TB] === Conv2 single-image bit-exact test (공유 BMG, 100MHz) ===");
        $readmemh(`CONV1_HEX,  c1c2_data);        // conv1 output (= c1c2 input)
        $readmemh(`WEIGHT_HEX, weight_mem);
        $readmemh(`CONV2_HEX,  expected_c2pool);

        // Reset
        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        // init_weight (conv2_weight_bram Port A)
        init_weight();

        // 가상 Conv1: c1c2 BMG bank 0 write
        write_c1c2();

        // start pulse (LOAD_WEIGHTS 진입)
        @(negedge clk); start = 1'b1;
        cycle_at_start = cycle_cnt;
        @(negedge clk); start = 1'b0;
        $display("[TB] @ cycle %0d : start pulsed", cycle_at_start);

        // prior_wdone pulse (data_ready → RUN)
        @(negedge clk); prior_wdone = 1'b1;
        cycle_at_prior_wdone = cycle_cnt;
        @(negedge clk); prior_wdone = 1'b0;
        $display("[TB] @ cycle %0d : prior_wdone pulsed", cycle_at_prior_wdone);

        // wait wdone
        @(posedge wdone);
        cycle_at_wdone = cycle_cnt;
        $display("[TB] @ cycle %0d : wdone received", cycle_at_wdone);

        repeat (5) @(posedge clk);

        // compare
        compare_c2pool();

        // report
        $display("");
        $display("================================================");
        $display("  Conv2 single-image testbench result");
        $display("================================================");
        $display("  init_weight done @ cycle %0d", cycle_at_init_done);
        $display("  start            @ cycle %0d", cycle_at_start);
        $display("  prior_wdone      @ cycle %0d", cycle_at_prior_wdone);
        $display("  wdone            @ cycle %0d", cycle_at_wdone);
        $display("  compute (start→wdone) : %0d cycles", cycle_at_wdone - cycle_at_start);
        $display("  mismatches            : %0d / 576", total_mm);
        if (total_mm == 0)
            $display("  *** PASS *** (bit-exact match)");
        else
            $display("  *** FAIL ***");
        $display("================================================");
        $finish;
    end

    //==========================================================================
    // Timeout
    //==========================================================================
    initial begin
        #200000;
        $display("\n[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
        $finish;
    end

endmodule
