`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_maxpool_engine
//   - conv2_out.hex          : conv2 HW 출력 → c2pool buffer에 packed 로드
//   - python_maxpool_ref.hex : Python 레퍼런스 (post-sim 비교)
//   - maxpool_out.hex        : HW 출력 저장
//
// 입력  c2pool : 128-bit × 576 (24×24), L=1 BRAM latency
// 출력 poolfc  : 128-bit × 144 (12×12), 캡처 후 비교
// 비교 총량    : 16채널 × 144픽셀 = 2304
//////////////////////////////////////////////////////////////////////////////////

module tb_maxpool_engine;

    //==========================================================================
    // 1. Clock / Reset / Control
    //==========================================================================
    reg clk = 0;
    reg rst = 1;
    reg start = 0;

    always #5 clk = ~clk;   // 10ns → 100MHz

    //==========================================================================
    // 2. DUT 포트 선언
    //==========================================================================
    wire         done;

    // c2pool 인터페이스 (DUT가 읽음)
    wire [10:0]  c2pool_rd_addr;
    wire         c2pool_rd_en;
    reg  signed [127:0] c2pool_rd_data;
    reg          c2pool_bank_sel = 1'b0;

    // poolfc 인터페이스 (DUT가 씀)
    wire [8:0]   poolfc_wr_addr;
    wire         poolfc_wr_en;
    wire [127:0] poolfc_wr_data;
    reg          poolfc_bank_sel = 1'b0;

    //==========================================================================
    // 3. DUT 인스턴스
    //==========================================================================
    maxpool_engine dut (
        .clk             (clk),
        .rst             (rst),
        .start           (start),
        .done            (done),

        .c2pool_rd_addr  (c2pool_rd_addr),
        .c2pool_rd_en    (c2pool_rd_en),
        .c2pool_rd_data  (c2pool_rd_data),
        .c2pool_bank_sel (c2pool_bank_sel),

        .poolfc_wr_addr  (poolfc_wr_addr),
        .poolfc_wr_en    (poolfc_wr_en),
        .poolfc_wr_data  (poolfc_wr_data),
        .poolfc_bank_sel (poolfc_bank_sel)
    );

    //==========================================================================
    // 4. c2pool behavioral BRAM (L=1, 128-bit)
    //    주소: base(0 or 576) + in_row*24 + in_col
    //    FSM: phase0에서 주소 요청 → phase1 posedge에서 BRAM이 데이터 드라이브
    //         → phase2 posedge에서 FSM이 캡처
    //==========================================================================
    reg [127:0] c2pool_mem [0:1151];   // bank0: 0~575, bank1: 576~1151

    always @(posedge clk) begin
        if (c2pool_rd_en)
            c2pool_rd_data <= c2pool_mem[c2pool_rd_addr];
    end

    //==========================================================================
    // 5. poolfc 캡처 버퍼
    //    poolfc_wr_addr = {poolfc_bank_sel(0), out_addr[7:0]}
    //    out_addr = out_row*12 + out_col  (0~143)
    //==========================================================================
    reg [127:0] poolfc_mem [0:511];

    always @(posedge clk) begin
        if (poolfc_wr_en)
            poolfc_mem[poolfc_wr_addr] <= poolfc_wr_data;
    end

    //==========================================================================
    // 6. 검증 버퍼
    //    python_ref[ch][r] : 채널 ch, 주소 r = row*12 + col
    //==========================================================================
    reg [7:0] python_ref [0:15][0:143];

    integer match_count    = 0;
    integer mismatch_count = 0;

    //==========================================================================
    // 7. conv2_out.hex 로드 → c2pool_mem 패킹
    //    conv2_out.hex 형식: ch0[0..575], ch1[0..575], ..., ch15[0..575]
    //    r = row*24 + col
    //
    //    c2pool_mem[r][ch*8 +: 8] = 채널 ch, 픽셀 r 값
    //    (maxpool_fsm rd_addr = base + in_row*24 + in_col 에 맞춤)
    //==========================================================================
    reg [7:0] conv2_flat [0:9215];   // 16채널 × 576픽셀

    integer ch, r, i;

    task load_c2pool_buffer;
        begin
            for (i = 0; i < 1152; i = i + 1)
                c2pool_mem[i] = 128'd0;

            for (ch = 0; ch < 16; ch = ch + 1) begin
                for (r = 0; r < 576; r = r + 1) begin
                    c2pool_mem[r][ch*8 +: 8] = conv2_flat[ch * 576 + r];
                end
            end
        end
    endtask

    //==========================================================================
    // 8. Main
    //==========================================================================
    integer fd;
    integer hw_val, py_val;

    initial begin
        $display("\n====== [START] MaxPool Simulation Setup & File Loading ======");

        // [8-1] conv2 출력 로드 → c2pool buffer 패킹
        conv2_flat[0] = 8'hxx;
        $readmemh("conv2_out.hex", conv2_flat);
        if (conv2_flat[0] === 8'hxx) begin
            $display("[FILE ERROR] Failed to load 'conv2_out.hex'!");
            $finish;
        end
        $display("[FILE SUCCESS] 'conv2_out.hex' loaded.");
        load_c2pool_buffer();
        $display("[INFO] c2pool buffer packed (24x24 x 16ch -> 128-bit words).");

        // [8-2] Python 레퍼런스 로드
        python_ref[0][0] = 8'hxx;
        $readmemh("python_maxpool_ref.hex", python_ref);
        if (python_ref[0][0] === 8'hxx) begin
            $display("[FILE ERROR] Failed to load 'python_maxpool_ref.hex'!");
            $finish;
        end
        $display("[FILE SUCCESS] 'python_maxpool_ref.hex' loaded.");
        $display("=============================================================\n");

        // [8-3] 리셋
        rst = 1;
        repeat(5) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);

        // [8-4] start 펄스
        @(negedge clk);
        start = 1;
        $display("[%0t ns] >> MaxPool Engine Started.", $time);
        @(negedge clk);
        start = 0;

        // [8-5] done 대기
        wait (done == 1'b1);
        repeat(3) @(posedge clk);

        $display("[%0t ns] -> done detected. Running verification...", $time);

        // [8-6] poolfc_mem vs python_ref 비교
        //   poolfc_wr_addr = {poolfc_bank_sel(0), out_addr}
        //   out_addr = out_row*12 + out_col  (r = 0~143)
        //   poolfc_mem[r][ch*8 +: 8] = 채널 ch, 픽셀 r
        for (ch = 0; ch < 16; ch = ch + 1) begin
            for (r = 0; r < 144; r = r + 1) begin
                hw_val = poolfc_mem[r][ch*8 +: 8];
                py_val = python_ref[ch][r];

                if (hw_val === py_val) begin
                    match_count = match_count + 1;
                end else begin
                    mismatch_count = mismatch_count + 1;
                    $display("[MISMATCH] Ch:%02d Addr:%3d(row=%0d,col=%0d) | HW:%02x != PY:%02x",
                             ch, r, r/12, r%12, hw_val, py_val);
                end
            end
        end

        // [8-7] 최종 리포트
        $display("\n==================================================");
        $display("          MaxPool H/W vs Python Report            ");
        $display("==================================================");
        $display("  - MATCH COUNT    : %0d / 2304", match_count);
        $display("  - MISMATCH COUNT : %0d / 2304", mismatch_count);
        $display("--------------------------------------------------");
        if (mismatch_count == 0 && match_count == 2304) begin
            $display("  >> [PASS] H/W results match Python 100%% perfectly!");
        end else begin
            $display("  >> [FAIL] Errors detected! Please check the waveforms.");
        end
        $display("==================================================\n");

        // [8-8] HW 출력 저장
        fd = $fopen("maxpool_out.hex", "w");
        for (ch = 0; ch < 16; ch = ch + 1) begin
            for (r = 0; r < 144; r = r + 1) begin
                $fwrite(fd, "%02x\n", poolfc_mem[r][ch*8 +: 8] & 8'hFF);
            end
        end
        $fclose(fd);
        $display("=== 'maxpool_out.hex' saved successfully. ===");

        #50;
        $finish;
    end

    //==========================================================================
    // 9. Watchdog Timeout
    //    144픽셀 × 6phase = 864 cycles + flush 6 + margin → 200us 충분
    //==========================================================================
    initial begin
        #200000;
        $display("[TIMEOUT ERROR] done not asserted within 200us.");
        $finish;
    end

endmodule
