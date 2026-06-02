`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_cnn_full_multi.v
// Conv1 + Conv2 + Maxpool + FC full pipeline multi-image TB (N_IMAGES)
//
//   Handshake chain:
//     TB(pulse) → conv1.prior_wdone
//     conv1.wdone → conv2.prior_wdone        (direct wire)
//     conv2.rdone → conv1.succ_rdone          (direct wire)
//     conv2.wdone → maxpool.prior_wdone       (direct wire)
//     maxpool.rdone → conv2.succ_rdone        (direct wire)
//     maxpool.wdone → fc.prior_wdone          (direct wire)
//     fc.rdone → maxpool.succ_rdone           (direct wire)
//
//   poolfc: 128-bit × 512 behavioral dual-port BRAM
//     write port : maxpool (wr_en / wr_addr[8:0] / wr_data[127:0])
//     read  port : fc_engine (re / addr[8:0] / dout[127:0], L=1)
//////////////////////////////////////////////////////////////////////////////////

`define ALL_INPUT_HEX    "C:/Users/111eh/INTELLIGENT_SYSTEM_DESIGN/assign4_code/CNN_Accelerator/data/multi_img/all_input.hex"
`define CONV1_WEIGHT_HEX "C:/Users/111eh/INTELLIGENT_SYSTEM_DESIGN/assign4_code/CNN_Accelerator/data/weights_simd/conv1_weights_simd.hex"
`define CONV2_WEIGHT_HEX "C:/Users/111eh/INTELLIGENT_SYSTEM_DESIGN/assign4_code/CNN_Accelerator/data/weights_simd/conv2_weights_simd.hex"
`define FCW_HEX          "C:/Users/111eh/INTELLIGENT_SYSTEM_DESIGN/assign4_code/CNN_Accelerator/data/weights_simd/fc_weights_simd.hex"
`define EXPECTED_HEX     "C:/Users/111eh/INTELLIGENT_SYSTEM_DESIGN/assign4_code/CNN_Accelerator/data/multi_img/expected_classes.hex"

module tb_cnn_full_multi;

    parameter N_IMAGES = 100;

    //==========================================================================
    // Clock / reset
    //==========================================================================
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    //==========================================================================
    // Top-level control
    //==========================================================================
    reg  conv1_start   = 1'b0;
    reg  conv2_start   = 1'b0;
    wire conv1_done;
    wire maxpool_done;

    wire conv1_rdone, conv1_wdone;
    wire conv2_rdone, conv2_wdone;
    wire maxpool_rdone, maxpool_wdone;
    wire fc_rdone;
    wire [3:0] fc_class_idx;
    wire       fc_class_valid;

    reg  conv1_prior_wdone = 1'b0;  // TB pulses per image

    //==========================================================================
    // BMG signals
    //==========================================================================
    // bram_input
    reg          in_ena   = 1'b0;
    reg          in_wea   = 1'b0;
    reg  [8:0]   in_addra = 9'd0;
    reg  [31:0]  in_dina  = 32'd0;
    wire [10:0]  in_addrb;
    wire         in_enb;
    wire signed [7:0] in_doutb;

    // conv1_weight_bram
    reg          w1_ena   = 1'b0;
    reg          w1_wea   = 1'b0;
    reg  [5:0]   w1_addra = 6'd0;
    reg  [31:0]  w1_dina  = 32'd0;
    wire [5:0]   w1_addrb;
    wire         w1_enb;
    wire [31:0]  w1_doutb;

    // bram_c1_to_c2
    wire         c1c2_we_a;
    wire [7:0]   c1c2_wea_a;
    wire [10:0]  c1c2_addr_a;
    wire [63:0]  c1c2_din_a;
    wire         c1c2_re_b;
    wire [10:0]  c1c2_addr_b;
    wire [63:0]  c1c2_doutb_b;

    // conv2_weight_bram
    reg          c2w_ena   = 1'b0;
    reg  [9:0]   c2w_addra = 10'd0;
    reg  [31:0]  c2w_dina  = 32'd0;

    // bram_c2_to_pool
    wire         c2pool_we_a;
    wire [10:0]  c2pool_addr_a;
    wire [127:0] c2pool_din_a;
    wire [10:0]  maxpool_c2pool_rd_addr;
    wire         c2pool_re_b;
    wire [127:0] c2pool_doutb_b;

    // poolfc (maxpool write ↔ fc read)
    wire [8:0]   poolfc_wr_addr;
    wire         poolfc_wr_en;
    wire [127:0] poolfc_wr_data;
    wire         poolfc_re;
    wire [8:0]   poolfc_addr;
    wire [127:0] poolfc_dout;

    // fc weight BMG Port A
    reg          fcw_ena   = 1'b0;
    reg  [9:0]   fcw_addra = 10'd0;
    reg  [255:0] fcw_dina  = 256'd0;

    //==========================================================================
    // Handshake counters (debug/backpressure)
    //==========================================================================
    integer conv1_rdone_count   = 0;
    integer conv1_wdone_count   = 0;
    integer conv2_rdone_count   = 0;
    integer maxpool_wdone_count = 0;
    integer fc_class_count      = 0;

    always @(posedge clk) begin
        if (rst) begin
            conv1_rdone_count   <= 0;
            conv1_wdone_count   <= 0;
            conv2_rdone_count   <= 0;
            maxpool_wdone_count <= 0;
            fc_class_count      <= 0;
        end else begin
            if (conv1_rdone)   conv1_rdone_count   <= conv1_rdone_count   + 1;
            if (conv1_wdone)   conv1_wdone_count   <= conv1_wdone_count   + 1;
            if (conv2_rdone)   conv2_rdone_count   <= conv2_rdone_count   + 1;
            if (maxpool_wdone) maxpool_wdone_count <= maxpool_wdone_count + 1;
            if (fc_class_valid)fc_class_count      <= fc_class_count      + 1;
        end
    end

    //==========================================================================
    // BMG IP instances
    //==========================================================================
    conv1_input_bram in_bmg (
        .clka  (clk), .ena (in_ena), .wea (in_wea),
        .addra (in_addra), .dina (in_dina),
        .clkb  (clk), .enb (in_enb),
        .addrb (in_addrb), .doutb (in_doutb)
    );

    conv1_weight_bram w1_bmg (
        .clka  (clk), .ena (w1_ena), .wea (w1_wea),
        .addra (w1_addra), .dina (w1_dina),
        .clkb  (clk), .enb (w1_enb),
        .addrb (w1_addrb), .doutb (w1_doutb),
        .regceb(1'b1)
    );

    bram_c1_to_c2 c1c2_bmg (
        .clka  (clk), .ena (c1c2_we_a), .wea (c1c2_wea_a),
        .addra (c1c2_addr_a), .dina (c1c2_din_a),
        .clkb  (clk), .enb (c1c2_re_b),
        .addrb (c1c2_addr_b), .doutb (c1c2_doutb_b)
    );

    bram_c2_to_pool c2pool_bmg (
        .clka  (clk), .ena (c2pool_we_a), .wea (c2pool_we_a),
        .addra (c2pool_addr_a), .dina (c2pool_din_a),
        .clkb  (clk), .enb (c2pool_re_b),
        .addrb (maxpool_c2pool_rd_addr),
        .doutb (c2pool_doutb_b)
    );

    //==========================================================================
    // poolfc behavioral dual-port BRAM (128-bit × 512)
    //   write: maxpool (synchronous)
    //   read : fc_engine (synchronous, L=1)
    //
    // ★ 핵심 수정: read port 를 명시적으로 구현 (없으면 poolfc_dout = 0 → fc 출력 0)
    //==========================================================================
    reg [127:0] poolfc_mem [0:511];
    reg [127:0] poolfc_dout_r;

    // write port
    always @(posedge clk) begin
        if (poolfc_wr_en)
            poolfc_mem[poolfc_wr_addr] <= poolfc_wr_data;
    end

    // read port (L=1)
    always @(posedge clk) begin
        if (poolfc_re)
            poolfc_dout_r <= poolfc_mem[poolfc_addr];
    end

    assign poolfc_dout = poolfc_dout_r;

    //==========================================================================
    // DUT 1: Conv1
    //==========================================================================
    conv1_engine conv1 (
        .clk          (clk),
        .rst          (rst),
        .start        (conv1_start),
        .done         (conv1_done),
        .prior_wdone  (conv1_prior_wdone),
        .succ_rdone   (conv2_rdone),          // direct wire
        .rdone        (conv1_rdone),
        .wdone        (conv1_wdone),
        .in_bram_addr (in_addrb),
        .in_bram_en   (in_enb),
        .in_bram_dout (in_doutb),
        .c1w_ena      (w1_ena),
        .c1w_wea      (w1_wea),
        .c1w_addra    (w1_addra),
        .c1w_dina     (w1_dina),
        .c1c2_we      (c1c2_we_a),
        .c1c2_wea     (c1c2_wea_a),
        .c1c2_addr    (c1c2_addr_a),
        .c1c2_din     (c1c2_din_a)
    );

    //==========================================================================
    // DUT 2: Conv2
    //==========================================================================
    conv2_engine conv2 (
        .clk         (clk),
        .rst         (rst),
        .start       (conv2_start),
        .c2w_ena     (c2w_ena),
        .c2w_addra   (c2w_addra),
        .c2w_dina    (c2w_dina),
        .c1c2_re     (c1c2_re_b),
        .c1c2_addr   (c1c2_addr_b),
        .c1c2_dout   (c1c2_doutb_b),
        .c2pool_we   (c2pool_we_a),
        .c2pool_addr (c2pool_addr_a),
        .c2pool_din  (c2pool_din_a),
        .prior_wdone (conv1_wdone),           // direct wire
        .rdone       (conv2_rdone),
        .succ_rdone  (maxpool_rdone),         // direct wire
        .wdone       (conv2_wdone)
    );

    //==========================================================================
    // DUT 3: Maxpool
    //   ★ succ_rdone = fc_rdone (direct wire, TB pulse 제거)
    //==========================================================================
    maxpool_engine maxpool (
        .clk            (clk),
        .rst            (rst),
        .start          (1'b0),               // legacy 미사용
        .done           (maxpool_done),
        .prior_wdone    (conv2_wdone),        // direct wire
        .succ_rdone     (fc_rdone),           // ★ direct wire from fc_engine
        .rdone          (maxpool_rdone),
        .wdone          (maxpool_wdone),
        .c2pool_rd_addr (maxpool_c2pool_rd_addr),
        .c2pool_rd_en   (c2pool_re_b),
        .c2pool_rd_data (c2pool_doutb_b),
        .poolfc_wr_addr (poolfc_wr_addr),
        .poolfc_wr_en   (poolfc_wr_en),
        .poolfc_wr_data (poolfc_wr_data)
    );

    //==========================================================================
    // DUT 4: FC Engine
    //   ★ prior_wdone = maxpool_wdone (direct wire)
    //   ★ rdone → maxpool.succ_rdone (direct wire)
    //==========================================================================
    fc_engine #(.ACC_W(24)) fc (
        .clk         (clk),
        .rst         (rst),
        .start       (1'b0),                  // handshake 로만 동작
        .fcw_ena     (fcw_ena),
        .fcw_addra   (fcw_addra),
        .fcw_dina    (fcw_dina),
        .poolfc_re   (poolfc_re),
        .poolfc_addr (poolfc_addr),
        .poolfc_dout (poolfc_dout),
        .prior_wdone (maxpool_wdone),         // ★ direct wire from maxpool
        .rdone       (fc_rdone),
        .class_idx   (fc_class_idx),
        .class_valid (fc_class_valid)
    );

    //==========================================================================
    // TB-local memory
    //==========================================================================
    reg [7:0]  input_data    [0:N_IMAGES*784-1];
    reg [31:0] weight1_mem   [0:35];
    reg [31:0] weight2_mem   [0:575];
    reg [31:0] weight_simd_mem [0:11519];
    reg [7:0]  expected_class [0:N_IMAGES-1]; // 0~9

    //==========================================================================
    // Statistics
    //==========================================================================
    integer total_pass  = 0;
    integer total_fail  = 0;
    integer cycle_cnt   = 0;
    integer cycle_at_start_pulse = 0;
    integer cycle_at_end = 0;

    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Tasks
    //==========================================================================
    task init_weight1;
        integer wi;
        begin
            $display("[TB] @ cycle %0d : init_weight1 start", cycle_cnt);
            for (wi = 0; wi < 36; wi = wi + 1) begin
                @(negedge clk);
                w1_ena = 1'b1; w1_wea = 1'b1;
                w1_addra = wi[5:0]; w1_dina = weight1_mem[wi];
            end
            @(negedge clk); w1_ena = 1'b0; w1_wea = 1'b0;
            $display("[TB] @ cycle %0d : init_weight1 done", cycle_cnt);
        end
    endtask

    task init_weight2;
        integer wi;
        begin
            $display("[TB] @ cycle %0d : init_weight2 start", cycle_cnt);
            for (wi = 0; wi < 576; wi = wi + 1) begin
                @(negedge clk);
                c2w_ena = 1'b1;
                c2w_addra = wi[9:0]; c2w_dina = weight2_mem[wi];
            end
            @(negedge clk); c2w_ena = 1'b0;
            $display("[TB] @ cycle %0d : init_weight2 done", cycle_cnt);
        end
    endtask

    task init_fc_weights;
        integer pair, s, c, line_idx;
        reg signed [7:0]  w0, w1;
        reg signed [16:0] w0_packed_17;
        reg signed [7:0]  w1_packed_8;
        reg [127:0]        w_even_concat, w_odd_concat;
        begin
            $display("[TB] @ cycle %0d : init_fc_weights start", cycle_cnt);
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
            $display("[TB] @ cycle %0d : init_fc_weights done (720 entries)", cycle_cnt);
        end
    endtask

    task write_input;
        input integer img_idx;
        integer k;
        reg bank;
        begin
            bank = img_idx[0];
            for (k = 0; k < 196; k = k + 1) begin
                @(negedge clk);
                in_ena = 1'b1; in_wea = 1'b1;
                in_addra = {bank, k[7:0]};
                in_dina  = {input_data[img_idx*784 + k*4 + 3],
                            input_data[img_idx*784 + k*4 + 2],
                            input_data[img_idx*784 + k*4 + 1],
                            input_data[img_idx*784 + k*4 + 0]};
            end
            @(negedge clk); in_ena = 1'b0; in_wea = 1'b0;
        end
    endtask

    task pulse_conv1_prior_wdone;
        begin
            @(negedge clk); conv1_prior_wdone = 1'b1;
            @(negedge clk); conv1_prior_wdone = 1'b0;
        end
    endtask

    //==========================================================================
    // Cross-process sync
    //==========================================================================
    reg weight_loaded_flag = 1'b0;
    reg all_done_flag      = 1'b0;

    //==========================================================================
    // PROCESS 1: Main
    //==========================================================================
    integer i_main;
    initial begin : main_process
        $display("\n==========================================");
        $display("  CNN Full Pipeline multi-image TB (N=%0d)", N_IMAGES);
        $display("==========================================");

        $readmemh(`ALL_INPUT_HEX,    input_data);
        $readmemh(`CONV1_WEIGHT_HEX, weight1_mem);
        $readmemh(`CONV2_WEIGHT_HEX, weight2_mem);
        $readmemh(`FCW_HEX,          weight_simd_mem);
        $readmemh(`EXPECTED_HEX,     expected_class, 0, N_IMAGES-1);
        $display("[TB] Data loaded");

        // Reset
        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        // Load all weights
        init_weight1();
        init_weight2();
        init_fc_weights();
        weight_loaded_flag = 1'b1;
        $display("[TB] @ cycle %0d : all weights loaded", cycle_cnt);

        // Conv2 start (weight load 1회)
        @(negedge clk); conv2_start = 1'b1;
        @(negedge clk); conv2_start = 1'b0;
        cycle_at_start_pulse = cycle_cnt;
        $display("[TB] @ cycle %0d : conv2_start pulsed", cycle_at_start_pulse);

        wait (all_done_flag == 1'b1);

        $display("\n=========================================");
        $display("  FINAL RESULT");
        $display("=========================================");
        $display("  PASS : %0d / %0d", total_pass, N_IMAGES);
        $display("  FAIL : %0d / %0d", total_fail, N_IMAGES);
        $display("  total cycles (start → last class_valid) : %0d",
                 cycle_at_end - cycle_at_start_pulse);
        $display("  avg cycles/img : %0d",
                 (cycle_at_end - cycle_at_start_pulse) / N_IMAGES);
        if (total_fail == 0)
            $display("  *** ALL PASS ***");
        else
            $display("  *** FAIL ***");
        $display("=========================================");
        $finish;
    end

    //==========================================================================
    // PROCESS 2: Conv1 dispatcher (input 공급)
    //==========================================================================
    integer i_conv1;
    initial begin : conv1_dispatcher
        wait (weight_loaded_flag == 1'b1);
        @(negedge clk);

        for (i_conv1 = 0; i_conv1 < N_IMAGES; i_conv1 = i_conv1 + 1) begin
            // backpressure: 2-bank ping-pong
            wait ((i_conv1 - conv1_rdone_count) < 2);

            write_input(i_conv1);
            pulse_conv1_prior_wdone();
        end
    end

    //==========================================================================
    // PROCESS 3: Result checker
    //   ★ maxpool.succ_rdone 를 TB가 pulse 하지 않음 (fc_rdone direct wire)
    //   ★ fc.class_valid 대기 → class_idx 비교
    //==========================================================================
    integer i_cmp;
    reg [3:0] got_class;
    initial begin : compare_process
        wait (rst == 1'b0);
        @(negedge clk);

        for (i_cmp = 0; i_cmp < N_IMAGES; i_cmp = i_cmp + 1) begin
            // FC 처리 완료 대기
            @(posedge fc_class_valid);
            @(posedge clk);  // class_idx 안정 대기
            got_class = fc_class_idx;
            cycle_at_end = cycle_cnt;

            if (got_class == expected_class[i_cmp]) begin
                total_pass = total_pass + 1;
                $display("[TB] img %3d : PASS  class=%0d @ cycle %0d",
                         i_cmp, got_class, cycle_cnt);
            end else begin
                total_fail = total_fail + 1;
                $display("[TB] img %3d : FAIL  got=%0d exp=%0d @ cycle %0d",
                         i_cmp, got_class, expected_class[i_cmp], cycle_cnt);
            end
        end

        all_done_flag = 1'b1;
    end

    //==========================================================================
    // Timeout
    //==========================================================================
    initial begin
        #50000000;
        $display("\n[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
        $finish;
    end

endmodule
