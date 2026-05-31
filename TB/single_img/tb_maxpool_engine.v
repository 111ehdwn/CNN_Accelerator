`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_maxpool_engine.v
// Single-image bit-exact testbench for maxpool_engine (real bram_c2_to_pool BMG IP)
//
//   Pipeline:
//     PS (init_c2pool) → bram_c2_to_pool Port A
//                        bram_c2_to_pool Port B → Maxpool engine → poolfc behavioral mem
//                                                                       ↓
//                                                                   TB compare
//
//   필요한 BMG IP (Vivado 프로젝트에 미리 생성):
//     bram_c2_to_pool : 128-bit × 2048, L=1, byte-write disable
//
//   자극 sequence:
//     reset → init_c2pool (Port A 576 cycle write to bank 0) →
//     pulse prior_wdone → maxpool auto-RUN (data_ready 조건 충족) → wait done →
//     compare poolfc_mem vs maxpool_output.hex
//
//   4-way handshake test:
//     prior_wdone 1 pulse → prior_diff = -1 → data_ready = true → IDLE→RUN
//     image 끝 후 wdone pulse → after_diff = 1 → output_avail = true (still <2)
//     succ_rdone 안 줘도 단일 image 는 정상 동작
//
//   Reference 형식:
//     maxpool_output.hex (2304 line × 8-bit) — channel-major (ch0 144px → ch1 144px → ... → ch15 144px)
//     poolfc 의 packed 128-bit word [pixel] 를 byte 별로 unpack 해서 비교
//////////////////////////////////////////////////////////////////////////////////

`define CONV2_OUT_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_output_c2pool.hex"
`define MAXPOOL_REF_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/maxpool_output.hex"


module tb_maxpool_engine;

    //==========================================================================
    // Clock / reset (100 MHz, active-high rst)
    //==========================================================================
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    //==========================================================================
    // DUT signals
    //==========================================================================
    reg          start        = 1'b0;        // legacy one-shot init (실제 trigger 는 prior_wdone)
    wire         done;

    reg          prior_wdone  = 1'b0;        // image 시작 trigger
    reg          succ_rdone   = 1'b0;        // downstream 비움 알림 (단일 image 라 미사용)
    wire         rdone;
    wire         wdone;

    // bram_c2_to_pool BMG (단일 IP, Port A: TB, Port B: maxpool)
    reg          c2pool_ena_a = 1'b0;
    reg          c2pool_wea_a = 1'b0;
    reg  [10:0]  c2pool_addra = 11'd0;
    reg  [127:0] c2pool_dina  = 128'd0;

    wire [10:0]  c2pool_rd_addr;             // physical addr {input_bank_sel, local} (11-bit)
    wire         c2pool_rd_en;
    wire signed [127:0] c2pool_rd_data;

    // poolfc 측 (behavioral mem)
    wire [8:0]   poolfc_wr_addr;
    wire         poolfc_wr_en;
    wire [127:0] poolfc_wr_data;

    //==========================================================================
    // BMG IP: bram_c2_to_pool
    //==========================================================================
    bram_c2_to_pool c2pool_bmg (
        .clka  (clk),
        .ena   (c2pool_ena_a),
        .wea   (c2pool_wea_a),
        .addra (c2pool_addra),
        .dina  (c2pool_dina),

        .clkb  (clk),
        .enb   (c2pool_rd_en),
        .addrb (c2pool_rd_addr),               // maxpool 이 physical addr 직접 출력 (single img → bank 0)
        .doutb (c2pool_rd_data)
    );

    //==========================================================================
    // DUT
    //==========================================================================
    maxpool_engine dut (
        .clk             (clk),
        .rst             (rst),
        .start           (start),
        .done            (done),

        .prior_wdone     (prior_wdone),
        .succ_rdone      (succ_rdone),
        .rdone           (rdone),
        .wdone           (wdone),

        .c2pool_rd_addr  (c2pool_rd_addr),
        .c2pool_rd_en    (c2pool_rd_en),
        .c2pool_rd_data  (c2pool_rd_data),

        .poolfc_wr_addr  (poolfc_wr_addr),
        .poolfc_wr_en    (poolfc_wr_en),
        .poolfc_wr_data  (poolfc_wr_data)
    );

    //==========================================================================
    // poolfc behavioral capture mem (단순 RAM, FC layer 미구현)
    //==========================================================================
    reg [127:0] poolfc_mem [0:511];

    always @(posedge clk) begin
        if (poolfc_wr_en)
            poolfc_mem[poolfc_wr_addr] <= poolfc_wr_data;
    end

    //==========================================================================
    // TB-local memory
    //==========================================================================
    reg [127:0] c2pool_data [0:575];           // 576 entry × 128-bit (maxpool input)
    reg [7:0]   maxpool_ref [0:2303];          // 2304 byte: ch-major (ch0 144 → ch1 144 → ...)

    //==========================================================================
    // Cycle counter
    //==========================================================================
    integer cycle_cnt;
    integer cycle_at_prior, cycle_at_done;

    initial cycle_cnt = 0;
    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Task: init_c2pool — write 576 entry × 128-bit to BMG Port A bank 0
    //==========================================================================
    task init_c2pool;
        integer i;
        begin
            $display("[TB] @ cycle %0d : init_c2pool start (576 cycle, bank 0)", cycle_cnt);
            for (i = 0; i < 576; i = i + 1) begin
                @(negedge clk);
                c2pool_ena_a = 1'b1;
                c2pool_wea_a = 1'b1;
                c2pool_addra = {1'b0, i[9:0]};
                c2pool_dina  = c2pool_data[i];
            end
            @(negedge clk);
            c2pool_ena_a = 1'b0;
            c2pool_wea_a = 1'b0;
            $display("[TB] @ cycle %0d : init_c2pool done", cycle_cnt);
        end
    endtask

    //==========================================================================
    // Task: 1-cycle prior_wdone pulse
    //==========================================================================
    task pulse_prior_wdone;
        begin
            @(negedge clk); prior_wdone = 1'b1;
            @(negedge clk); prior_wdone = 1'b0;
        end
    endtask

    //==========================================================================
    // Task: compare_output — poolfc_mem vs maxpool_ref (byte-by-byte, ch-major)
    //==========================================================================
    integer total_mm;
    task compare_output;
        integer pixel, ch;
        reg [7:0] got, exp;
        begin
            total_mm = 0;
            $display("[TB] Comparing maxpool output (144 pixel x 16 ch = 2304 byte) ...");
            for (pixel = 0; pixel < 144; pixel = pixel + 1) begin
                for (ch = 0; ch < 16; ch = ch + 1) begin
                    got = poolfc_mem[pixel][ch*8 +: 8];
                    exp = maxpool_ref[ch*144 + pixel];        // ch-major file order
                    if (got !== exp) begin
                        total_mm = total_mm + 1;
                        if (total_mm <= 10)
                            $display("  MM @ ch=%0d pixel=%0d : got=%h, exp=%h",
                                     ch, pixel, got, exp);
                    end
                end
            end
        end
    endtask

    //==========================================================================
    // Main stimulus
    //==========================================================================
    initial begin
        $display("[TB] === Maxpool single-image bit-exact test ===");
        $display("[TB] Loading c2pool data : %s", `CONV2_OUT_HEX);
        $readmemh(`CONV2_OUT_HEX,   c2pool_data);
        $display("[TB] Loading ref output  : %s", `MAXPOOL_REF_HEX);
        $readmemh(`MAXPOOL_REF_HEX, maxpool_ref);
        $display("[TB] Loaded c2pool (576 x 128b) + ref (2304 x 8b ch-major)");

        // Reset
        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        // Init c2pool BMG bank 0 (Port A driving)
        init_c2pool();

        // Settle for BMG mem write commit
        repeat (3) @(posedge clk);

        // Pulse prior_wdone -> maxpool data_ready=true -> IDLE->RUN
        pulse_prior_wdone();
        cycle_at_prior = cycle_cnt;
        $display("[TB] @ cycle %0d : prior_wdone pulsed", cycle_at_prior);

        // Wait done
        @(posedge done);
        cycle_at_done = cycle_cnt;
        $display("[TB] @ cycle %0d : done received (compute %0d cycles)",
                 cycle_at_done, cycle_at_done - cycle_at_prior);

        // Settle for poolfc mem write
        repeat (3) @(posedge clk);

        // Compare
        compare_output();

        // Report
        $display("");
        $display("================================================");
        $display("  Maxpool single-image testbench result");
        $display("================================================");
        $display("  prior_wdone   @ cycle %0d", cycle_at_prior);
        $display("  done          @ cycle %0d", cycle_at_done);
        $display("  compute       : %0d cycles", cycle_at_done - cycle_at_prior);
        $display("  mismatches    : %0d / 2304", total_mm);
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
        #100000;     // 10,000 cycle @ 100 MHz — sequential maxpool ~870 cycle + init
        $display("[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
        $finish;
    end

endmodule
