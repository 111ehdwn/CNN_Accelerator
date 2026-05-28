`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_engine
// Description:
//   FC layer engine for channel-major packed input.
//
//   Input BRAM:
//     width = 128-bit = 16ch * 8-bit
//     depth = 144 spatial words
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
    // 128-bit x 144 per bank, 1-cycle read latency
    //==========================================================================
    output wire         poolfc_re,
    output wire [9:0]   poolfc_addr,
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
    // 2. Input BRAM address
    // If there is no ping-pong bank, use only fsm_s_cnt in the connected memory.
    // If two banks are stored in one BRAM, this maps:
    //   bank0: 0..143
    //   bank1: 144..287
    //==========================================================================
    assign poolfc_re   = fsm_comp_v;
    assign poolfc_addr = (fsm_input_bank_sel) ? (10'd144 + {2'd0, fsm_s_cnt})
                                              : ({2'd0, fsm_s_cnt});

    //==========================================================================
    // 3. Weight BRAM, 256-bit x 720, 1-cycle read latency
    //==========================================================================
    wire [9:0]   fcw_addrb = fsm_wbase + {2'd0, fsm_s_cnt};
    wire [255:0] fcw_doutb;

    fc_weight_bram fcw_bmg_inst (
        .clka   (clk),
        .wea    (fcw_ena),
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
    // Timeline for an issued spatial word at cycle T:
    //   T+1 : input/weight BRAM dout valid       -> PE samples
    //   T+2 : PE output register updated
    //   T+3 : adder stage1 samples PE output
    //   T+6 : adder final sum register updated
    //   T+7 : accumulator samples final sum
    //
    // Therefore:
    //   pe_en     = comp_v delayed 1
    //   adder_en  = comp_v delayed 3
    //   acc_ctrl  = comp_v/first/last/pair delayed 7
    //==========================================================================
    localparam CTRL_DELAY = 7;

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

    wire pe_en    = comp_pipe[1] | comp_pipe[2];
    wire adder_en = comp_pipe[3] | comp_pipe[4] | comp_pipe[5] | comp_pipe[6]; 

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
    // acc_pair = pair_pipe[7] 는 logit_valid 가 출력되는 사이클(T+1)에
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