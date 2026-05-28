`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
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
//////////////////////////////////////////////////////////////////////////////////

module tb_conv1_engine;

    //==========================================================================
    // 1. 클럭 / 리셋
    //==========================================================================
    reg clk   = 0;
    reg rst = 1;     // active-high: 1=리셋, 0=정상동작
    reg start = 0;

    always #5 clk = ~clk;   // 10ns = 100MHz

    //==========================================================================
    // 2. DUT 포트 선언
    //==========================================================================
    wire        done;

    wire [9:0]        in_bram_addr;
    wire              in_bram_en;
    wire signed [7:0] in_bram_dout;

    wire [5:0]  w_bram_addr;
    wire        w_bram_en;
    wire [31:0] w_bram_dout;

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
    //==========================================================================
    reg [31:0] w_mem [0:63];
    initial $readmemh("conv1_weight.mem", w_mem);

    reg [31:0] w_pipe1, w_pipe2;
    always @(posedge clk) begin
        w_pipe1 <= w_mem[w_bram_addr];
        w_pipe2 <= w_pipe1;
    end
    assign w_bram_dout = w_pipe2;

    //==========================================================================
    // 5. BRAM 모델 — input image BRAM (latency=1)
    //==========================================================================
    reg [7:0] in_mem [0:783];
    initial $readmemh("input_image.mem", in_mem);

    reg [7:0] in_pipe;
    always @(posedge clk)
        in_pipe <= in_mem[in_bram_addr];
    assign in_bram_dout = $signed(in_pipe);

    //==========================================================================
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
            end
        end
    end

    //==========================================================================
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
        end
    end

    //==========================================================================
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
        $finish;
    end

endmodule
