`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_cnn_accelerator_multi.v
// PL core (cnn_accelerator) 전체 검증 TB — overlap throughput.
//
//   PS 동작 emul:
//     - weight 적재 : w1/c2w/fcw Port A write (AXI BRAM Ctrl emul)
//     - enable=1, start pulse (weight load + 가동)
//     - per image  : Input BRAM Port A write → img_ready pulse
//     - 검증       : result(class) + dut.fc.logit_reg(logit) bit-exact
//
//   Overlap (input_consumed backpressure):
//     dispatcher 가 input_consumed 기준 (적재 - consumed < 2, input BRAM 2-bank) 으로
//     다음 image 를 미리 적재 → conv1 처리 중 다음 image 를 채워 pipeline overlap
//     (통합 TB 와 동일 throughput). result_collector 가 img_done 마다 검증.
//
//   iverilog: TB/models/bmg_sim_models.v + dsp48e1_model.v 필요.
//////////////////////////////////////////////////////////////////////////////////

`ifdef __ICARUS__
  `define ALL_INPUT_HEX    "data/multi_img/all_input.hex"
  `define CONV1_WEIGHT_HEX "data/weights_simd/conv1_weights_simd.hex"
  `define CONV2_WEIGHT_HEX "data/weights_simd/conv2_weights_simd.hex"
  `define FCW_HEX          "data/weights_simd/fc_weights_simd.hex"
  `define FC_LOGIT_HEX     "data/multi_img/all_fc_logit.hex"
`else
  `define ALL_INPUT_HEX    "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_input.hex"
  `define CONV1_WEIGHT_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_weights_simd.hex"
  `define CONV2_WEIGHT_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_weights_simd.hex"
  `define FCW_HEX          "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/fc_weights_simd.hex"
  `define FC_LOGIT_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_fc_logit.hex"
`endif


module tb_cnn_accelerator_multi;

    parameter N_IMAGES    = 40;
    parameter ACC_W       = 24;
    parameter CHECK_LABEL = 1;

    //==========================================================================
    // Clock / reset
    //==========================================================================
    reg clk    = 1'b0;
    reg resetn = 1'b0;       // active-low (외부 버튼 emul), 초기 asserted
    always #5 clk = ~clk;

    //==========================================================================
    // CSR control / status
    //==========================================================================
    reg        enable    = 1'b0;
    reg        start     = 1'b0;
    reg        img_ready = 1'b0;
    wire [3:0] result;
    wire       img_done;
    wire       input_consumed;

    // Output result BRAM Port B (PS read) — bram_output readback 검증
    reg         res_rd_en   = 1'b0;
    reg  [11:0] res_rd_addr = 12'd0;
    wire [31:0] res_rd_data;
    integer     rb_word, rb_i, rb_base, rb_pass;
    reg  [31:0] rb_data;
    reg  [3:0]  rb_res, rb_exp;

    //==========================================================================
    // PS-write BMG Port A
    //==========================================================================
    reg         in_ena   = 1'b0;
    reg  [3:0]  in_wea   = 4'd0;          // byte-write (AXI WSTRB)
    reg  [8:0]  in_addra = 9'd0;
    reg  [31:0] in_dina  = 32'd0;

    reg         c1w_ena   = 1'b0;
    reg  [3:0]  c1w_wea   = 4'd0;         // byte-write (AXI WSTRB)
    reg  [5:0]  c1w_addra = 6'd0;
    reg  [31:0] c1w_dina  = 32'd0;

    reg         c2w_ena   = 1'b0;
    reg  [3:0]  c2w_wea   = 4'd0;         // byte-write (AXI WSTRB)
    reg  [9:0]  c2w_addra = 10'd0;
    reg  [31:0] c2w_dina  = 32'd0;

    reg          fcw_ena   = 1'b0;
    reg  [31:0]  fcw_wea   = 32'd0;        // 256-bit byte-write (AXI WSTRB)
    reg  [9:0]   fcw_addra = 10'd0;
    reg  [255:0] fcw_dina  = 256'd0;

    //==========================================================================
    // DUT
    //==========================================================================
    cnn_accelerator dut (
        .clk       (clk),
        .resetn    (resetn),
        .enable    (enable),
        .start     (start),
        .img_ready (img_ready),
        .result    (result),
        .img_done  (img_done),
        .input_consumed (input_consumed),

        .in_ena (in_ena), .in_wea (in_wea), .in_addra (in_addra), .in_dina (in_dina),
        .c1w_ena (c1w_ena), .c1w_wea (c1w_wea), .c1w_addra (c1w_addra), .c1w_dina (c1w_dina),
        .c2w_ena(c2w_ena), .c2w_wea(c2w_wea), .c2w_addra(c2w_addra), .c2w_dina(c2w_dina),
        .fcw_ena(fcw_ena), .fcw_wea(fcw_wea), .fcw_addra(fcw_addra), .fcw_dina(fcw_dina),
        .res_rd_en(res_rd_en), .res_rd_addr(res_rd_addr), .res_rd_data(res_rd_data)
    );

    //==========================================================================
    // TB-local memory
    //==========================================================================
    reg [7:0]   input_data     [0:N_IMAGES*784-1];
    reg [31:0]  weight1_mem    [0:35];
    reg [31:0]  weight2_mem    [0:575];
    reg [31:0]  fc_weight_simd [0:11519];
    reg signed [23:0] exp_logit [0:N_IMAGES*10-1];

    //==========================================================================
    // Statistics + cross-process sync
    //==========================================================================
    integer cycle_cnt    = 0;
    integer images_pass  = 0;
    integer results_seen = 0;
    integer first_result_cyc = 0;
    integer last_result_cyc  = 0;

    always @(posedge clk) if (resetn) cycle_cnt <= cycle_cnt + 1;

    // input_consumed count (overlap backpressure: 적재 - consumed < 2)
    integer input_consumed_count = 0;
    always @(posedge clk) begin
        if (!resetn)            input_consumed_count <= 0;
        else if (input_consumed) input_consumed_count <= input_consumed_count + 1;
    end

    reg weight_loaded = 1'b0;
    reg all_done      = 1'b0;

    //==========================================================================
    // Tasks — PS-style Port A write
    //==========================================================================
    task load_w1;
        integer wi;
        begin
            for (wi = 0; wi < 36; wi = wi + 1) begin
                @(negedge clk);
                c1w_ena = 1'b1; c1w_wea = 4'hF;
                c1w_addra = wi[5:0]; c1w_dina = weight1_mem[wi];
            end
            @(negedge clk); c1w_ena = 1'b0; c1w_wea = 4'd0;
        end
    endtask

    task load_w2;
        integer wi;
        begin
            for (wi = 0; wi < 576; wi = wi + 1) begin
                @(negedge clk);
                c2w_ena = 1'b1; c2w_wea = 4'hF;
                c2w_addra = wi[9:0]; c2w_dina = weight2_mem[wi];
            end
            @(negedge clk); c2w_ena = 1'b0; c2w_wea = 4'd0;
        end
    endtask

    // FC weight SIMD unpack → asymmetric Port A 32b write (256b word 당 8 × 32b, LSB-first)
    task load_fcw;
        integer pair, s, c, k, line_idx;
        reg signed [7:0]  w0, w1;
        reg signed [16:0] w0_packed_17;
        reg signed [7:0]  w1_packed_8;
        reg [127:0]       w_even_concat, w_odd_concat;
        reg [255:0]       word;
        begin
            for (pair = 0; pair < 5; pair = pair + 1) begin
                for (s = 0; s < 144; s = s + 1) begin
                    w_even_concat = 128'd0;
                    w_odd_concat  = 128'd0;
                    for (c = 0; c < 16; c = c + 1) begin
                        line_idx     = pair*144*16 + s*16 + c;
                        w0_packed_17 = $signed(fc_weight_simd[line_idx][16:0]);
                        w1_packed_8  = $signed(fc_weight_simd[line_idx][24:17]);
                        w0 = w0_packed_17[7:0];
                        w1 = w1_packed_8 + (w0_packed_17[16] ? 8'sd1 : 8'sd0);
                        w_even_concat[c*8 +: 8] = w0;
                        w_odd_concat [c*8 +: 8] = w1;
                    end
                    word = {w_odd_concat, w_even_concat};
                    // 256b full-word write : addr = pair*144 + s
                    @(negedge clk);
                    fcw_ena   = 1'b1; fcw_wea = 32'hFFFF_FFFF;
                    fcw_addra = pair*144 + s;
                    fcw_dina  = word;
                end
            end
            @(negedge clk); fcw_ena = 1'b0; fcw_wea = 32'd0; fcw_addra = 10'd0; fcw_dina = 256'd0;
        end
    endtask

    task write_input;
        input integer img_idx;
        integer k;
        reg     bank;
        begin
            bank = img_idx[0];
            for (k = 0; k < 196; k = k + 1) begin
                @(negedge clk);
                in_ena = 1'b1; in_wea = 4'hF;
                in_addra = {bank, k[7:0]};
                in_dina  = {input_data[img_idx*784 + k*4 + 3],
                            input_data[img_idx*784 + k*4 + 2],
                            input_data[img_idx*784 + k*4 + 1],
                            input_data[img_idx*784 + k*4 + 0]};
            end
            @(negedge clk); in_ena = 1'b0; in_wea = 4'd0;
        end
    endtask

    task pulse_start;
        begin
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
        end
    endtask

    task pulse_img_ready;
        begin
            @(negedge clk); img_ready = 1'b1;
            @(negedge clk); img_ready = 1'b0;
        end
    endtask

    // expected logit 10개에서 argmax (fc_argmax 와 동일 규칙)
    function [3:0] exp_argmax;
        input integer base;
        integer j;
        reg signed [23:0] best;
        reg [3:0] bi;
        begin
            best = exp_logit[base]; bi = 4'd0;
            for (j = 1; j < 10; j = j + 1)
                if (exp_logit[base + j] > best) begin
                    best = exp_logit[base + j]; bi = j[3:0];
                end
            exp_argmax = bi;
        end
    endfunction

    //==========================================================================
    // PROCESS 1: Main — reset → weight 적재 → enable/start → wait → report
    //==========================================================================
    initial begin : main_process
        $display("\n==========================================");
        $display("  cnn_accelerator (PL core) overlap TB  (N=%0d, CHECK_LABEL=%0d)", N_IMAGES, CHECK_LABEL);
        $display("==========================================");

        $readmemh(`ALL_INPUT_HEX,    input_data);
        $readmemh(`CONV1_WEIGHT_HEX, weight1_mem);
        $readmemh(`CONV2_WEIGHT_HEX, weight2_mem);
        $readmemh(`FCW_HEX,          fc_weight_simd);
        if (CHECK_LABEL) $readmemh(`FC_LOGIT_HEX, exp_logit);

        // Reset (active-low)
        resetn = 1'b0;
        repeat (10) @(posedge clk);
        @(negedge clk); resetn = 1'b1;
        $display("[TB] @ cyc %0d : reset released", cycle_cnt);

        // PS: weight 적재 (Port A)
        load_w1();
        load_w2();
        load_fcw();
        $display("[TB] @ cyc %0d : weights loaded (w1/w2/fc)", cycle_cnt);

        // 가동 + weight load (conv2 LOAD_WEIGHTS) + timer
        @(negedge clk); enable = 1'b1;
        pulse_start();
        $display("[TB] @ cyc %0d : enable=1, start pulsed", cycle_cnt);
        weight_loaded = 1'b1;

        wait (all_done == 1'b1);

        // ---- bram_output readback 검증 (PS emul: 종료 후 res_rd_* 로 일괄 read) ----
        //   word k = image 4k..4k+3 의 result (byte 의 low 4-bit). overlap 으로 다 처리된
        //   뒤 읽어 "파이프라이닝 중 결과 손실 없음" 입증 (cnn `result` 출력과 독립 경로).
        rb_pass = 0;
        if (CHECK_LABEL) begin
            for (rb_word = 0; rb_word < (N_IMAGES + 3) / 4; rb_word = rb_word + 1) begin
                @(negedge clk); res_rd_en = 1'b1; res_rd_addr = rb_word[11:0];
                @(posedge clk);                        // L=1 read: doutb <= mem[rb_word]
                @(negedge clk); rb_data = res_rd_data; // doutb 안정
                for (rb_i = 0; rb_i < 4; rb_i = rb_i + 1) begin
                    rb_base = rb_word*4 + rb_i;
                    if (rb_base < N_IMAGES) begin
                        rb_res = rb_data[rb_i*8 +: 4];      // {4'b0, digit} 의 digit
                        rb_exp = exp_argmax(rb_base*10);
                        if (rb_res === rb_exp) rb_pass = rb_pass + 1;
                        else $display("[TB] readback img %0d : FAIL  bram=%0d exp=%0d",
                                      rb_base, rb_res, rb_exp);
                    end
                end
            end
            @(negedge clk); res_rd_en = 1'b0;
        end

        // Final report
        $display("\n=========================================");
        $display("  FINAL : results %0d / %0d", results_seen, N_IMAGES);
        if (CHECK_LABEL) begin
            $display("  images PASS    : %0d / %0d", images_pass, N_IMAGES);
        end
        $display("  throughput     : %0d cyc total (img0..%0d), avg %0d cyc/img",
                 last_result_cyc - first_result_cyc, N_IMAGES-1,
                 (N_IMAGES > 1) ? (last_result_cyc - first_result_cyc) / (N_IMAGES-1) : 0);
        if (CHECK_LABEL) begin
            $display("  bram_output readback : %0d / %0d", rb_pass, N_IMAGES);
            if (images_pass == N_IMAGES && rb_pass == N_IMAGES)
                $display("  *** PASS *** (result+logit bit-exact + bram_output readback, overlap)");
            else
                $display("  *** FAIL ***");
        end
        $display("=========================================");
        $finish;
    end

    //==========================================================================
    // PROCESS 2: Image dispatcher (PS emul) — input_consumed backpressure
    //   적재 - input_consumed < 2 (input BRAM 2-bank) 일 때만 다음 image 적재 →
    //   conv1 이 image i 처리 중 image i+1 을 미리 채워 pipeline overlap.
    //==========================================================================
    integer i_disp;
    initial begin : dispatcher
        wait (weight_loaded == 1'b1);
        @(negedge clk);

        for (i_disp = 0; i_disp < N_IMAGES; i_disp = i_disp + 1) begin
            wait ((i_disp - input_consumed_count) < 2);   // backpressure
            write_input(i_disp);                          // bank (i_disp & 1)
            pulse_img_ready();
        end
    end

    //==========================================================================
    // PROCESS 3: Result collector — img_done 마다 result/logit 검증
    //==========================================================================
    integer i_res, j_res, logit_mm;
    reg [3:0] exp_cls;
    initial begin : result_collector
        wait (resetn == 1'b1);

        for (i_res = 0; i_res < N_IMAGES; i_res = i_res + 1) begin
            @(posedge img_done);
            if (i_res == 0) first_result_cyc = cycle_cnt;
            last_result_cyc = cycle_cnt;
            results_seen = results_seen + 1;

            if (CHECK_LABEL) begin
                logit_mm = 0;
                for (j_res = 0; j_res < 10; j_res = j_res + 1)
                    if (dut.fc.logit_reg[j_res][23:0] !== exp_logit[i_res*10 + j_res])
                        logit_mm = logit_mm + 1;
                exp_cls = exp_argmax(i_res*10);

                if (logit_mm == 0 && result == exp_cls) begin
                    images_pass = images_pass + 1;
                    $display("[TB] img %3d : PASS  result=%0d  @cyc %0d", i_res, result, cycle_cnt);
                end else begin
                    $display("[TB] img %3d : FAIL  result=%0d exp=%0d logit_mm=%0d/10  @cyc %0d",
                             i_res, result, exp_cls, logit_mm, cycle_cnt);
                end
            end else begin
                $display("[TB] img %3d : result=%0d  @cyc %0d", i_res, result, cycle_cnt);
            end
        end

        all_done = 1'b1;
    end

    //==========================================================================
    // Timeout
    //==========================================================================
    initial begin
        #40000000;
        $display("\n[TB] !!! TIMEOUT @ cyc %0d (results=%0d/%0d) !!!",
                 cycle_cnt, results_seen, N_IMAGES);
        $finish;
    end

endmodule
