`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Single-image bit-exact testbench for conv2_engine
//
//   Flow:
//     0. Pre-init conv2_weight_bram (BMG behavioral) via $readmemh (576 entries)
//     1. Pre-init c1c2 BRAM bank 0 via $readmemh (1024 entries, 64-bit each)
//     2. Load expected c2pool output (576 entries, 128-bit each)
//     3. Reset, then pulse `start` (LOAD_WEIGHTS 진입)
//     4. Pulse `prior_wdone` (data_ready=true; image data is already loaded)
//     5. Wait for `wdone` (engine finished)
//     6. Compare c2pool BRAM bank 0 [0..575] with expected
//     7. PASS/FAIL report (first 10 mismatch detail 출력)
//
//   주의:
//     - `conv2_weight_bram` 의 behavioral 모델이 본 file 안에 정의됨 (sim only).
//       Vivado synthesis 시에는 실제 BMG IP 가 같은 이름으로 교체됨.
//     - `pe_cell.v` 가 DSP48E1 primitive 사용 → Xilinx unisim library 필요.
//       권장: Vivado XSIM. (iverilog/verilator 는 DSP48E1 stub 필요.)
//     - hex file path 는 `+define+HEX_PATH=...` 로 override 가능. 기본값은
//       프로젝트 root 에서 sim 실행 가정 (`data/hex_layer_by_layer`, `data/weights_simd`).
//////////////////////////////////////////////////////////////////////////////////

// 절대 경로 (Windows 경로지만 forward slash 사용 — Verilog string 안전).
// Hex 파일 위치 변경 시 아래 3 define 만 수정.
`define CONV1_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_output_c1c2.hex"
`define CONV2_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_output_c2pool.hex"
`define WEIGHT_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_weights_simd.hex"


//////////////////////////////////////////////////////////////////////////////////
// Behavioral model of conv2_weight_bram BMG IP (simulation only)
//
//   - SDP, common clock, 32-bit dual port, depth 1024 (576 entries used)
//   - Port A: write only (testbench 가 직접 mem 에 $readmemh 로 init)
//   - Port B: read with L=2 (core + output reg, REGCEB 상수 1 가정)
//
//   Synthesis 시 Vivado 가 생성한 IP wrapper 와 같은 module name 으로 교체.
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

    initial begin
        core  = 32'h0;
        doutb = 32'h0;
    end

    // Port A: write
    always @(posedge clka) begin
        if (wea) mem[addra] <= dina;
    end

    // Port B: read with L=2 (ENA=enb, REGCE=regceb)
    always @(posedge clkb) begin
        if (enb)    core  <= mem[addrb];
        if (regceb) doutb <= core;
    end
endmodule


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

    // Conv2 weight Port A (testbench 는 pre-init 만 함; c2w_ena 는 0 유지)
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
    // Expected c2pool output (for comparison)
    //==========================================================================
    reg [127:0] expected_c2pool [0:575];

    //==========================================================================
    // DUT 인스턴스
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
    // Cycle counter (debug / 결과 reporting 용)
    //==========================================================================
    integer cycle_cnt;
    integer cycle_at_start, cycle_at_prior_wdone, cycle_at_wdone;

    initial cycle_cnt = 0;
    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

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
        $readmemh(`WEIGHT_HEX, dut.c2w_bmg_inst.mem);  // 576 lines

        $display("[TB] Loading expected : %s", `CONV2_HEX);
        $readmemh(`CONV2_HEX, expected_c2pool);

        // ---- 1. Reset
        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        $display("[TB] @ cycle %0d: reset released", cycle_cnt);

        // ---- 2. start pulse (LOAD_WEIGHTS 진입)
        @(negedge clk);
        start = 1'b1;
        cycle_at_start = cycle_cnt;
        @(negedge clk);
        start = 1'b0;
        $display("[TB] @ cycle %0d: start pulsed", cycle_at_start);

        // ---- 3. prior_wdone pulse (data_ready=true)
        //   LOAD_WEIGHTS 동안 어디서 pulse 해도 OK. FSM 의 prior_diff 가 -1 되어
        //   data_ready=true 가 됨. DONE 진입 시 즉시 PIPELINE_FILL 로 전환.
        @(negedge clk);
        prior_wdone = 1'b1;
        cycle_at_prior_wdone = cycle_cnt;
        @(negedge clk);
        prior_wdone = 1'b0;
        $display("[TB] @ cycle %0d: prior_wdone pulsed", cycle_at_prior_wdone);

        // ---- 4. wdone 기다리기 (engine 가 처리 완료)
        @(posedge wdone);
        cycle_at_wdone = cycle_cnt;
        $display("[TB] @ cycle %0d: wdone received", cycle_at_wdone);

        // ---- 5. 추가 cycle 대기 (safety)
        repeat (5) @(posedge clk);

        // ---- 6. c2pool BRAM bank 0 vs expected 비교
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

        // ---- 7. 최종 report
        $display("");
        $display("================================================");
        $display("  Conv2 single-image testbench result");
        $display("================================================");
        $display("  start         @ cycle %0d", cycle_at_start);
        $display("  prior_wdone   @ cycle %0d", cycle_at_prior_wdone);
        $display("  wdone         @ cycle %0d", cycle_at_wdone);
        $display("  compute total : %0d cycles (start → wdone)", cycle_at_wdone - cycle_at_start);
        $display("  mismatches    : %0d / 576", mismatches);
        if (mismatches == 0)
            $display("  *** PASS *** (bit-exact match)");
        else
            $display("  *** FAIL ***");
        $display("================================================");

        $finish;
    end

    //==========================================================================
    // Timeout (engine 가 stall 시 sim 무한 hang 방지)
    //==========================================================================
    initial begin
        #200000;   // 200 μs = clk 36000+ cycle. 2 image 처리 분량보다 큼.
        $display("");
        $display("[TB] !!! TIMEOUT @ cycle %0d — engine 가 wdone 을 emit 하지 않음 !!!",
                 cycle_cnt);
        $finish;
    end

    //==========================================================================
    // Optional: waveform dump (for debug)
    //==========================================================================
    initial begin
        $dumpfile("tb_conv2_engine.vcd");
        $dumpvars(0, tb_conv2_engine);
    end

endmodule
