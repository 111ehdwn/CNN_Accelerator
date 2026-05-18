`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: Testbench
//   - top_memory_ctrlr 전체에 대한 testbench (BRAM1, BRAM2, sobel_ip 통합 검증)
//   - PS 동작 시뮬레이션:
//       (1) image_in.mem을 읽어 BRAM1.PortB로 한 픽셀씩 write
//       (2) start 펄스 → done wait
//       (3) BRAM2.PortB로 한 픽셀씩 read → image_out_ref.mem과 비교
//   - 결과는 console로 PASS/FAIL 출력
//   - waveform : Vivado 자동 dump (XSIM)
//////////////////////////////////////////////////////////////////////////////////

module Testbench;

    // ============================================================
    // Clock / Reset
    // ============================================================
    reg clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    reg resetn = 0;

    // ============================================================
    // DUT control
    // ============================================================
    reg  start = 0;
    wire done;

    // ============================================================
    // BRAM1 Port B (input image write 용)
    // ============================================================
    reg         b1_enb   = 0;
    reg         b1_web   = 0;
    reg  [13:0] b1_addrb = 0;
    reg  [7:0]  b1_dinb  = 0;
    wire [7:0]  b1_doutb;

    // ============================================================
    // BRAM2 Port B (output image read 용)
    // ============================================================
    reg         b2_enb   = 0;
    reg         b2_web   = 0;
    reg  [13:0] b2_addrb = 0;
    reg  [7:0]  b2_dinb  = 0;
    wire [7:0]  b2_doutb;

    // ============================================================
    // DUT instantiation
    // ============================================================
    top_memory_ctrlr dut(
        .clk      (clk),
        .resetn   (resetn),
        .start    (start),
        .done     (done),

        // BRAM1 Port B
        .b1_clkb  (clk),
        .b1_enb   (b1_enb),
        .b1_web   (b1_web),
        .b1_addrb (b1_addrb),
        .b1_dinb  (b1_dinb),
        .b1_doutb (b1_doutb),

        // BRAM2 Port B
        .b2_clkb  (clk),
        .b2_enb   (b2_enb),
        .b2_web   (b2_web),
        .b2_addrb (b2_addrb),
        .b2_dinb  (b2_dinb),
        .b2_doutb (b2_doutb)
    );

    // ============================================================
    // Image data buffers (testbench-internal)
    // ============================================================
    reg [7:0] image_in  [0:10403];   // 102 * 102
    reg [7:0] image_ref [0:9999];    // 100 * 100
    reg [7:0] image_got [0:9999];

    // ============================================================
    // Main test
    // ============================================================
    integer i;
    integer mismatch_count;
    integer mismatch_print;

    initial begin
        // -------- Load test vectors from files --------
        $readmemh("image_in.mem",      image_in);
        $readmemh("image_out_ref.mem", image_ref);
        $display("[%0t] Loaded image_in.mem and image_out_ref.mem", $time);

        // -------- Reset --------
        resetn = 1'b0;
        start  = 1'b0;
        b1_enb = 1'b0; b1_web = 1'b0; b1_addrb = 0; b1_dinb = 0;
        b2_enb = 1'b0; b2_web = 1'b0; b2_addrb = 0; b2_dinb = 0;
        repeat (10) @(posedge clk);
        resetn = 1'b1;
        repeat (5) @(posedge clk);
        $display("[%0t] Reset released", $time);

        // -------- Stage 1: Write input image to BRAM1 via Port B --------
        $display("[%0t] Stage 1: Writing %0d input pixels to BRAM1...", $time, 10404);
        for (i = 0; i < 10404; i = i + 1) begin
            @(negedge clk);
            b1_enb   = 1'b1;
            b1_web   = 1'b1;
            b1_addrb = i[13:0];
            b1_dinb  = image_in[i];
        end
        @(negedge clk);
        b1_enb = 1'b0;
        b1_web = 1'b0;
        b1_addrb = 0;
        b1_dinb  = 0;
        $display("[%0t] Stage 1 done. BRAM1 fully loaded.", $time);
        repeat (5) @(posedge clk);

        // -------- Stage 2: Issue start pulse (1 cycle) --------
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        $display("[%0t] Stage 2: start pulse issued, waiting for done...", $time);

        // -------- Stage 3: Wait for done --------
        wait (done == 1'b1);
        $display("[%0t] Stage 3: DONE asserted", $time);
        repeat (10) @(posedge clk);

        // -------- Stage 4: Read result from BRAM2 via Port B --------
        $display("[%0t] Stage 4: Reading %0d output pixels from BRAM2...", $time, 10000);
        for (i = 0; i < 10000; i = i + 1) begin
            @(negedge clk);
            b2_enb   = 1'b1;
            b2_web   = 1'b0;
            b2_addrb = i[13:0];

            // BRAM read latency = 1 cycle, so doutb of cycle when addrb=i
            // is captured at the *next* posedge.
            @(posedge clk);
            #1; // settle
            image_got[i] = b2_doutb;
        end
        @(negedge clk);
        b2_enb = 1'b0;
        $display("[%0t] Stage 4 done. All %0d pixels read.", $time, 10000);

        // -------- Stage 5: Compare with reference --------
        mismatch_count = 0;
        mismatch_print = 0;
        for (i = 0; i < 10000; i = i + 1) begin
            if (image_got[i] !== image_ref[i]) begin
                mismatch_count = mismatch_count + 1;
                if (mismatch_print < 20) begin
                    $display("  MISMATCH addr=%0d  (row=%0d,col=%0d)  expected=%02x  got=%02x",
                             i, i/100, i%100, image_ref[i], image_got[i]);
                    mismatch_print = mismatch_print + 1;
                end
            end
        end

        $display("");
        $display("============================================");
        if (mismatch_count == 0)
            $display("  PASS : all 10000 output pixels match.");
        else
            $display("  FAIL : %0d / 10000 mismatches.", mismatch_count);
        $display("============================================");
        $display("");

        // -------- Optional: dump first 10 outputs for inspection --------
        $display("First 10 outputs (got vs ref):");
        for (i = 0; i < 10; i = i + 1)
            $display("  addr=%0d  got=%02x  ref=%02x  %s",
                     i, image_got[i], image_ref[i],
                     (image_got[i] === image_ref[i]) ? "OK" : "MISMATCH");

        $finish;
    end

    // ============================================================
    // Watchdog
    // ============================================================
    initial begin
        #10_000_000;  // 10 ms
        $display("!!! TIMEOUT !!!");
        $finish;
    end

endmodule