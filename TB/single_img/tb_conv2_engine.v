`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_conv2_engine.v
// Single-image bit-exact testbench for conv2_engine  (uses real conv2_weight_bram BMG IP)
//
//   Weight init: TB 의 init_weight() task 가 576 cycle 동안 Port A 의 c2w_ena/addra/dina
//                를 driving 하여 실제 PS 동작 emulation. (BMG IP 내부 mem path 에 의존
//                하지 않으므로 IP 버전 변경에 영향 없음.)
//   자극 sequence: reset → init_weight() → start → prior_wdone → wait wdone → compare.
//////////////////////////////////////////////////////////////////////////////////

// 절대 경로 (Windows 경로지만 forward slash 사용 — Verilog string 안전).
`define CONV1_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_output_c1c2.hex"
`define CONV2_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_output_c2pool.hex"
`define WEIGHT_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_weights_simd.hex"


//////////////////////////////////////////////////////////////////////////////////
// Main testbench
//////////////////////////////////////////////////////////////////////////////////
module tb_conv2_engine;

    //==========================================================================
    // Clock / reset (180 MHz)
    //==========================================================================
    reg clk = 1'b0;
    reg rst = 1'b1;

    always #2.78 clk = ~clk;   // 5.56 ns period

    //==========================================================================
    // DUT 시그널
    //==========================================================================
    reg          start       = 1'b0;

    // Conv2 weight Port A — TB 가 init_weight task 로 driving
    reg          c2w_ena     = 1'b0;
    reg  [9:0]   c2w_addra   = 10'd0;
    reg  [31:0]  c2w_dina    = 32'd0;

    // c1c2 BRAM Port B (behavioral 모델)
    wire         c1c2_re;
    wire [10:0]  c1c2_addr;
    wire [63:0]  c1c2_dout;

    // c2pool BRAM Port A (behavioral 모델)
    wire         c2pool_we;
    wire [10:0]  c2pool_addr;
    wire [127:0] c2pool_din;

    // Handshake
    reg          prior_wdone = 1'b0;
    wire         rdone;
    reg          succ_rdone  = 1'b0;
    wire         wdone;

    //==========================================================================
    // Behavioral c1c2 BRAM (L=2 SDP, 64-bit × 2048 entries)
    //   addr = {bank_sel, row[4:0], col[4:0]}; ENA=REGCE=c1c2_re
    //==========================================================================
    reg [63:0] c1c2_mem    [0:2047];
    reg [63:0] c1c2_core;
    reg [63:0] c1c2_outreg;

    initial begin
        c1c2_core   = 64'h0;
        c1c2_outreg = 64'h0;
    end

    always @(posedge clk) begin
        if (c1c2_re) begin
            c1c2_core   <= c1c2_mem[c1c2_addr];
            c1c2_outreg <= c1c2_core;
        end
    end

    assign c1c2_dout = c1c2_outreg;

    //==========================================================================
    // Behavioral c2pool BRAM (write only from engine; testbench reads after wdone)
    //==========================================================================
    reg [127:0] c2pool_mem [0:2047];

    integer ci_init;
    initial begin
        for (ci_init = 0; ci_init < 2048; ci_init = ci_init + 1)
            c2pool_mem[ci_init] = 128'h0;
    end

    always @(posedge clk) begin
        if (c2pool_we) c2pool_mem[c2pool_addr] <= c2pool_din;
    end

    //==========================================================================
    // TB-local weight memory (init_weight task 가 여기서 읽어 Port A 로 driving)
    //==========================================================================
    reg [31:0] weight_mem [0:575];

    //==========================================================================
    // Expected c2pool output (for comparison)
    //==========================================================================
    reg [127:0] expected_c2pool [0:575];

    //==========================================================================
    // DUT 인스턴스 (실제 BMG IP `conv2_weight_bram` 사용)
    //==========================================================================
    conv2_engine dut (
        .clk         (clk),
        .rst         (rst),
        .start       (start),

        .c2w_ena     (c2w_ena),
        .c2w_addra   (c2w_addra),
        .c2w_dina    (c2w_dina),

        .c1c2_re     (c1c2_re),
        .c1c2_addr   (c1c2_addr),
        .c1c2_dout   (c1c2_dout),

        .c2pool_we   (c2pool_we),
        .c2pool_addr (c2pool_addr),
        .c2pool_din  (c2pool_din),

        .prior_wdone (prior_wdone),
        .rdone       (rdone),
        .succ_rdone  (succ_rdone),
        .wdone       (wdone)
    );

    //==========================================================================
    // Cycle counter
    //==========================================================================
    integer cycle_cnt;
    integer cycle_at_init_done, cycle_at_start, cycle_at_prior_wdone, cycle_at_wdone;

    initial cycle_cnt = 0;
    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Task: init_weight  (Port A 로 576 cycle 동안 weight write)
    //   reset 해제 후, start 펄스 전에 호출.
    //   실제 PS 가 AXI BRAM Ctrl 로 conv2_weight_bram 에 write 하는 동작 emulation.
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
            cycle_at_init_done = cycle_cnt;
            $display("[TB] @ cycle %0d : init_weight done", cycle_at_init_done);
        end
    endtask

    //==========================================================================
    // 자극 + 비교
    //==========================================================================
    integer i;
    integer mismatches;
    integer addr;
    reg [127:0] got;
    reg [127:0] exp;

    initial begin
        // ---- 0. memory 초기화
        $display("[TB] === Conv2 single-image bit-exact test ===");
        $display("[TB] Loading c1c2 BRAM : %s", `CONV1_HEX);
        $readmemh(`CONV1_HEX, c1c2_mem);   // 1024 lines → mem[0..1023] (bank 0)
        for (i = 1024; i < 2048; i = i + 1) c1c2_mem[i] = 64'h0;

        $display("[TB] Loading weight   : %s", `WEIGHT_HEX);
        $readmemh(`WEIGHT_HEX, weight_mem);   // TB local mem, init_weight 가 사용

        $display("[TB] Loading expected : %s", `CONV2_HEX);
        $readmemh(`CONV2_HEX, expected_c2pool);

        // ---- 1. Reset
        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        // ---- 2. init_weight (Port A 로 576 cycle 동안 weight write)
        init_weight();

        // ---- 3. start pulse (LOAD_WEIGHTS 진입)
        @(negedge clk);
        start = 1'b1;
        cycle_at_start = cycle_cnt;
        @(negedge clk);
        start = 1'b0;
        $display("[TB] @ cycle %0d : start pulsed", cycle_at_start);

        // ---- 4. prior_wdone pulse (data_ready=true)
        @(negedge clk);
        prior_wdone = 1'b1;
        cycle_at_prior_wdone = cycle_cnt;
        @(negedge clk);
        prior_wdone = 1'b0;
        $display("[TB] @ cycle %0d : prior_wdone pulsed", cycle_at_prior_wdone);

        // ---- 5. wdone 기다리기 (engine 가 처리 완료)
        @(posedge wdone);
        cycle_at_wdone = cycle_cnt;
        $display("[TB] @ cycle %0d : wdone received", cycle_at_wdone);

        // ---- 6. 추가 cycle 대기 (safety)
        repeat (5) @(posedge clk);

        // ---- 7. c2pool BRAM bank 0 vs expected 비교
        mismatches = 0;
        $display("[TB] Comparing c2pool[0..575] vs expected ...");
        for (addr = 0; addr < 576; addr = addr + 1) begin
            got = c2pool_mem[addr];
            exp = expected_c2pool[addr];
            if (got !== exp) begin
                mismatches = mismatches + 1;
                if (mismatches <= 10) begin
                    $display("  MISMATCH @ addr %0d (h=%0d w=%0d) : got=%h, exp=%h",
                             addr, addr/24, addr%24, got, exp);
                end
            end
        end

        // ---- 8. 최종 report
        $display("");
        $display("================================================");
        $display("  Conv2 single-image testbench result");
        $display("================================================");
        $display("  init_weight done @ cycle %0d", cycle_at_init_done);
        $display("  start             @ cycle %0d", cycle_at_start);
        $display("  prior_wdone       @ cycle %0d", cycle_at_prior_wdone);
        $display("  wdone             @ cycle %0d", cycle_at_wdone);
        $display("  compute (start→wdone) : %0d cycles", cycle_at_wdone - cycle_at_start);
        $display("  total  (rst→wdone)    : %0d cycles", cycle_at_wdone);
        $display("  mismatches            : %0d / 576", mismatches);
        if (mismatches == 0)
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
        $display("");
        $display("[TB] !!! TIMEOUT @ cycle %0d — engine 가 wdone 을 emit 하지 않음 !!!",
                 cycle_cnt);
        $finish;
    end

    initial begin
        $dumpfile("tb_conv2_engine.vcd");
        $dumpvars(0, tb_conv2_engine);
    end

endmodule
