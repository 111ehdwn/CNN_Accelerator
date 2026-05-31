`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_conv1_engine.v  (behavioral BRAMs, 4-way handshake, per-channel error report)
// Single-image bit-exact testbench for conv1_engine
//
//   BRAM models (behavioral, latency matches Vivado BMG IP):
//     bram_input        : byte array [0:2047], L=1 (ENA-gated output register)
//     conv1_weight_bram : word array [0:63],   L=2 (REGCEB=1, 2-stage pipeline)
//     bram_c1_to_c2     : qword array [0:2047], byte-write, direct-compare after wdone
//
//   Handshake (4-way, single-image):
//     prior_wdone - 1-cycle pulse → triggers IDLE→LOAD
//     succ_rdone  - tied 0         → no downstream back-pressure
//     rdone       - fires at end of RUN2 (input read done)
//     wdone       - fires in DONE state (c1c2 write done) → we wait here
//
//   Data files (absolute paths):
//     conv1_input.hex         - 784 entries x 8-bit  (28x28 pixels)
//     conv1_weights_simd.hex  - 36  entries x 32-bit (packed weights)
//     conv1_output_c1c2.hex   - 1024 entries x 64-bit (expected bank 0)
//
//   FSM cycle budget (approx):
//     LOAD(~40) + RUN1(784) + FLUSH1(6) + LBRST(1) + RUN2(784) + FLUSH2(6) + DONE(1)
//     = ~1622 cycles  (timeout = 20000 cycles)
//////////////////////////////////////////////////////////////////////////////////

`define CONV1_INPUT_HEX    "C:/Users/111eh/INTELLIGENT_SYSTEM_DESIGN/assign4_code/CNN_Accelerator/data/single_img/conv1_input.hex"
`define CONV1_WEIGHT_HEX   "C:/Users/111eh/INTELLIGENT_SYSTEM_DESIGN/assign4_code/CNN_Accelerator/data/weights_simd/conv1_weights_simd.hex"
`define CONV1_EXPECTED_HEX "C:/Users/111eh/INTELLIGENT_SYSTEM_DESIGN/assign4_code/CNN_Accelerator/data/single_img/conv1_output_c1c2.hex"

module tb_conv1_engine;

    //==========================================================================
    // Clock / reset  (100 MHz, active-high rst)
    //==========================================================================
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    //==========================================================================
    // 4-way handshake signals
    //==========================================================================
    reg  prior_wdone = 1'b0;  // TB pulses this to tell conv1 "image is ready"
    reg  succ_rdone  = 1'b0;  // single image: no downstream, tie to 0
    wire rdone;                // conv1 → "input BRAM read done"
    wire wdone;                // conv1 → "c1c2 write done"  <- we wait on this

    // Legacy - not used for triggering in the 4-way handshake design
    reg  start = 1'b0;
    wire done;

    //==========================================================================
    // BRAM interface wires (all driven/received by DUT)
    //==========================================================================
    // bram_input Port B  (L=1, 8-bit signed, 11-bit addr = {bank_sel[0], px[9:0]})
    wire [10:0]       in_addrb;
    wire              in_enb;
    wire signed [7:0] in_doutb;

    // conv1_weight_bram Port B  (L=2, 32-bit, 6-bit addr)
    wire [5:0]  w_addrb;
    wire        w_enb;
    wire [31:0] w_doutb;

    // bram_c1_to_c2 Port A  (byte-write, 64-bit, written by DUT)
    wire        c1c2_we;
    wire [7:0]  c1c2_wea;
    wire [10:0] c1c2_addr;
    wire [63:0] c1c2_din;

    //==========================================================================
    // Behavioral: bram_input
    //   - Stores 2048 bytes (2 banks x 1024 pixels).  Bank 0 = addr[10]=0.
    //   - Port B read latency = 1 clock (ENA-gated output register).
    //   - We load pixels directly with $readmemh; no Port A logic needed.
    //==========================================================================
    reg [7:0] in_mem [0:2047];

    reg [7:0] in_doutb_r;
    always @(posedge clk) begin
        if (in_enb)
            in_doutb_r <= in_mem[in_addrb];
    end
    assign in_doutb = in_doutb_r;

    //==========================================================================
    // Behavioral: conv1_weight_bram
    //   - 32-bit x 64 words.  conv1 uses addresses 0..35.
    //   - Port B read latency = 2 clocks (matches BMG REGCEB=1):
    //       stage1: gated by ENB  (core output register)
    //       stage2: always active (REGCEB=1 output register)
    //   - Weights loaded directly with $readmemh; no Port A logic needed.
    //==========================================================================
    reg [31:0] w_mem [0:63];

    reg [31:0] w_dout_r1, w_dout_r2;
    always @(posedge clk) begin
        if (w_enb) w_dout_r1 <= w_mem[w_addrb]; // stage 1 - ENB-gated
        w_dout_r2 <= w_dout_r1;                   // stage 2 - REGCEB=1 -> always
    end
    assign w_doutb = w_dout_r2;

    //==========================================================================
    // Behavioral: bram_c1_to_c2
    //   - 64-bit x 2048 words with byte-write enable (wea[7:0]).
    //   - DUT writes via Port A; TB verifies contents directly after wdone.
    //   - No Port B pipeline needed: we read c1c2_mem[] directly in the TB.
    //==========================================================================
    reg [63:0] c1c2_mem [0:2047];

    integer ci_init;
    initial begin
        for (ci_init = 0; ci_init < 2048; ci_init = ci_init + 1)
            c1c2_mem[ci_init] = 64'h0;
    end

    always @(posedge clk) begin
        if (c1c2_we) begin
            if (c1c2_wea[0]) c1c2_mem[c1c2_addr][ 7: 0] <= c1c2_din[ 7: 0];
            if (c1c2_wea[1]) c1c2_mem[c1c2_addr][15: 8] <= c1c2_din[15: 8];
            if (c1c2_wea[2]) c1c2_mem[c1c2_addr][23:16] <= c1c2_din[23:16];
            if (c1c2_wea[3]) c1c2_mem[c1c2_addr][31:24] <= c1c2_din[31:24];
            if (c1c2_wea[4]) c1c2_mem[c1c2_addr][39:32] <= c1c2_din[39:32];
            if (c1c2_wea[5]) c1c2_mem[c1c2_addr][47:40] <= c1c2_din[47:40];
            if (c1c2_wea[6]) c1c2_mem[c1c2_addr][55:48] <= c1c2_din[55:48];
            if (c1c2_wea[7]) c1c2_mem[c1c2_addr][63:56] <= c1c2_din[63:56];
        end
    end

    //==========================================================================
    // DUT
    //==========================================================================
    conv1_engine dut (
        .clk          (clk),
        .rst          (rst),
        .start        (start),
        .done         (done),

        // 4-way handshake
        .prior_wdone  (prior_wdone),
        .succ_rdone   (succ_rdone),
        .rdone        (rdone),
        .wdone        (wdone),

        // bram_input Port B
        .in_bram_addr (in_addrb),
        .in_bram_en   (in_enb),
        .in_bram_dout (in_doutb),

        // conv1_weight_bram Port B
        .w_bram_addr  (w_addrb),
        .w_bram_en    (w_enb),
        .w_bram_dout  (w_doutb),

        // bram_c1_to_c2 Port A
        .c1c2_we      (c1c2_we),
        .c1c2_wea     (c1c2_wea),
        .c1c2_addr    (c1c2_addr),
        .c1c2_din     (c1c2_din)
    );

    //==========================================================================
    // Expected output  (1024 entries, bank 0)
    //==========================================================================
    reg [63:0] expected_c1c2 [0:1023];

    //==========================================================================
    // Cycle counter
    //==========================================================================
    integer cycle_cnt;
    integer cycle_at_prior_wdone, cycle_at_rdone, cycle_at_wdone;

    initial cycle_cnt = 0;
    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    // capture rdone timestamp asynchronously
    always @(posedge rdone) cycle_at_rdone = cycle_cnt;

    //==========================================================================
    // Main stimulus
    //==========================================================================
    integer i, mismatches;
    integer mm_ch0, mm_ch1, mm_ch2, mm_ch3;
    integer mm_ch4, mm_ch5, mm_ch6, mm_ch7;
    reg [63:0] got, exp;

    initial begin
        $display("[TB] === Conv1 single-image bit-exact test (dohyun branch) ===");

        // ---- 0. Load data files into behavioral memories ----
        $display("[TB] Loading input    : %s", `CONV1_INPUT_HEX);
        $readmemh(`CONV1_INPUT_HEX,    in_mem);
        $display("[TB] Loading weights  : %s", `CONV1_WEIGHT_HEX);
        $readmemh(`CONV1_WEIGHT_HEX,   w_mem);
        $display("[TB] Loading expected : %s", `CONV1_EXPECTED_HEX);
        $readmemh(`CONV1_EXPECTED_HEX, expected_c1c2);

        // ---- 1. Reset (active-high, hold 10 cycles) ----
        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        // ---- 2. prior_wdone 1-cycle pulse ----
        //   FSM: data_ready = (prior_diff_next < 0) = (-1 < 0) = 1
        //        output_avail = (after_diff_next < 2) = (0 < 2) = 1
        //   -> IDLE -> LOAD at the posedge where prior_wdone is sampled
        @(negedge clk);
        prior_wdone          = 1'b1;
        cycle_at_prior_wdone = cycle_cnt;
        @(negedge clk);
        prior_wdone          = 1'b0;
        $display("[TB] @ cycle %0d : prior_wdone pulsed (FSM IDLE->LOAD)", cycle_at_prior_wdone);

        // ---- 3. Wait for wdone (c1c2 write complete) ----
        @(posedge wdone);
        cycle_at_wdone = cycle_cnt;
        $display("[TB] @ cycle %0d : wdone received  (rdone was @ cycle %0d)",
                 cycle_at_wdone, cycle_at_rdone);

        // ---- 4. Settle a few cycles (last write committed to c1c2_mem) ----
        repeat (5) @(posedge clk);

        // ---- 5. Compare c1c2_mem bank 0 (addr 0..1023) vs expected ----
        //   64-bit word layout:
        //     [7:0]  =ch0(oc0)  [15:8] =ch1(oc1)  [23:16]=ch2(oc2)  [31:24]=ch3(oc3)  <- Round0
        //     [39:32]=ch4(oc4)  [47:40]=ch5(oc5)  [55:48]=ch6(oc6)  [63:56]=ch7(oc7)  <- Round1
        mismatches = 0;
        mm_ch0 = 0; mm_ch1 = 0; mm_ch2 = 0; mm_ch3 = 0;
        mm_ch4 = 0; mm_ch5 = 0; mm_ch6 = 0; mm_ch7 = 0;

        $display("[TB] Comparing c1c2_mem[0..1023] vs expected ...");
        for (i = 0; i < 1024; i = i + 1) begin
            got = c1c2_mem[i];
            exp = expected_c1c2[i];
            if (got !== exp) begin
                mismatches = mismatches + 1;

                // per-channel mismatch count
                if (got[ 7: 0] !== exp[ 7: 0]) mm_ch0 = mm_ch0 + 1;
                if (got[15: 8] !== exp[15: 8]) mm_ch1 = mm_ch1 + 1;
                if (got[23:16] !== exp[23:16]) mm_ch2 = mm_ch2 + 1;
                if (got[31:24] !== exp[31:24]) mm_ch3 = mm_ch3 + 1;
                if (got[39:32] !== exp[39:32]) mm_ch4 = mm_ch4 + 1;
                if (got[47:40] !== exp[47:40]) mm_ch5 = mm_ch5 + 1;
                if (got[55:48] !== exp[55:48]) mm_ch6 = mm_ch6 + 1;
                if (got[63:56] !== exp[63:56]) mm_ch7 = mm_ch7 + 1;

                // 첫 10개 상세 출력
                if (mismatches <= 10) begin
                    $display("  MISMATCH @ addr=%4d row=%2d col=%2d",
                             i, i / 32, i % 32);
                    if (got[ 7: 0] !== exp[ 7: 0])
                        $display("    ch0(oc0): got=0x%02h(%4d)  exp=0x%02h(%4d)",
                                 got[ 7: 0], $signed(got[ 7: 0]),
                                 exp[ 7: 0], $signed(exp[ 7: 0]));
                    if (got[15: 8] !== exp[15: 8])
                        $display("    ch1(oc1): got=0x%02h(%4d)  exp=0x%02h(%4d)",
                                 got[15: 8], $signed(got[15: 8]),
                                 exp[15: 8], $signed(exp[15: 8]));
                    if (got[23:16] !== exp[23:16])
                        $display("    ch2(oc2): got=0x%02h(%4d)  exp=0x%02h(%4d)",
                                 got[23:16], $signed(got[23:16]),
                                 exp[23:16], $signed(exp[23:16]));
                    if (got[31:24] !== exp[31:24])
                        $display("    ch3(oc3): got=0x%02h(%4d)  exp=0x%02h(%4d)",
                                 got[31:24], $signed(got[31:24]),
                                 exp[31:24], $signed(exp[31:24]));
                    if (got[39:32] !== exp[39:32])
                        $display("    ch4(oc4): got=0x%02h(%4d)  exp=0x%02h(%4d)",
                                 got[39:32], $signed(got[39:32]),
                                 exp[39:32], $signed(exp[39:32]));
                    if (got[47:40] !== exp[47:40])
                        $display("    ch5(oc5): got=0x%02h(%4d)  exp=0x%02h(%4d)",
                                 got[47:40], $signed(got[47:40]),
                                 exp[47:40], $signed(exp[47:40]));
                    if (got[55:48] !== exp[55:48])
                        $display("    ch6(oc6): got=0x%02h(%4d)  exp=0x%02h(%4d)",
                                 got[55:48], $signed(got[55:48]),
                                 exp[55:48], $signed(exp[55:48]));
                    if (got[63:56] !== exp[63:56])
                        $display("    ch7(oc7): got=0x%02h(%4d)  exp=0x%02h(%4d)",
                                 got[63:56], $signed(got[63:56]),
                                 exp[63:56], $signed(exp[63:56]));
                end
            end
        end
        if (mismatches > 10)
            $display("  ... (%0d more mismatches suppressed)", mismatches - 10);

        // ---- 6. Final report ----
        $display("");
        $display("================================================");
        $display("  Conv1 single-image testbench result");
        $display("================================================");
        $display("  prior_wdone  @ cycle %0d", cycle_at_prior_wdone);
        $display("  rdone        @ cycle %0d", cycle_at_rdone);
        $display("  wdone        @ cycle %0d", cycle_at_wdone);
        $display("  compute      : %0d cycles", cycle_at_wdone - cycle_at_prior_wdone);
        $display("  mismatches   : %0d / 1024", mismatches);
        $display("  --- per-channel mismatches ---");
        $display("  Round0: ch0=%0d  ch1=%0d  ch2=%0d  ch3=%0d",
                 mm_ch0, mm_ch1, mm_ch2, mm_ch3);
        $display("  Round1: ch4=%0d  ch5=%0d  ch6=%0d  ch7=%0d",
                 mm_ch4, mm_ch5, mm_ch6, mm_ch7);
        if (mismatches == 0)
            $display("  *** PASS *** (bit-exact match)");
        else
            $display("  *** FAIL ***");
        $display("================================================");

        $finish;
    end

    //==========================================================================
    // Timeout  (200 us = 20000 cycles; conv1 needs ~1650 cycles)
    //==========================================================================
    initial begin
        #200000;
        $display("[TB] !!! TIMEOUT @ cycle %0d  - wdone never asserted !!!", cycle_cnt);
        $finish;
    end

    //==========================================================================
    // Optional VCD dump
    //==========================================================================
    initial begin
        $dumpfile("tb_conv1_engine.vcd");
        $dumpvars(0, tb_conv1_engine);
    end

endmodule
