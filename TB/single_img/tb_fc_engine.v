`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_fc_engine.v
// Single-image bit-exact testbench for fc_engine (conv2-pattern alignment).
//
//   Pipeline emul:
//     TB poolfc_mem (behavioral, bank=0 에 image data) → FC Engine → argmax
//     TB PS-write   → fc_weight_bram (behavioral, 720 entries)
//
//   Handshake (new conv2-pattern):
//     start       : system arm pulse — init 1회만 (이후 image 는 handshake 자동)
//     prior_wdone : image trigger pulse (= maxpool.wdone direct wire emul)
//     rdone       : FC 가 image read 완료 — 모니터링만
//     class_valid : argmax 결과 ready — 1-cycle pulse
//
//   Bank format (new):
//     poolfc_addr = {input_bank_sel, s_cnt[7:0]}   ← maxpool 의 write 포맷과 일치
//       bank=0 : addr 0..143
//       bank=1 : addr 256..399
//     단일 image TB 는 bank=0 만 사용 (FSM 의 input_bank_sel reset=0).
//
//   Verification:
//     1. 10 OC logits (24-bit signed) per pair — pre-argmax 정확성.
//     2. argmax class_idx (= 5, expected).
//
//   Data files:
//     POOLFC_HEX  : maxpool_output.hex   (2304 byte, channel-major flatten)
//     FCW_HEX     : fc_weights_simd.hex  (11520 line × 32-bit SIMD-packed)
//////////////////////////////////////////////////////////////////////////////////

// 데이터 경로는 다른 TB(tb_conv1_conv2_maxpool_multi 등)와 동일 베이스로 통일.
//   C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/
`define POOLFC_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/maxpool_output.hex"
`define FCW_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/fc_weights_simd.hex"


module tb_fc_engine;

    parameter ACC_W      = 24;
    parameter CLK_PERIOD = 10;

    //==========================================================================
    // Expected logits (24-bit signed, Python reference)
    //   class_idx = argmax = OC5 (= 9565)
    //==========================================================================
    localparam signed [23:0] EXP_OC0 = 24'h00010B;  //   267
    localparam signed [23:0] EXP_OC1 = 24'hFFF885;  // -1915
    localparam signed [23:0] EXP_OC2 = 24'h000AF9;  //  2809
    localparam signed [23:0] EXP_OC3 = 24'h001ABC;  //  6844
    localparam signed [23:0] EXP_OC4 = 24'hFFED99;  // -4711
    localparam signed [23:0] EXP_OC5 = 24'h00255D;  //  9565   ← max
    localparam signed [23:0] EXP_OC6 = 24'h00067A;  //  1658
    localparam signed [23:0] EXP_OC7 = 24'h001231;  //  4657
    localparam signed [23:0] EXP_OC8 = 24'h000D6B;  //  3435
    localparam signed [23:0] EXP_OC9 = 24'h000D7A;  //  3450

    localparam       [3:0]   EXP_CLS = 4'd5;

    //==========================================================================
    // Clock / reset (active-high rst, 시스템 통일)
    //==========================================================================
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(CLK_PERIOD/2) clk = ~clk;

    //==========================================================================
    // DUT signals
    //==========================================================================
    reg          start        = 1'b0;       // system arm pulse (init 1회)
    reg          prior_wdone  = 1'b0;       // image trigger (maxpool emul)
    wire         rdone;
    wire [3:0]   class_idx;
    wire         class_valid;

    // Weight BMG Port A (TB 가 PS-style sequential write)
    reg          fcw_ena      = 1'b0;
    reg  [9:0]   fcw_addra    = 10'd0;
    reg  [255:0] fcw_dina     = 256'd0;

    // poolfc (TB-local behavioral mem)
    wire         poolfc_re;
    wire [8:0]   poolfc_addr;              // {input_bank_sel, s_cnt[7:0]}
    reg  [127:0] poolfc_dout  = 128'd0;

    //==========================================================================
    // DUT
    //==========================================================================
    fc_engine #(.ACC_W(ACC_W)) dut (
        .clk         (clk),
        .rst         (rst),
        .start       (start),

        .fcw_ena     (fcw_ena),
        .fcw_addra   (fcw_addra),
        .fcw_dina    (fcw_dina),

        .poolfc_re   (poolfc_re),
        .poolfc_addr (poolfc_addr),
        .poolfc_dout (poolfc_dout),

        .prior_wdone (prior_wdone),
        .rdone       (rdone),

        .class_idx   (class_idx),
        .class_valid (class_valid)
    );

    //==========================================================================
    // poolfc behavioral mem
    //
    //   New bank format: {input_bank_sel, s_cnt[7:0]}
    //     bank=0 : addrs 0..143  ← 단일 image TB 가 채우는 영역
    //     bank=1 : addrs 256..399 (멀티 image TB 용, 여기서는 0 유지)
    //
    //   Source (maxpool_output.hex) 는 channel-major byte flatten:
    //     line c*144 + s = byte at channel c, spatial s.
    //   TB 가 spatial-major 128-bit word 로 재조립.
    //==========================================================================
    reg [7:0]   poolfc_byte_mem [0:2303];
    reg [127:0] poolfc_mem      [0:511];

    initial begin : poolfc_init
        integer s, c;
        // 전체 0 초기화 (bank 1 영역 포함)
        for (s = 0; s < 512; s = s + 1)
            poolfc_mem[s] = 128'd0;

        $readmemh(`POOLFC_HEX, poolfc_byte_mem, 0, 2303);
        $display("[TB] %s loaded (%0d bytes)", `POOLFC_HEX, 2304);

        // bank 0 (addrs 0..143): channel-major → spatial-major 128-bit
        for (s = 0; s < 144; s = s + 1) begin
            for (c = 0; c < 16; c = c + 1) begin
                poolfc_mem[s][c*8 +: 8] = poolfc_byte_mem[c*144 + s];
            end
        end
    end

    // poolfc BMG behavioral (L=1)
    always @(posedge clk) begin
        if (poolfc_re)
            poolfc_dout <= poolfc_mem[poolfc_addr];
    end

    //==========================================================================
    // Weight loader task (PS-style sequential write, 720 entries)
    //
    //   fc_weights_simd.hex 포맷:
    //     11520 line × 32-bit SIMD-packed (W1*2^17 + W0)
    //     line index = pair*144*16 + s*16 + c
    //
    //   SIMD unpack (DSP48E1 packing 의 inverse):
    //     W0 (8-bit signed) = packed[7:0]
    //     W1 (8-bit signed) = packed[24:17] + (packed[16] ? 1 : 0)   ← carry correction
    //
    //   BMG 256-bit dina:
    //     dina[127:0]   = {w0_ch15, ..., w0_ch0}    (even OC, 16ch packed)
    //     dina[255:128] = {w1_ch15, ..., w1_ch0}    (odd  OC, 16ch packed)
    //==========================================================================
    reg [31:0] weight_simd_mem [0:11519];

    task load_weights;
        integer pair, s, c, line_idx;
        reg signed [7:0]  w0, w1;
        reg signed [16:0] w0_packed_17;
        reg signed [7:0]  w1_packed_8;
        reg [127:0]       w_even_concat, w_odd_concat;
        begin
            $readmemh(`FCW_HEX, weight_simd_mem);
            $display("[TB] %s loaded (%0d entries)", `FCW_HEX, 11520);

            for (pair = 0; pair < 5; pair = pair + 1) begin
                for (s = 0; s < 144; s = s + 1) begin
                    w_even_concat = 128'd0;
                    w_odd_concat  = 128'd0;
                    for (c = 0; c < 16; c = c + 1) begin
                        line_idx     = pair*144*16 + s*16 + c;
                        w0_packed_17 = $signed(weight_simd_mem[line_idx][16:0]);
                        w1_packed_8  = $signed(weight_simd_mem[line_idx][24:17]);
                        w0 = w0_packed_17[7:0];
                        w1 = w1_packed_8 + (w0_packed_17[16] ? 8'sd1 : 8'sd0);
                        w_even_concat[c*8 +: 8] = w0;
                        w_odd_concat [c*8 +: 8] = w1;
                    end
                    @(negedge clk);
                    fcw_ena   = 1'b1;
                    fcw_addra = pair * 144 + s;
                    fcw_dina  = {w_odd_concat, w_even_concat};
                end
            end
            @(negedge clk);
            fcw_ena   = 1'b0;
            fcw_addra = 10'd0;
            fcw_dina  = 256'd0;
            $display("[TB] Weight BRAM write done (720 entries)");
        end
    endtask

    //==========================================================================
    // Cycle counter (log readability)
    //==========================================================================
    integer cycle_cnt = 0;
    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Verification taps
    //==========================================================================
    wire                    logit_valid_w = dut.logit_valid;
    wire [2:0]              acc_pair_w    = dut.acc_pair_latch;

    // logit_reg 가 logit_valid 다음 edge 에 latch 되므로 1-cycle 지연 후 read.
    reg                     lv_d1   = 1'b0;
    reg [2:0]               pair_d1 = 3'd0;
    always @(posedge clk) begin
        lv_d1   <= logit_valid_w;
        pair_d1 <= acc_pair_w;
    end

    wire signed [ACC_W-1:0] lr [0:9];
    assign lr[0] = dut.logit_reg[0]; assign lr[1] = dut.logit_reg[1];
    assign lr[2] = dut.logit_reg[2]; assign lr[3] = dut.logit_reg[3];
    assign lr[4] = dut.logit_reg[4]; assign lr[5] = dut.logit_reg[5];
    assign lr[6] = dut.logit_reg[6]; assign lr[7] = dut.logit_reg[7];
    assign lr[8] = dut.logit_reg[8]; assign lr[9] = dut.logit_reg[9];

    integer pass_cnt      = 0;
    integer fail_cnt      = 0;
    integer pair_done_cnt = 0;

    task check_pair;
        input [3:0]   oc_even, oc_odd;
        input signed [23:0] got0, got1, exp0, exp1;
        reg pass0, pass1;
        begin
            pass0 = (got0 === exp0);
            pass1 = (got1 === exp1);
            $display("---------------------------------------------------------");
            $display("[LOGIT] OC%0d / OC%0d  @ cyc=%0d", oc_even, oc_odd, cycle_cnt);
            if (pass0) begin
                $display("  OC%0d : PASS  %0d (0x%06H)", oc_even, $signed(got0), got0);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  OC%0d : FAIL  got=%0d (0x%06H), exp=%0d (0x%06H), diff=%0d",
                    oc_even, $signed(got0), got0, $signed(exp0), exp0,
                    $signed(got0) - $signed(exp0));
                fail_cnt = fail_cnt + 1;
            end
            if (pass1) begin
                $display("  OC%0d : PASS  %0d (0x%06H)", oc_odd, $signed(got1), got1);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  OC%0d : FAIL  got=%0d (0x%06H), exp=%0d (0x%06H), diff=%0d",
                    oc_odd, $signed(got1), got1, $signed(exp1), exp1,
                    $signed(got1) - $signed(exp1));
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (lv_d1) begin
            pair_done_cnt = pair_done_cnt + 1;
            case (pair_d1)
                3'd0: check_pair(0, 1, lr[0][23:0], lr[1][23:0], EXP_OC0, EXP_OC1);
                3'd1: check_pair(2, 3, lr[2][23:0], lr[3][23:0], EXP_OC2, EXP_OC3);
                3'd2: check_pair(4, 5, lr[4][23:0], lr[5][23:0], EXP_OC4, EXP_OC5);
                3'd3: check_pair(6, 7, lr[6][23:0], lr[7][23:0], EXP_OC6, EXP_OC7);
                3'd4: check_pair(8, 9, lr[8][23:0], lr[9][23:0], EXP_OC8, EXP_OC9);
                default: $display("[WARN] unexpected pair_d1=%0d", pair_d1);
            endcase
        end
    end

    //==========================================================================
    // FSM state monitor
    //==========================================================================
    reg [1:0] prev_state = 2'd0;
    always @(posedge clk) begin
        if (!rst && dut.fsm_inst.state !== prev_state) begin
            case (dut.fsm_inst.state)
                2'd0: $display("[FSM] cyc=%0d : IDLE",    cycle_cnt);
                2'd1: $display("[FSM] cyc=%0d : COMPUTE", cycle_cnt);
                2'd2: $display("[FSM] cyc=%0d : DRAIN",   cycle_cnt);
                2'd3: $display("[FSM] cyc=%0d : DONE",    cycle_cnt);
            endcase
        end
        prev_state <= dut.fsm_inst.state;
    end

    //==========================================================================
    // Handshake event monitor
    //==========================================================================
    always @(posedge clk) begin
        if (!rst) begin
            if (rdone)
                $display("[DBG H] cyc=%0d : fc.rdone (image read 완료)", cycle_cnt);
            if (class_valid)
                $display("[DBG H] cyc=%0d : fc.class_valid pulsed — class_idx=%0d",
                         cycle_cnt, class_idx);
        end
    end

    //==========================================================================
    // Main sequence
    //==========================================================================
    integer timeout_cnt;
    initial begin : main
        $display("============================================================");
        $display("[TB] tb_fc_engine — single-image bit-exact verification");
        $display("     ACC_W=%0d, CLK_PERIOD=%0d ns", ACC_W, CLK_PERIOD);
        $display("     Handshake: start (arm) + prior_wdone (image trigger)");
        $display("     Bank format: poolfc_addr = {input_bank_sel, s_cnt[7:0]}");
        $display("============================================================");

        rst = 1'b1;
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        $display("[TB] cyc=%0d : reset released", cycle_cnt);

        // 1. Load weights (PS-side write to fc_weight_bram)
        load_weights();
        repeat (3) @(posedge clk);

        // 2. System arm pulse — conv1 / maxpool 패턴: 첫 image 진입 전 한 번.
        //    이후 image 는 prior_wdone 만으로 자동 진행 (FSM 의 ready_to_compute).
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        $display("[TB] cyc=%0d : start pulsed (system arm, init 1회)", cycle_cnt);

        // 3. Image trigger pulse (= 실제 시스템에서는 maxpool.wdone direct wire)
        @(negedge clk); prior_wdone = 1'b1;
        @(negedge clk); prior_wdone = 1'b0;
        $display("[TB] cyc=%0d : prior_wdone pulsed (image trigger)", cycle_cnt);

        // 4. Wait for class_valid (= 처리 종료 + argmax 결과 ready)
        timeout_cnt = 0;
        while (!class_valid && timeout_cnt < 1000) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end

        if (!class_valid) begin
            $display("[TB] *** TIMEOUT *** class_valid never asserted in 1000 cycles");
            fail_cnt = fail_cnt + 1;
        end
        repeat (5) @(posedge clk);

        // 5. Final report
        $display("============================================================");
        $display("[FINAL]");
        $display("  pair_done_cnt   = %0d / 5", pair_done_cnt);
        $display("  logit pass/fail = %0d / %0d  (10 OC total)", pass_cnt, fail_cnt);
        $display("  class_idx       = %0d (expected %0d) — %s",
                 class_idx, EXP_CLS, (class_idx == EXP_CLS) ? "PASS" : "FAIL");
        $display("------------------------------------------------------------");
        if (fail_cnt == 0 && pair_done_cnt == 5 && class_idx == EXP_CLS)
            $display("[FINAL] *** ALL PASS *** (logits bit-exact + argmax correct)");
        else
            $display("[FINAL] *** FAIL ***");
        $display("============================================================");
        $finish;
    end

    //==========================================================================
    // VCD dump
    //==========================================================================
    initial begin
        $dumpfile("tb_fc_engine.vcd");
        $dumpvars(0, tb_fc_engine);
    end

endmodule


//==============================================================================
// fc_weight_bram behavioral model
//   Simple Dual-Port, 256-bit × 1024 (BMG spec depth; 720 entries 사용).
//   Port A: write only — ENA + WEA 둘 다 결선 필요 (실제 BMG 거동과 일치).
//   Port B: read with L=1 (Primitive Output Register Disable).
//
//   ★ Vivado 프로젝트에 실제 fc_weight_bram BMG IP 가 있으면 이 module 을
//     주석 처리하거나 다른 파일로 분리하세요 (duplicate 정의 충돌 방지).
//==============================================================================
module fc_weight_bram (
    input  wire         clka,
    input  wire         ena,
    input  wire         wea,
    input  wire [9:0]   addra,
    input  wire [255:0] dina,

    input  wire         clkb,
    input  wire         enb,
    input  wire [9:0]   addrb,
    output reg  [255:0] doutb
);
    reg [255:0] mem [0:1023];

    integer mi;
    initial begin
        for (mi = 0; mi < 1024; mi = mi + 1) mem[mi] = 256'd0;
        doutb = 256'd0;
    end

    always @(posedge clka) begin
        if (ena && wea) mem[addra] <= dina;
    end

    always @(posedge clkb) begin
        if (enb) doutb <= mem[addrb];
    end
endmodule
