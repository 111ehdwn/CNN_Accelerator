`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Description:
//
//   ★ 구조 요약:
//     fc_simd_fsm        : pair 0~4 순차, spatial 0~287 scan (1440 COMPUTE cycle)
//     fc_simd_pe_array   : 16 DSP SIMD (1 pair × 8 ch)
//     fc_simd_adder_tree : 16:1 × 2 OC (4-stage)
//     fc_simd_accumulator: 2 OC 누산 → pair 완료 시 logit0/1 pulse
//     [logit_reg 10개]   : engine 내부 레지스터 (logit 수집)
//     fc_simd_argmax     : 10 logit 동시 비교 (1 cycle)
//
//   ★ Pipeline depth: BRAM 2 + pe 2 + adder 4 + acc 1 = 9  (ACC_DELAY = 8)
//
//   ★ Weight BRAM: 128-bit × 1440
//     addr = pair*288 + s  (pair 0~4, s 0~287)
//     [63:0]   = w0 (OC_even 8ch)
//     [127:64] = w1 (OC_odd  8ch)
//
//   ★ DSP: 16개 (20개 제약 이내)
//////////////////////////////////////////////////////////////////////////////////

module fc_engine #(
    parameter ACC_W = 24
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         start,

    //==========================================================================
    // FC weight BRAM Port A (PS write)
    // 128-bit × 1440, addr = pair*288 + spatial
    //==========================================================================
    input  wire         fcw_ena,
    input  wire [10:0]  fcw_addra,   // 0..1439
    input  wire [127:0] fcw_dina,

    //==========================================================================
    // poolfc buffer (read, L=2)
    //==========================================================================
    output wire         poolfc_re,
    output wire [9:0]   poolfc_addr,
    input  wire [127:0] poolfc_dout,

    //==========================================================================
    // Handshake for pingpong
    //==========================================================================
    input  wire         prior_wdone,
    output wire         rdone,

    //==========================================================================
    // 결과
    //==========================================================================
    output wire [3:0]   class_idx,
    output wire         class_valid
);

    //==========================================================================
    // 1. FSM
    //==========================================================================
    wire [8:0] fsm_s_cnt;
    wire [2:0] fsm_pair_cnt;
    wire [10:0] fsm_wbase;
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
    // 2. Read enable 연장 (BRAM L=2 drain)
    //==========================================================================
    reg rd_v_d1, rd_v_d2, rd_v_d3;
    always @(posedge clk) begin
        if (rst) begin
            rd_v_d1 <= 0; rd_v_d2 <= 0; rd_v_d3 <= 0;
        end else begin
            rd_v_d1 <= fsm_comp_v;
            rd_v_d2 <= rd_v_d1;
            rd_v_d3 <= rd_v_d2;
        end
    end
    wire rd_en_ext = fsm_comp_v | rd_v_d1 | rd_v_d2 | rd_v_d3;

    assign poolfc_re   = rd_en_ext;
    assign poolfc_addr = {fsm_input_bank_sel, fsm_s_cnt[8:0]};

    //==========================================================================
    // 3. Weight BRAM (128-bit × 1440)
    //==========================================================================
    wire [10:0]  fcw_addrb = fsm_wbase + {2'd0, fsm_s_cnt};
    wire [127:0] fcw_doutb;

    fc_weight_bram fcw_bmg_inst (
        .clka   (clk),
        .wea    (fcw_ena),
        .addra  (fcw_addra),
        .dina   (fcw_dina),

        .clkb   (clk),
        .enb    (rd_en_ext),
        .addrb  (fcw_addrb),
        .doutb  (fcw_doutb),
        .regceb (rd_en_ext)
    );

    wire [63:0] w0_flat = fcw_doutb[ 63:  0];   // OC_even 8ch
    wire [63:0] w1_flat = fcw_doutb[127: 64];   // OC_odd  8ch

    //==========================================================================
    // 4. PE enable 정렬 (BRAM L=2)
    //==========================================================================
    reg rd_en_d1, rd_en_d2;
    always @(posedge clk) begin
        if (rst) begin
            rd_en_d1 <= 0; rd_en_d2 <= 0;
        end else begin
            rd_en_d1 <= rd_en_ext;
            rd_en_d2 <= rd_en_d1;
        end
    end

    //==========================================================================
    // 5. SIMD PE array (16 DSP)
    //==========================================================================
    wire [255:0] p0_flat;
    wire [255:0] p1_flat;

    fc_pe_array pe_inst (
        .clk    (clk),
        .rst    (rst),
        .en     (rd_en_d2),
        .x_flat (poolfc_dout),
        .w0_flat(w0_flat),
        .w1_flat(w1_flat),
        .p0_flat(p0_flat),
        .p1_flat(p1_flat)
    );

    //==========================================================================
    // 6. Adder tree (2 OC 병렬, 4-stage)
    //   PE latency=2 → rd_en_d2 를 2 더 지연
    //==========================================================================
    reg rd_en_d3, rd_en_d4;
    always @(posedge clk) begin
        if (rst) begin
            rd_en_d3 <= 0; rd_en_d4 <= 0;
        end else begin
            rd_en_d3 <= rd_en_d2;
            rd_en_d4 <= rd_en_d3;
        end
    end

    wire signed [19:0] sum0;
    wire signed [19:0] sum1;

    fc_adder_tree adder_inst (
        .clk    (clk),
        .rst    (rst),
        .en     (rd_en_d4),
        .p0_flat(p0_flat),
        .p1_flat(p1_flat),
        .sum0   (sum0),
        .sum1   (sum1)
    );

    //==========================================================================
    // 7. Accumulator control 정렬
    //   FSM issue T → sum valid @ T+8  (BRAM2 + PE2 + adder4)
    //   acc_en/clear/last = FSM strobe 를 8-cycle 지연
    //   pair_cnt 도 같이 지연 → logit 저장 슬롯 결정
    //==========================================================================
    localparam ACC_DELAY = 8;

    reg [ACC_DELAY-1:0] comp_v_pipe;
    reg [ACC_DELAY-1:0] first_pipe;
    reg [ACC_DELAY-1:0] last_pipe;
    reg [2:0]           pair_pipe [0:ACC_DELAY-1];

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            comp_v_pipe <= 0;
            first_pipe  <= 0;
            last_pipe   <= 0;
            for (k = 0; k < ACC_DELAY; k = k + 1)
                pair_pipe[k] <= 3'd0;
        end else begin
            comp_v_pipe[0] <= fsm_comp_v;
            first_pipe[0]  <= fsm_s_first;
            last_pipe[0]   <= fsm_s_last;
            pair_pipe[0]   <= fsm_pair_cnt;
            for (k = 1; k < ACC_DELAY; k = k + 1) begin
                comp_v_pipe[k] <= comp_v_pipe[k-1];
                first_pipe[k]  <= first_pipe[k-1];
                last_pipe[k]   <= last_pipe[k-1];
                pair_pipe[k]   <= pair_pipe[k-1];
            end
        end
    end

    wire       acc_en    = comp_v_pipe[ACC_DELAY-1];
    wire       acc_clear = first_pipe [ACC_DELAY-1];
    wire       acc_last  = last_pipe  [ACC_DELAY-1];
    wire [2:0] acc_pair  = pair_pipe  [ACC_DELAY-1];

    //==========================================================================
    // 8. Accumulator (2 OC)
    //==========================================================================
    wire signed [ACC_W-1:0] logit0_acc;
    wire signed [ACC_W-1:0] logit1_acc;
    wire                    logit_valid;

    fc_accumulator #(.ACC_W(ACC_W)) acc_inst (
        .clk        (clk),
        .rst        (rst),
        .en         (acc_en),
        .clear      (acc_clear),
        .last       (acc_last),
        .sum0       (sum0),
        .sum1       (sum1),
        .logit0     (logit0_acc),
        .logit1     (logit1_acc),
        .logit_valid(logit_valid)
    );

    //==========================================================================
    // 9. Logit 수집 레지스터 (10-slot, 각 ACC_W-bit signed)
    //
    //   logit_valid pulse 마다 acc_pair 를 기준으로:
    //     logit_reg[pair*2]   ← logit0_acc  (OC_even)
    //     logit_reg[pair*2+1] ← logit1_acc  (OC_odd)
    //
    //   ★ acc_pair 는 ACC_DELAY 지연되어 logit_valid 와 동일 cycle 에 valid.
    //
    //   pair 4 (마지막) 의 logit_valid 다음 cycle 에
    //   all_ready=1 → argmax 에 logit_flat 전달.
    //==========================================================================
    reg signed [ACC_W-1:0] logit_reg [0:9];

    integer oc;
    always @(posedge clk) begin
        if (rst) begin
            for (oc = 0; oc < 10; oc = oc + 1)
                logit_reg[oc] <= {ACC_W{1'b0}};
        end else if (logit_valid) begin
            logit_reg[{1'b0, acc_pair} * 2    ] <= logit0_acc;
            logit_reg[{1'b0, acc_pair} * 2 + 1] <= logit1_acc;
        end
    end

    // logit_flat 조립 (argmax 입력)
    wire [10*ACC_W-1:0] logit_flat;
    genvar gi;
    generate
        for (gi = 0; gi < 10; gi = gi + 1) begin : flat_pack
            assign logit_flat[gi*ACC_W +: ACC_W] = logit_reg[gi];
        end
    endgenerate

    //==========================================================================
    // 10. all_ready: pair 4 의 logit_valid 다음 cycle → argmax 기동
    //   logit_valid && acc_pair==4 인 cycle 에 마지막 pair 완료.
    //   그 edge 에서 logit_reg[8/9] 도 업데이트됨.
    //   → 다음 cycle (all_ready) 에 logit_flat 이 완성 → argmax 에 전달.
    //==========================================================================
    reg all_ready;
    always @(posedge clk) begin
        if (rst)
            all_ready <= 1'b0;
        else
            all_ready <= logit_valid && (acc_pair == 3'd4);
    end

    //==========================================================================
    // 11. argmax (10 logit 동시 비교)
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