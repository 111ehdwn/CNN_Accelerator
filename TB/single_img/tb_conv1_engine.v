`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
<<<<<<< HEAD
// Testbench: tb_conv1_engine
// - conv1_weight.mem / input_image.mem 을 $readmemh 로 로드
// - weight BRAM 모델: latency=2 (Primitive Output Register ON)
// - input  BRAM 모델: latency=1 (Primitive Output Register OFF)
// - 128-bit c1c2 BRAM 모델 (byte write enable, depth=512, 2 pixels per address)
//     레이아웃: [127:96]=Run2 odd,  [95:64]=Run2 even
//              [ 63:32]=Run1 odd,  [ 31: 0]=Run1 even
//     Run1: wea=16'h00FF → 하위 64bit 기록 (ch0~3)
//     Run2: wea=16'hFF00 → 상위 64bit 기록 (ch4~7)
// - done 시 8채널 26x26 을 conv1_out.hex 로 저장
=======
// tb_conv1_engine.v
// Single-image bit-exact testbench for conv1_engine  (uses real BMG IPs)
//
//   3 real BMG IP instantiation:
//     conv1_input_bram   (PS write Port A, Conv1 read Port B)  — 8-bit × 1024, L=2
//     conv1_weight_bram  (PS write Port A, Conv1 read Port B)  — 32-bit × 64,  L=2, REGCEB pin exposed
//     bram_c1_to_c2      (Conv1 write Port A, TB read Port B)  — 64-bit × 2048, L=2, byte-write 8-bit
//
//   자극 sequence:
//     reset → init_input() → init_weight() → start pulse → wait done → compare c1c2 BMG bank 0 vs expected
//
//   Conv1 동작 (요약):
//     IDLE → LOAD (weight 적재 ~40 cycle) → RUN1 (28×28 scan, oc0..3, sel=0) → FLUSH1
//     → LBRST → RUN2 (28×28 scan, oc4..7, sel=1) → FLUSH2 → DONE
//     done 시 c1c2 BMG bank 0 에 8 OC × 26×26 결과 완성.
>>>>>>> 12f287f260ce26553f81628f33c1bef5ec0139cb
//////////////////////////////////////////////////////////////////////////////////

`define CONV1_INPUT_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_input.hex"
`define CONV1_WEIGHT_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_weights_simd.hex"
`define CONV1_EXPECTED_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_output_c1c2.hex"


module tb_conv1_engine;

    //==========================================================================
    // Clock / reset (100 MHz)
    //==========================================================================
<<<<<<< HEAD
    reg clk   = 0;
    reg rst = 1;     // active-high: 1=리셋, 0=정상동작
    reg start = 0;

    always #5 clk = ~clk;   // 10ns = 100MHz

    //==========================================================================
    // 2. DUT 포트 선언
=======
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    //==========================================================================
    // DUT 시그널
>>>>>>> 12f287f260ce26553f81628f33c1bef5ec0139cb
    //==========================================================================
    reg          start    = 1'b0;
    wire         done;

    // ping-pong bank (standalone: 항상 0)
    wire         bank_sel = 1'b0;

    // conv1_input_bram interface
    reg          in_ena   = 1'b0;            // TB driving Port A (init_input)
    reg          in_wea   = 1'b0;
    reg  [9:0]   in_addra = 10'd0;
    reg  [7:0]   in_dina  = 8'd0;
    wire [9:0]   in_addrb;                   // Conv1 reads Port B
    wire         in_enb;
    wire signed [7:0] in_doutb;

<<<<<<< HEAD
    // 128-bit c1c2 인터페이스
    wire [8:0]   c1c2_addr;   // pair address (pixel_addr >> 1), max 337
    wire         c1c2_we;     // write enable (odd pixel only)
    wire [15:0]  c1c2_wea;    // byte write enable
    wire [127:0] c1c2_din;    // 128-bit data

    //==========================================================================
    // 3. DUT 인스턴스
    //==========================================================================
    conv1_engine dut (
        .clk          (clk),
        .rst          (rst),
        .start        (start),
        .done         (done),
        .in_bram_addr (in_bram_addr),
        .in_bram_en   (in_bram_en),
        .in_bram_dout (in_bram_dout),
        .w_bram_addr  (w_bram_addr),
        .w_bram_en    (w_bram_en),
        .w_bram_dout  (w_bram_dout),
        .c1c2_addr    (c1c2_addr),
        .c1c2_we      (c1c2_we),
        .c1c2_wea     (c1c2_wea),
        .c1c2_din     (c1c2_din)
    );

    //==========================================================================
    // 4. BRAM 모델 — weight BRAM (latency=2)
=======
    // conv1_weight_bram interface
    reg          w_ena    = 1'b0;            // TB driving Port A (init_weight)
    reg          w_wea    = 1'b0;
    reg  [5:0]   w_addra  = 6'd0;
    reg  [31:0]  w_dina   = 32'd0;
    wire [5:0]   w_addrb;
    wire         w_enb;
    wire [31:0]  w_doutb;

    // bram_c1_to_c2 interface
    wire         c1c2_we_a;                  // Conv1 writes Port A
    wire [7:0]   c1c2_wea_a;
    wire [10:0]  c1c2_addr_a;
    wire [63:0]  c1c2_din_a;
    reg          c1c2_enb_b   = 1'b0;        // TB reads Port B (verification)
    reg  [10:0]  c1c2_addr_b  = 11'd0;
    wire [63:0]  c1c2_doutb_b;

    //==========================================================================
    // BMG IP 인스턴스 (사용자 측 Vivado 프로젝트에 생성 필요)
    //==========================================================================
    conv1_input_bram in_bmg (
        .clka  (clk),
        .ena   (in_ena),
        .wea   (in_wea),
        .addra (in_addra),
        .dina  (in_dina),
        .clkb  (clk),
        .enb   (in_enb),
        .addrb (in_addrb),
        .doutb (in_doutb)
    );

    conv1_weight_bram w_bmg (
        .clka  (clk),
        .ena   (w_ena),
        .wea   (w_wea),
        .addra (w_addra),
        .dina  (w_dina),
        .clkb  (clk),
        .enb   (w_enb),
        .addrb (w_addrb),
        .doutb (w_doutb),
        .regceb(1'b1)                        // 상수 1: 마지막 weight propagation 보장
    );

    bram_c1_to_c2 c1c2_bmg (
        .clka  (clk),
        .ena   (c1c2_we_a),
        .wea   (c1c2_wea_a),
        .addra (c1c2_addr_a),
        .dina  (c1c2_din_a),
        .clkb  (clk),
        .enb   (c1c2_enb_b),
        .addrb (c1c2_addr_b),
        .doutb (c1c2_doutb_b)
    );

    //==========================================================================
    // DUT
>>>>>>> 12f287f260ce26553f81628f33c1bef5ec0139cb
    //==========================================================================
    conv1_engine dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .done         (done),

        .bank_sel     (bank_sel),

        .in_bram_addr (in_addrb),
        .in_bram_en   (in_enb),
        .in_bram_dout (in_doutb),

        .w_bram_addr  (w_addrb),
        .w_bram_en    (w_enb),
        .w_bram_dout  (w_doutb),

        .c1c2_we      (c1c2_we_a),
        .c1c2_wea     (c1c2_wea_a),
        .c1c2_addr    (c1c2_addr_a),
        .c1c2_din     (c1c2_din_a)
    );

    //==========================================================================
<<<<<<< HEAD
    // 5. BRAM 모델 — input image BRAM (latency=1)
=======
    // TB-local memory (init 용)
>>>>>>> 12f287f260ce26553f81628f33c1bef5ec0139cb
    //==========================================================================
    reg [7:0]  input_mem  [0:783];          // 28×28 raw pixels
    reg [31:0] weight_mem [0:35];           // Conv1 packed weights (36 entry)
    reg [63:0] expected_c1c2 [0:1023];      // expected c1c2 BMG bank 0 (1024 padded)

    //==========================================================================
<<<<<<< HEAD
    // 6. 128-bit c1c2 BRAM 모델 (byte write enable)
    //    depth=512 (실제 사용 338 pairs), width=128bit
    //==========================================================================
    reg [127:0] c1c2_mem [0:511];

    integer init_i;
    initial begin
        for (init_i = 0; init_i < 512; init_i = init_i + 1)
            c1c2_mem[init_i] = 128'd0;
    end

    integer byte_i;
    always @(posedge clk) begin
        if (c1c2_we) begin
            for (byte_i = 0; byte_i < 16; byte_i = byte_i + 1) begin
                if (c1c2_wea[byte_i])
                    c1c2_mem[c1c2_addr][byte_i*8 +: 8] <= c1c2_din[byte_i*8 +: 8];
=======
    // Cycle counter
    //==========================================================================
    integer cycle_cnt;
    integer cycle_at_start, cycle_at_done;

    initial cycle_cnt = 0;
    always @(posedge clk) if (rst_n) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Task: init_input — Port A 로 784 cycle 동안 input image write
    //==========================================================================
    task init_input;
        integer ii;
        begin
            $display("[TB] @ cycle %0d : init_input start (784 cycle)", cycle_cnt);
            for (ii = 0; ii < 784; ii = ii + 1) begin
                @(negedge clk);
                in_ena   = 1'b1;
                in_wea   = 1'b1;
                in_addra = ii[9:0];
                in_dina  = input_mem[ii];
>>>>>>> 12f287f260ce26553f81628f33c1bef5ec0139cb
            end
            @(negedge clk);
            in_ena   = 1'b0;
            in_wea   = 1'b0;
            $display("[TB] @ cycle %0d : init_input done", cycle_cnt);
        end
    endtask

    //==========================================================================
<<<<<<< HEAD
    // 7. done 시 c1c2_mem → 8채널 재구성 → conv1_out.hex 저장
    //
    //    pair_addr = pixel_addr / 2   (0~337)
    //    px_lsb    = pixel_addr % 2   (0=even, 1=odd)
    //
    //    ch 0~3 : c1c2_mem[pair_addr][ px_lsb*32 + ch*8      +: 8]  (하위 64bit)
    //    ch 4~7 : c1c2_mem[pair_addr][ 64 + px_lsb*32 + (ch-4)*8 +: 8]  (상위 64bit)
    //
    //    저장 형식: 채널 순서대로 676개씩 → 총 8*676=5408 줄 (16진수 2자리)
    //==========================================================================
    reg signed [7:0] out_buf [0:7][0:675];
    integer fd, save_ch, save_px, pair_addr, px_lsb, bit_base;

    always @(posedge clk) begin
        if (done) begin
            // c1c2_mem에서 채널별 픽셀 복원
            for (save_ch = 0; save_ch < 8; save_ch = save_ch + 1) begin
                for (save_px = 0; save_px < 676; save_px = save_px + 1) begin
                    pair_addr = save_px / 2;
                    px_lsb    = save_px % 2;
                    if (save_ch < 4)
                        bit_base = px_lsb * 32 + save_ch * 8;
                    else
                        bit_base = 64 + px_lsb * 32 + (save_ch - 4) * 8;
                    out_buf[save_ch][save_px] =
                        $signed(c1c2_mem[pair_addr][bit_base +: 8]);
                end
            end

            // 파일 저장
            fd = $fopen("conv1_out.hex", "w");
            for (save_ch = 0; save_ch < 8; save_ch = save_ch + 1)
                for (save_px = 0; save_px < 676; save_px = save_px + 1)
                    $fwrite(fd, "%02x\n", out_buf[save_ch][save_px] & 8'hFF);
            $fclose(fd);
            $display("[TB] done at %0t ns. conv1_out.hex saved.", $time);
            #20 $finish;
=======
    // Task: init_weight — Port A 로 36 cycle 동안 weight write
    //==========================================================================
    task init_weight;
        integer wi;
        begin
            $display("[TB] @ cycle %0d : init_weight start (36 cycle)", cycle_cnt);
            for (wi = 0; wi < 36; wi = wi + 1) begin
                @(negedge clk);
                w_ena   = 1'b1;
                w_wea   = 1'b1;
                w_addra = wi[5:0];
                w_dina  = weight_mem[wi];
            end
            @(negedge clk);
            w_ena   = 1'b0;
            w_wea   = 1'b0;
            $display("[TB] @ cycle %0d : init_weight done", cycle_cnt);
>>>>>>> 12f287f260ce26553f81628f33c1bef5ec0139cb
        end
    endtask

    //==========================================================================
<<<<<<< HEAD
    // 8. 자극 시퀀스
    //==========================================================================
    initial begin
        repeat(5)  @(posedge clk);
        rst = 0;            // 리셋 해제
        repeat(2)  @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        // 타임아웃: 가중치 로드(~41) + RUN1(784) + FLUSH1(6) + LBRST(1)
        //         + RUN2(784) + FLUSH2(6) + DONE(1) + 여유 ≈ 1700 사이클
        repeat(5000) @(posedge clk);
        $display("[TB] TIMEOUT");
=======
    // Task: compare_c1c2 — bank 0 read + expected 비교 (L=2 pipelined read)
    //==========================================================================
    integer total_mm;
    task compare_c1c2;
        integer i;
        reg [63:0] got, exp;
        reg [10:0] read_addr;
        begin
            total_mm = 0;
            $display("[TB] Comparing c1c2 BMG bank 0 (1024 entries) vs expected ...");
            // Pipelined read (L=2): addr@T → dout@T+2
            for (i = 0; i < 1024 + 2; i = i + 1) begin
                @(negedge clk);
                if (i < 1024) begin
                    c1c2_enb_b  = 1'b1;
                    c1c2_addr_b = {1'b0, i[9:0]};   // bank 0
                end else begin
                    c1c2_enb_b  = 1'b0;
                end

                if (i >= 2) begin
                    read_addr = i - 2;
                    got = c1c2_doutb_b;
                    exp = expected_c1c2[read_addr];
                    if (got !== exp) begin
                        total_mm = total_mm + 1;
                        if (total_mm <= 10) begin
                            $display("  MM @ addr %0d : got=%h, exp=%h",
                                     read_addr, got, exp);
                        end
                    end
                end
            end
            @(negedge clk);
            c1c2_enb_b = 1'b0;
        end
    endtask

    //==========================================================================
    // Main stimulus
    //==========================================================================
    initial begin
        $display("[TB] === Conv1 single-image bit-exact test ===");
        $display("[TB] Loading input  : %s", `CONV1_INPUT_HEX);
        $readmemh(`CONV1_INPUT_HEX,    input_mem);
        $display("[TB] Loading weight : %s", `CONV1_WEIGHT_HEX);
        $readmemh(`CONV1_WEIGHT_HEX,   weight_mem);
        $display("[TB] Loading expected: %s", `CONV1_EXPECTED_HEX);
        $readmemh(`CONV1_EXPECTED_HEX, expected_c1c2);

        // Reset
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        // Init BMGs (Port A driving)
        init_input();
        init_weight();

        // Start pulse
        @(negedge clk);
        start = 1'b1;
        cycle_at_start = cycle_cnt;
        @(negedge clk);
        start = 1'b0;
        $display("[TB] @ cycle %0d : start pulsed", cycle_at_start);

        // Wait done
        @(posedge done);
        cycle_at_done = cycle_cnt;
        $display("[TB] @ cycle %0d : done received", cycle_at_done);

        // Settle a few cycles for c1c2 BMG mem update
        repeat (5) @(posedge clk);

        // Compare c1c2 BMG bank 0 vs expected
        compare_c1c2();

        // Report
        $display("");
        $display("================================================");
        $display("  Conv1 single-image testbench result");
        $display("================================================");
        $display("  start       @ cycle %0d", cycle_at_start);
        $display("  done        @ cycle %0d", cycle_at_done);
        $display("  compute     : %0d cycles", cycle_at_done - cycle_at_start);
        $display("  mismatches  : %0d / 1024", total_mm);
        if (total_mm == 0)
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
        #100000;
        $display("[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
>>>>>>> 12f287f260ce26553f81628f33c1bef5ec0139cb
        $finish;
    end

endmodule
