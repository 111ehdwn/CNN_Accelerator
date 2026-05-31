`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_engine
// Description:
//   FC layer engine for channel-major packed input.
//
//   Handshake (conv2 패턴 정합):
//     prior_wdone : maxpool 의 wdone direct wire (입력 image 준비 알림)
//     rdone       : FC 가 poolfc bank read 완료 1-cycle pulse
//     input_bank_sel : 내부 toggle FF, rdone 시 토글 (ping-pong)
//     start       : legacy system arm pulse (init 용 backup, 이후 handshake 자동)
//   FC 는 terminal layer 이므로 output 측 handshake (succ_rdone, wdone, output_bank_sel)
//   없음. argmax 결과는 class_idx / class_valid 로 직출.
//
//   Input BRAM (poolfc):
//     width = 128-bit = 16ch * 8-bit
//     depth = 512 = 2 bank * 256 (144 만 유효, 나머지 padding)
//     addr  = {input_bank_sel, s_cnt[7:0]}   — maxpool 의 write 포맷과 일치
//     one address contains all 16 channels for the same spatial position
//
//   Weight BRAM:
//     width = 256-bit
//     depth = 720 = 5 output-pairs * 144 spatial
//     addr = pair_cnt * 144 + s_cnt
//     [127:0]   : even output column weights, 16ch
//     [255:128] : odd  output column weights, 16ch
//
//   BRAM read latency:
//     input BRAM  = 1 cycle
//     weight BRAM = 1 cycle
//////////////////////////////////////////////////////////////////////////////////

module fc_engine #(
    parameter ACC_W = 24
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         start,

    //==========================================================================
    // FC weight BRAM Port A
    // 256-bit x 720, addr = pair*144 + spatial
    //==========================================================================
    input  wire         fcw_ena,
    input  wire [9:0]   fcw_addra,
    input  wire [255:0] fcw_dina,

    //==========================================================================
    // poolfc buffer read port
    //   128-bit × 512 (2 bank × 256), 1-cycle read latency.
    //   addr = {input_bank_sel, s_cnt[7:0]} — bank=0: 0..143, bank=1: 256..399.
    //==========================================================================
    output wire         poolfc_re,
    output wire [8:0]   poolfc_addr,         // {input_bank_sel, s_cnt[7:0]}
    input  wire [127:0] poolfc_dout,

    //==========================================================================
    // Handshake for ping-pong buffer
    //==========================================================================
    input  wire         prior_wdone,
    output wire         rdone,

    //==========================================================================
    // Result
    //==========================================================================
    output wire [3:0]   class_idx,
    output wire         class_valid
);

    //==========================================================================
    // 1. FSM
    //==========================================================================
    wire [7:0] fsm_s_cnt;
    wire [2:0] fsm_pair_cnt;
    wire [9:0] fsm_wbase;
    wire       fsm_comp_v;
    wire       fsm_s_first;
    wire       fsm_s_last;
    wire       fsm_busy;
    wire       fsm_input_bank_sel;

    fc_fsm fsm_inst (
        .clk            (clk),
        .rst            (rst),
        .start          (start),
        .prior_wdone    (prior_wdone),
        .rdone          (rdone),
        .input_bank_sel (fsm_input_bank_sel),
        .s_cnt          (fsm_s_cnt),
        .pair_cnt       (fsm_pair_cnt),
        .wbase          (fsm_wbase),
        .comp_v         (fsm_comp_v),
        .s_first        (fsm_s_first),
        .s_last         (fsm_s_last),
        .busy           (fsm_busy)
    );

    //==========================================================================
    // 2. Input BRAM address (poolfc)
    //
    //   Bank format: {bank_sel, s_cnt[7:0]} — 9-bit, top bit = bank.
    //     bank=0 : addr {0, 0}..{0, 143} = 0..143
    //     bank=1 : addr {1, 0}..{1, 143} = 256..399
    //
    //   ★ maxpool 의 poolfc_wr_addr = {output_bank_sel, out_addr[7:0]} 와 동일 포맷.
    //   이전엔 `(bank ? (144 + s_cnt) : s_cnt)` 였는데 (144..287) maxpool 의 write
    //   range (256..399) 와 mismatch → bank 1 read 시 빈 영역에서 0 만 읽음.
    //==========================================================================
    assign poolfc_re   = fsm_comp_v;
    assign poolfc_addr = {fsm_input_bank_sel, fsm_s_cnt};

    //==========================================================================
    // 3. Weight BRAM, 256-bit x 720, 1-cycle read latency
    //==========================================================================
    wire [9:0]   fcw_addrb = fsm_wbase + {2'd0, fsm_s_cnt};
    wire [255:0] fcw_doutb;

    fc_weight_bram fcw_bmg_inst (
        .clka   (clk),
        .ena    (fcw_ena),                 // ★ ENA + WEA 둘 다 결선 필수
        .wea    (fcw_ena),                 //   (conv2_weight_bram 의 ENA 누락 버그와 동일 원인 예방)
        .addra  (fcw_addra),
        .dina   (fcw_dina),

        .clkb   (clk),
        .enb    (fsm_comp_v),
        .addrb  (fcw_addrb),
        .doutb  (fcw_doutb)
    );

    // User-defined packing:
    //   MSB side = odd column  16 weights
    //   LSB side = even column 16 weights
    wire [127:0] w_even_flat = fcw_doutb[127:0];
    wire [127:0] w_odd_flat  = fcw_doutb[255:128];

    //==========================================================================
    // 4. Valid/control alignment
    //
    // PE 는 공용 core/pe_cell (DSP 3-stage + 출력 reg = 4-cycle latency).
    // Timeline for an issued spatial word at cycle T (BRAM L=1):
    //   T+1 : BRAM doutb valid           — PE x/packed_w inputs valid (combinational)
    //   T+2 : DSP A/B latch              — pe_en @ T+1 = 1 필요
    //   T+3 : DSP M latch                — pe_en @ T+2 = 1 필요
    //   T+4 : DSP P latch                — pe_en @ T+3 = 1 필요
    //   T+5 : PE 출력 reg (mul0/mul1)    — pe_en @ T+4 = 1 필요
    //   T+6 : adder stage1 reg (e1)      — adder_en @ T+5 = 1 필요
    //   T+7 : adder stage2 reg (e2)
    //   T+8 : adder stage3 reg (e3)
    //   T+9 : adder stage4 reg (sum0/1)  — adder_en @ T+8 = 1 필요
    //   T+10: accumulator update         — acc_en @ T+9 = 1 필요
    //
    // comp_pipe[k] @ cycle C = fsm_comp_v @ cycle (C-k-1) (1-cycle 등록 지연부터).
    // 따라서 (index k = X-(T+1)):
    //   pe_en    = comp_pipe[0] | comp_pipe[1] | comp_pipe[2]
    //                          | comp_pipe[3]                    (covers T+1..T+4)
    //   adder_en = comp_pipe[4] | comp_pipe[5] | comp_pipe[6]
    //                          | comp_pipe[7]                    (covers T+5..T+8)
    //   acc_en/clear/last/pair = *_pipe[8]                       (covers T+9)
    //
    // 주의: accumulator 의 logit 캡처는 "acc + sum" 형태로 마지막 spatial 포함.
    // (RTL/fc/fc_accumulator.v 의 last=1 branch 참조; sp(last) 가 acc0_OLD 에
    //  아직 없을 때도 combinational add 로 logit 에 반영.)
    //==========================================================================
    localparam CTRL_DELAY = 8;

    reg [CTRL_DELAY:0] comp_pipe;
    reg [CTRL_DELAY:0] first_pipe;
    reg [CTRL_DELAY:0] last_pipe;
    reg [2:0]          pair_pipe [0:CTRL_DELAY];

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            comp_pipe  <= {(CTRL_DELAY+1){1'b0}};
            first_pipe <= {(CTRL_DELAY+1){1'b0}};
            last_pipe  <= {(CTRL_DELAY+1){1'b0}};
            for (k = 0; k <= CTRL_DELAY; k = k + 1)
                pair_pipe[k] <= 3'd0;
        end else begin
            comp_pipe[0]  <= fsm_comp_v;
            first_pipe[0] <= fsm_s_first;
            last_pipe[0]  <= fsm_s_last;
            pair_pipe[0]  <= fsm_pair_cnt;

            for (k = 1; k <= CTRL_DELAY; k = k + 1) begin
                comp_pipe[k]  <= comp_pipe[k-1];
                first_pipe[k] <= first_pipe[k-1];
                last_pipe[k]  <= last_pipe[k-1];
                pair_pipe[k]  <= pair_pipe[k-1];
            end
        end
    end

    wire pe_en    = comp_pipe[0] | comp_pipe[1] | comp_pipe[2] | comp_pipe[3];
    wire adder_en = comp_pipe[4] | comp_pipe[5] | comp_pipe[6] | comp_pipe[7];

    wire       acc_en    = comp_pipe [CTRL_DELAY];
    wire       acc_clear = first_pipe[CTRL_DELAY];
    wire       acc_last  = last_pipe [CTRL_DELAY];
    wire [2:0] acc_pair  = pair_pipe [CTRL_DELAY];

    //==========================================================================
    // 5. SIMD PE array: 16 lanes, each lane produces even/odd product
    //==========================================================================
    wire [255:0] p_even_flat;
    wire [255:0] p_odd_flat;

    fc_pe_array pe_inst (
        .clk    (clk),
        .rst    (rst),
        .en     (pe_en),
        .x_flat (poolfc_dout),
        .w0_flat(w_even_flat),
        .w1_flat(w_odd_flat),
        .p0_flat(p_even_flat),
        .p1_flat(p_odd_flat)
    );

    //==========================================================================
    // 6. 16-channel adder tree for even/odd output columns
    //==========================================================================
    wire signed [19:0] sum_even;
    wire signed [19:0] sum_odd;

    fc_adder_tree adder_inst (
        .clk    (clk),
        .rst    (rst),
        .en     (adder_en),
        .p0_flat(p_even_flat),
        .p1_flat(p_odd_flat),
        .sum0   (sum_even),
        .sum1   (sum_odd)
    );

    //==========================================================================
    // 7. Accumulator
    //==========================================================================
    wire signed [ACC_W-1:0] logit_even_acc;
    wire signed [ACC_W-1:0] logit_odd_acc;
    wire                    logit_valid;

    fc_accumulator #(.ACC_W(ACC_W)) acc_inst (
        .clk        (clk),
        .rst        (rst),
        .en         (acc_en),
        .clear      (acc_clear),
        .last       (acc_last),
        .sum0       (sum_even),
        .sum1       (sum_odd),
        .logit0     (logit_even_acc),
        .logit1     (logit_odd_acc),
        .logit_valid(logit_valid)
    );

    //==========================================================================
    // 8. Logit collection
    //
    // acc_pair = pair_pipe[CTRL_DELAY] 는 logit_valid 가 출력되는 사이클(T+1)에
    // 이미 다음 pair 값으로 시프트되어 있다.
    // acc_last pulse 가 뜨는 사이클(T)의 acc_pair 가 진짜 현재 pair 이므로
    // 그 값을 래치하여 logit_reg 인덱스로 사용한다.
    //==========================================================================
    reg signed [ACC_W-1:0] logit_reg [0:9];
    reg [2:0] acc_pair_latch;

    always @(posedge clk) begin
        if (rst)
            acc_pair_latch <= 3'd0;
        else if (acc_en && acc_last)
            acc_pair_latch <= acc_pair;
    end

    integer oc;
    always @(posedge clk) begin
        if (rst) begin
            for (oc = 0; oc < 10; oc = oc + 1)
                logit_reg[oc] <= {ACC_W{1'b0}};
        end else if (logit_valid) begin
            logit_reg[{1'b0, acc_pair_latch} * 2    ] <= logit_even_acc;
            logit_reg[{1'b0, acc_pair_latch} * 2 + 1] <= logit_odd_acc;
        end
    end

    wire [10*ACC_W-1:0] logit_flat;

    genvar gi;
    generate
        for (gi = 0; gi < 10; gi = gi + 1) begin : flat_pack
            assign logit_flat[gi*ACC_W +: ACC_W] = logit_reg[gi];
        end
    endgenerate

    // Last pair write is visible to argmax on the next cycle.
    reg all_ready;
    always @(posedge clk) begin
        if (rst)
            all_ready <= 1'b0;
        else
            all_ready <= logit_valid && (acc_pair_latch == 3'd4);
    end

    //==========================================================================
    // 9. Argmax
    //==========================================================================
    fc_argmax #(.ACC_W(ACC_W)) argmax_inst (
        .clk       (clk),
        .rst       (rst),
        .in_valid  (all_ready),
        .logit_flat(logit_flat),
        .class_idx (class_idx),
        .done      (class_valid)
    );

endmodule