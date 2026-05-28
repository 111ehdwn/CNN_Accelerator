`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_fc_engine (수정판)
//
// 원본 대비 변경사항:
//   1. poolfc 버퍼: 1-cycle latency로 단순화
//   2. fc_weight_bram: 256-bit × 720으로 수정, regceb 제거
//   3. load_weights: 720번 loop, 256-bit씩 write ({odd, even})
//   4. hex 파일 형식:
//      - maxpool_output.hex    : 288 lines × 32 hex chars (128-bit per entry)
//          entry s = {ch15,..,ch0} where ch0=[7:0]
//          bank0: s=0..143, bank1: s=144..287 (동일 데이터)
//      - fc1_weight_bram.hex   : 1440 lines × 32 hex chars (128-bit per entry)
//          entry 2*(pair*144+s)+0 = even OC weights ch0..15
//          entry 2*(pair*144+s)+1 = odd  OC weights ch0..15
//          load시 두 entry씩 합쳐 256-bit로 기록
//////////////////////////////////////////////////////////////////////////////////

module tb_fc_engine;

    //==========================================================================
    // 파라미터
    //==========================================================================
    parameter ACC_W      = 24;
    parameter CLK_PERIOD = 10;

    //==========================================================================
    // 기대 logit
    //==========================================================================
    localparam [23:0] EXP_OC0 = 24'h00010B;  //   267
    localparam [23:0] EXP_OC1 = 24'hFFF885;  // -1915
    localparam [23:0] EXP_OC2 = 24'h000AF9;  //  2809
    localparam [23:0] EXP_OC3 = 24'h001ABC;  //  6844
    localparam [23:0] EXP_OC4 = 24'hFFED99;  // -4711
    localparam [23:0] EXP_OC5 = 24'h00255D;  //  9565
    localparam [23:0] EXP_OC6 = 24'h00067A;  //  1658
    localparam [23:0] EXP_OC7 = 24'h001231;  //  4657
    localparam [23:0] EXP_OC8 = 24'h000D6B;  //  3435
    localparam [23:0] EXP_OC9 = 24'h000D7A;  //  3450

    //==========================================================================
    // 클럭 / 리셋
    //==========================================================================
    reg clk = 0;
    reg rst = 1;
    always #(CLK_PERIOD/2) clk = ~clk;

    //==========================================================================
    // DUT 포트
    //==========================================================================
    reg          start_r     = 0;
    reg          fcw_ena     = 0;
    reg  [9:0]   fcw_addra   = 0;
    reg  [255:0] fcw_dina    = 0;
    wire         poolfc_re;
    wire [9:0]   poolfc_addr;
    reg  [127:0] poolfc_dout = 128'd0;
    reg          prior_wdone = 0;
    wire         rdone;
    wire [3:0]   class_idx;
    wire         class_valid;

    fc_engine #(.ACC_W(ACC_W)) dut (
        .clk(clk), .rst(rst), .start(start_r),
        .fcw_ena(fcw_ena), .fcw_addra(fcw_addra), .fcw_dina(fcw_dina),
        .poolfc_re(poolfc_re), .poolfc_addr(poolfc_addr), .poolfc_dout(poolfc_dout),
        .prior_wdone(prior_wdone), .rdone(rdone),
        .class_idx(class_idx), .class_valid(class_valid)
    );

    //==========================================================================
    // poolfc 버퍼 (288 entries × 128-bit, 1-cycle latency)
    // hex: 288 lines, 한 줄 = 32 hex chars = 128-bit
    // [ch*8+:8] = channel ch (ch0=[7:0], ch15=[127:120])
    //==========================================================================
    reg [127:0] poolfc_mem [0:287];

    initial begin
        $readmemh("maxpool_output.hex", poolfc_mem, 0, 287);
        $display("[TB] maxpool_output.hex loaded");
    end

    always @(posedge clk) begin
        if (poolfc_re)
            poolfc_dout <= poolfc_mem[poolfc_addr];
    end

    //==========================================================================
    // Weight BRAM 로드
    // fc1_weight_bram.hex: 1440 lines × 128-bit
    //   line 2k   = even OC weights (pair=k/144, s=k%144), ch0..15
    //   line 2k+1 = odd  OC weights
    // 720번 write, 한 번에 256-bit: dina = {odd_128b, even_128b}
    //==========================================================================
    reg [127:0] weight_init_mem [0:1439];

    task load_weights;
        integer i;
        begin
            $readmemh("fc1_weight_bram.hex", weight_init_mem);
            $display("[TB] fc1_weight_bram.hex loaded");
            // 256-bit씩 720번 write
            for (i = 0; i < 720; i = i + 1) begin
                @(negedge clk);
                fcw_ena   = 1;
                fcw_addra = i[9:0];
                // MSB = odd weights, LSB = even weights
                fcw_dina  = {weight_init_mem[i*2+1], weight_init_mem[i*2]};
            end
            @(negedge clk); fcw_ena = 0; fcw_addra = 0; fcw_dina = 0;
            @(posedge clk);
            $display("[TB] Weight BRAM write done");
        end
    endtask

    //==========================================================================
    // 내부 신호 tap
    //==========================================================================
    wire                    logit_valid_w = dut.logit_valid;
    wire [2:0]              acc_pair_w    = dut.acc_pair_latch;  // latch된 pair 사용

    wire signed [ACC_W-1:0] lr [0:9];
    assign lr[0] = dut.logit_reg[0]; assign lr[1] = dut.logit_reg[1];
    assign lr[2] = dut.logit_reg[2]; assign lr[3] = dut.logit_reg[3];
    assign lr[4] = dut.logit_reg[4]; assign lr[5] = dut.logit_reg[5];
    assign lr[6] = dut.logit_reg[6]; assign lr[7] = dut.logit_reg[7];
    assign lr[8] = dut.logit_reg[8]; assign lr[9] = dut.logit_reg[9];

    //==========================================================================
    // 검증
    //==========================================================================
    integer pair_done_cnt = 0;
    integer pass_cnt      = 0;
    integer fail_cnt      = 0;

    reg       lv_d1   = 0;
    reg [2:0] pair_d1 = 0;
    always @(posedge clk) begin
        lv_d1   <= logit_valid_w;
        pair_d1 <= acc_pair_w;
    end

    task check_pair;
        input [3:0]  oc_even;
        input [3:0]  oc_odd;
        input [23:0] got0, got1;
        input [23:0] exp0, exp1;
        reg pass0, pass1;
        begin
            pass0 = (got0 === exp0);
            pass1 = (got1 === exp1);
            $display("------------------------------------------------------------");
            $display("[LOGIT] OC%0d / OC%0d  @ %0t ns", oc_even, oc_odd, $time);
            if (pass0) begin
                $display("  OC%0d : PASS  %0d  (0x%06H)", oc_even, $signed(got0), got0);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  OC%0d : FAIL  got=%0d (0x%06H)  exp=%0d (0x%06H)  diff=%0d",
                    oc_even, $signed(got0), got0, $signed(exp0), exp0,
                    $signed(got0) - $signed(exp0));
                fail_cnt = fail_cnt + 1;
            end
            if (pass1) begin
                $display("  OC%0d : PASS  %0d  (0x%06H)", oc_odd, $signed(got1), got1);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  OC%0d : FAIL  got=%0d (0x%06H)  exp=%0d (0x%06H)  diff=%0d",
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
                default:
                    $display("[WARN] unexpected pair_d1=%0d @ %0t ns", pair_d1, $time);
            endcase
        end
    end

    //==========================================================================
    // FSM 모니터
    //==========================================================================
    reg [1:0] prev_state = 2'd0;
    always @(posedge clk) begin
        if (dut.fsm_inst.state !== prev_state) begin
            case (dut.fsm_inst.state)
                2'd0: $display("[FSM] IDLE    @ %0t ns", $time);
                2'd1: $display("[FSM] COMPUTE @ %0t ns", $time);
                2'd2: $display("[FSM] DRAIN   @ %0t ns", $time);
                2'd3: $display("[FSM] DONE    @ %0t ns", $time);
            endcase
            prev_state <= dut.fsm_inst.state;
        end
    end

    reg [2:0] prev_pair_mon = 3'd7;
    always @(posedge clk) begin
        if (dut.fsm_inst.state == 2'd1 &&
            dut.fsm_pair_cnt !== prev_pair_mon) begin
            $display("[FSM] pair=%0d started  wbase=%0d  @ %0t ns",
                      dut.fsm_pair_cnt, dut.fsm_wbase, $time);
            prev_pair_mon <= dut.fsm_pair_cnt;
        end
    end

    //==========================================================================
    // 메인 시퀀스
    //==========================================================================
    integer timeout_cnt;

    initial begin
        $display("============================================================");
        $display("[TB] fc_engine — logit verification (pre-argmax)");
        $display("     ACC_W=%0d, CLK_PERIOD=%0d ns", ACC_W, CLK_PERIOD);
        $display("============================================================");

        rst = 1;
        repeat(5) @(posedge clk);
        @(negedge clk); rst = 0;
        $display("[TB] Reset released @ %0t ns", $time);

        load_weights();
        repeat(3) @(posedge clk);

        @(negedge clk); prior_wdone = 1;
        @(negedge clk); prior_wdone = 0;
        @(negedge clk); start_r = 1;
        @(negedge clk); start_r = 0;
        $display("[TB] Start issued @ %0t ns", $time);

        timeout_cnt = 0;
        while (pair_done_cnt < 5 && timeout_cnt < 25000) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        repeat(5) @(posedge clk);

        $display("============================================================");
        if (timeout_cnt >= 25000)
            $display("[TIMEOUT] pair_done=%0d/5", pair_done_cnt);
        else
            $display("[INFO] 5 pairs completed in %0d cycles", timeout_cnt);

        $display("  PASS : %0d / 10", pass_cnt);
        $display("  FAIL : %0d / 10", fail_cnt);
        $display("------------------------------------------------------------");
        if (fail_cnt == 0 && pair_done_cnt == 5)
            $display("[FINAL] *** ALL PASS *** logit values correct (pre-argmax)");
        else if (fail_cnt > 0)
            $display("[FINAL] *** FAIL *** logit mismatch");
        else
            $display("[FINAL] *** INCOMPLETE *** pair 미완료");
        $display("============================================================");
        $finish;
    end

    initial begin
        $dumpfile("tb_fc_engine.vcd");
        $dumpvars(0, tb_fc_engine);
    end

endmodule


//==============================================================================
// fc_weight_bram 수정 모델
// Simple Dual-Port, 256-bit × 720, 1-cycle read latency
//
// Write: wea=1, addra[9:0], dina[255:0] → mem[addra] = dina
//   dina[127:0]  = even OC weights (ch0..15)
//   dina[255:128] = odd  OC weights (ch0..15)
//
// Read: enb=1, addrb[9:0] → 다음 사이클 doutb[255:0] 유효
//   doutb[127:0]  = even OC weights
//   doutb[255:128] = odd  OC weights
//==============================================================================
module fc_weight_bram (
    input  wire         clka,
    input  wire         wea,
    input  wire [9:0]   addra,
    input  wire [255:0] dina,

    input  wire         clkb,
    input  wire         enb,
    input  wire [9:0]   addrb,
    output reg  [255:0] doutb
);
    reg [255:0] mem [0:719];

    integer mi;
    initial begin
        for (mi = 0; mi < 720; mi = mi + 1) mem[mi] = 256'd0;
        doutb = 256'd0;
    end

    always @(posedge clka) begin
        if (wea) mem[addra] <= dina;
    end

    always @(posedge clkb) begin
        if (enb) doutb <= mem[addrb];
    end
endmodule