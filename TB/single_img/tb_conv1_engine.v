`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_conv1_engine.v
// Single-image bit-exact testbench for conv1_engine  (uses real BMG IPs)
//
//   3 real BMG IP instantiation:
//     bram_input         (PS write Port A 32-bit × 512, Conv1 read Port B 8-bit × 2048, L=1)
//     conv1_weight_bram  (PS write Port A, Conv1 read Port B) — 32-bit × 64, L=2, REGCEB exposed
//     bram_c1_to_c2      (Conv1 write Port A, TB read Port B) — 64-bit × 2048, L=2, byte-write 8-bit
//
//   자극 sequence:
//     reset → init_input() → init_weight() → start pulse → wait done → compare c1c2 BMG bank 0 vs expected
//
//   Conv1 동작 (요약):
//     IDLE → LOAD (weight 적재 ~40 cycle) → RUN1 (28×28 scan, oc0..3, sel=0) → FLUSH1
//     → LBRST → RUN2 (28×28 scan, oc4..7, sel=1) → FLUSH2 → DONE
//     done 시 c1c2 BMG bank 0 에 8 OC × 26×26 결과 완성.
//////////////////////////////////////////////////////////////////////////////////

`define CONV1_INPUT_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_input.hex"
`define CONV1_WEIGHT_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_weights_simd.hex"
`define CONV1_EXPECTED_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_output_c1c2.hex"


module tb_conv1_engine;

    //==========================================================================
    // Clock / reset (100 MHz)
    //==========================================================================
    reg clk = 1'b0;
    reg rst = 1'b1;        // active-high (시스템 통일)
    always #5 clk = ~clk;

    //==========================================================================
    // DUT 시그널
    //==========================================================================
    reg          start    = 1'b0;
    wire         done;

    // ping-pong bank 은 conv1_engine 내부 toggle FF (internal-only) — TB driving 불필요.

    // bram_input interface (asymmetric: Port A 32-bit × 512, Port B 8-bit × 2048)
    reg          in_ena   = 1'b0;            // TB driving Port A (init_input, 32-bit burst)
    reg          in_wea   = 1'b0;
    reg  [8:0]   in_addra = 9'd0;            // word addr (= byte_addr/4)
    reg  [31:0]  in_dina  = 32'd0;           // 4 bytes packed (little-endian)
    wire [10:0]  in_addrb;                   // Conv1 reads Port B, byte addr
    wire         in_enb;
    wire signed [7:0] in_doutb;

    // conv1_weight_bram interface
    reg          w_ena    = 1'b0;            // TB driving Port A (init_weight)
    reg          w_wea    = 1'b0;
    reg  [5:0]   w_addra  = 6'd0;
    reg  [31:0]  w_dina   = 32'd0;
    wire [5:0]   w_addrb;
    wire         w_enb;
    wire [31:0]  w_doutb;

    // bram_c1_to_c2 interface
    wire         c1c2_we_a;                  // Conv1 writes Port A
    wire [7:0]   c1c2_wea_a;
    wire [10:0]  c1c2_addr_a;
    wire [63:0]  c1c2_din_a;
    reg          c1c2_enb_b   = 1'b0;        // TB reads Port B (verification)
    reg  [10:0]  c1c2_addr_b  = 11'd0;
    wire [63:0]  c1c2_doutb_b;

    //==========================================================================
    // BMG IP 인스턴스 (사용자 측 Vivado 프로젝트에 생성 필요)
    //==========================================================================
    bram_input in_bmg (
        .clka  (clk),
        .ena   (in_ena),
        .wea   (in_wea),
        .addra (in_addra),
        .dina  (in_dina),
        .clkb  (clk),
        .enb   (in_enb),
        .addrb (in_addrb),
        .doutb (in_doutb)
    );

    conv1_weight_bram w_bmg (
        .clka  (clk),
        .ena   (w_ena),
        .wea   (w_wea),
        .addra (w_addra),
        .dina  (w_dina),
        .clkb  (clk),
        .enb   (w_enb),
        .addrb (w_addrb),
        .doutb (w_doutb),
        .regceb(1'b1)                        // 상수 1: 마지막 weight propagation 보장
    );

    bram_c1_to_c2 c1c2_bmg (
        .clka  (clk),
        .ena   (c1c2_we_a),
        .wea   (c1c2_wea_a),
        .addra (c1c2_addr_a),
        .dina  (c1c2_din_a),
        .clkb  (clk),
        .enb   (c1c2_enb_b),
        .addrb (c1c2_addr_b),
        .doutb (c1c2_doutb_b)
    );

    //==========================================================================
    // DUT
    //==========================================================================
    conv1_engine dut (
        .clk          (clk),
        .rst          (rst),
        .start        (start),
        .done         (done),

        .prior_wdone  (1'b0),       // start 로 트리거 (legacy backup) — prior 미사용
        .succ_rdone   (1'b0),       // downstream 없음
        .rdone        (),           // 미사용
        .wdone        (),           // 미사용 (done 으로 완료 감지)

        .in_bram_addr (in_addrb),
        .in_bram_en   (in_enb),
        .in_bram_dout (in_doutb),

        .w_bram_addr  (w_addrb),
        .w_bram_en    (w_enb),
        .w_bram_dout  (w_doutb),

        .c1c2_we      (c1c2_we_a),
        .c1c2_wea     (c1c2_wea_a),
        .c1c2_addr    (c1c2_addr_a),
        .c1c2_din     (c1c2_din_a)
    );

    //==========================================================================
    // TB-local memory (init 용)
    //==========================================================================
    reg [7:0]  input_mem  [0:783];          // 28×28 raw pixels
    reg [31:0] weight_mem [0:35];           // Conv1 packed weights (36 entry)
    reg [63:0] expected_c1c2 [0:1023];      // expected c1c2 BMG bank 0 (1024 padded)

    //==========================================================================
    // Cycle counter
    //==========================================================================
    integer cycle_cnt;
    integer cycle_at_start, cycle_at_done;

    initial cycle_cnt = 0;
    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Task: init_input — Port A 로 784 cycle 동안 input image write
    //==========================================================================
    task init_input;
        integer k;
        begin
            $display("[TB] @ cycle %0d : init_input start (196 word × 32-bit, bank 0)", cycle_cnt);
            // 784 byte = 196 word (4 byte / word). Little-endian packing.
            for (k = 0; k < 196; k = k + 1) begin
                @(negedge clk);
                in_ena   = 1'b1;
                in_wea   = 1'b1;
                in_addra = {1'b0, k[7:0]};         // bank 0 (MSB=0), word addr 0..195
                in_dina  = {input_mem[k*4 + 3],
                            input_mem[k*4 + 2],
                            input_mem[k*4 + 1],
                            input_mem[k*4 + 0]};
            end
            @(negedge clk);
            in_ena   = 1'b0;
            in_wea   = 1'b0;
            $display("[TB] @ cycle %0d : init_input done", cycle_cnt);
        end
    endtask

    //==========================================================================
    // Task: init_weight — Port A 로 36 cycle 동안 weight write
    //==========================================================================
    task init_weight;
        integer wi;
        begin
            $display("[TB] @ cycle %0d : init_weight start (36 cycle)", cycle_cnt);
            for (wi = 0; wi < 36; wi = wi + 1) begin
                @(negedge clk);
                w_ena   = 1'b1;
                w_wea   = 1'b1;
                w_addra = wi[5:0];
                w_dina  = weight_mem[wi];
            end
            @(negedge clk);
            w_ena   = 1'b0;
            w_wea   = 1'b0;
            $display("[TB] @ cycle %0d : init_weight done", cycle_cnt);
        end
    endtask

    //==========================================================================
    // Task: compare_c1c2 — bank 0 read + expected 비교 (L=2 pipelined read)
    //==========================================================================
    integer total_mm;
    task compare_c1c2;
        integer i;
        reg [63:0] got, exp;
        reg [10:0] read_addr;
        begin
            total_mm = 0;
            $display("[TB] Comparing c1c2 BMG bank 0 (1024 entries) vs expected ...");
            // Pipelined read (L=2): addr@T → dout@T+2
            for (i = 0; i < 1024 + 2; i = i + 1) begin
                @(negedge clk);
                if (i < 1024) begin
                    c1c2_enb_b  = 1'b1;
                    c1c2_addr_b = {1'b0, i[9:0]};   // bank 0
                end else begin
                    c1c2_enb_b  = 1'b0;
                end

                if (i >= 2) begin
                    read_addr = i - 2;
                    got = c1c2_doutb_b;
                    exp = expected_c1c2[read_addr];
                    if (got !== exp) begin
                        total_mm = total_mm + 1;
                        if (total_mm <= 10) begin
                            $display("  MM @ addr %0d : got=%h, exp=%h",
                                     read_addr, got, exp);
                        end
                    end
                end
            end
            @(negedge clk);
            c1c2_enb_b = 1'b0;
        end
    endtask

    //==========================================================================
    // Main stimulus
    //==========================================================================
    initial begin
        $display("[TB] === Conv1 single-image bit-exact test ===");
        $display("[TB] Loading input  : %s", `CONV1_INPUT_HEX);
        $readmemh(`CONV1_INPUT_HEX,    input_mem);
        $display("[TB] Loading weight : %s", `CONV1_WEIGHT_HEX);
        $readmemh(`CONV1_WEIGHT_HEX,   weight_mem);
        $display("[TB] Loading expected: %s", `CONV1_EXPECTED_HEX);
        $readmemh(`CONV1_EXPECTED_HEX, expected_c1c2);

        // Reset (active-high)
        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        // Init BMGs (Port A driving)
        init_input();
        init_weight();

        // Start pulse
        @(negedge clk);
        start = 1'b1;
        cycle_at_start = cycle_cnt;
        @(negedge clk);
        start = 1'b0;
        $display("[TB] @ cycle %0d : start pulsed", cycle_at_start);

        // Wait done
        @(posedge done);
        cycle_at_done = cycle_cnt;
        $display("[TB] @ cycle %0d : done received", cycle_at_done);

        // Settle a few cycles for c1c2 BMG mem update
        repeat (5) @(posedge clk);

        // Compare c1c2 BMG bank 0 vs expected
        compare_c1c2();

        // Report
        $display("");
        $display("================================================");
        $display("  Conv1 single-image testbench result");
        $display("================================================");
        $display("  start       @ cycle %0d", cycle_at_start);
        $display("  done        @ cycle %0d", cycle_at_done);
        $display("  compute     : %0d cycles", cycle_at_done - cycle_at_start);
        $display("  mismatches  : %0d / 1024", total_mm);
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
        #100000;
        $display("[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
        $finish;
    end

endmodule
