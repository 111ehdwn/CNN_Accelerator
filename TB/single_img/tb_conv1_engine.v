`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_conv1_engine  (BMG IP version)
//
//   BMG IP 3개 인스턴스:
//     conv1_input_bram  — 8-bit  × 1024, SDP, L=2 (Port B output register)
//     conv1_weight_bram — 32-bit × 64,   SDP, L=2 (REGCEB 노출, 항상 1)
//     bram_c1_to_c2     — 64-bit × 2048, SDP, byte-write wea[7:0], L=2
//
//   c1c2 BRAM 레이아웃 (64-bit per pixel):
//     [31: 0] = {ch3, ch2, ch1, ch0}  (Round 0, wea=8'b00001111)
//     [63:32] = {ch7, ch6, ch5, ch4}  (Round 1, wea=8'b11110000)
//     addr    = {bank_sel[0], row[4:0], col[4:0]}
//
//   저장 형식: 채널 순 676개씩 → 총 8×676 = 5408줄 (hex)
//////////////////////////////////////////////////////////////////////////////////

`define CONV1_INPUT_HEX   "conv1_input.hex"
`define CONV1_WEIGHT_HEX  "conv1_weight.mem"

module tb_conv1_engine;

    //==========================================================================
    // 1. 클럭 / 리셋
    //==========================================================================
    reg clk = 0;
    reg rst = 1;        // active-high: 1=리셋, 0=정상동작
    always #5 clk = ~clk;  // 100 MHz

    //==========================================================================
    // 2. DUT 신호
    //==========================================================================
    reg  start    = 0;
    wire done;
    wire bank_sel_w = 1'b0;   // single-image: bank 0 고정

    // conv1_input_bram  Port A (TB write) / Port B (DUT read)
    reg         in_ena   = 0;
    reg         in_wea   = 0;
    reg  [9:0]  in_addra = 0;
    reg  [7:0]  in_dina  = 0;
    wire [9:0]  in_addrb;
    wire        in_enb;
    wire signed [7:0] in_doutb;

    // conv1_weight_bram  Port A (TB write) / Port B (DUT read)
    reg         w_ena    = 0;
    reg         w_wea    = 0;
    reg  [5:0]  w_addra  = 0;
    reg  [31:0] w_dina   = 0;
    wire [5:0]  w_addrb;
    wire        w_enb;
    wire [31:0] w_doutb;

    // bram_c1_to_c2  Port A (DUT write) / Port B (TB read)
    wire         c1c2_we;
    wire [7:0]   c1c2_wea;
    wire [10:0]  c1c2_addr;
    wire [63:0]  c1c2_din;
    reg          c1c2_enb   = 0;
    reg  [10:0]  c1c2_addrb = 0;
    wire [63:0]  c1c2_doutb;

    //==========================================================================
    // 3. DUT 인스턴스
    //==========================================================================
    conv1_engine dut (
        .clk         (clk),
        .rst         (rst),
        .start       (start),
        .done        (done),
        .bank_sel    (bank_sel_w),
        // input BRAM Port B
        .in_bram_addr(in_addrb),
        .in_bram_en  (in_enb),
        .in_bram_dout(in_doutb),
        // weight BRAM Port B
        .w_bram_addr (w_addrb),
        .w_bram_en   (w_enb),
        .w_bram_dout (w_doutb),
        // c1c2 BRAM Port A (write)
        .c1c2_we     (c1c2_we),
        .c1c2_wea    (c1c2_wea),
        .c1c2_addr   (c1c2_addr),
        .c1c2_din    (c1c2_din)
    );

    //==========================================================================
    // 4. BMG IP 인스턴스
    //    ※ Vivado IP 이름 / 포트 이름이 다를 경우 맞춰서 수정
    //==========================================================================

    // 8-bit × 1024, SDP, L=2
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

    // 32-bit × 64, SDP, L=2, REGCEB 항상 1
    conv1_weight_bram w_bmg (
        .clka   (clk),
        .ena    (w_ena),
        .wea    (w_wea),
        .addra  (w_addra),
        .dina   (w_dina),
        .clkb   (clk),
        .enb    (w_enb),
        .addrb  (w_addrb),
        .doutb  (w_doutb),
        .regceb (1'b1)
    );

    // 64-bit × 2048, SDP, byte-write wea[7:0], L=2
    bram_c1_to_c2 c1c2_bmg (
        .clka  (clk),
        .ena   (c1c2_we),
        .wea   (c1c2_wea),
        .addra (c1c2_addr),
        .dina  (c1c2_din),
        .clkb  (clk),
        .enb   (c1c2_enb),
        .addrb (c1c2_addrb),
        .doutb (c1c2_doutb)
    );

    //==========================================================================
    // 5. 로컬 메모리 (BRAM 초기화 용)
    //==========================================================================
    reg [7:0]  input_mem  [0:783];    // 28×28 입력 이미지
    reg [31:0] weight_mem [0:35];     // conv1 packed weight 36개

    //==========================================================================
    // 6. BRAM 초기화 태스크
    //==========================================================================

    // conv1_input_bram Port A 를 통해 784픽셀 기록
    task init_input_bram;
        integer i;
        begin
            @(posedge clk); #1;
            for (i = 0; i < 784; i = i + 1) begin
                in_ena   = 1;
                in_wea   = 1;
                in_addra = i[9:0];
                in_dina  = input_mem[i];
                @(posedge clk); #1;
            end
            in_ena = 0; in_wea = 0;
            @(posedge clk);
        end
    endtask

    // conv1_weight_bram Port A 를 통해 36엔트리 기록
    task init_weight_bram;
        integer i;
        begin
            @(posedge clk); #1;
            for (i = 0; i < 36; i = i + 1) begin
                w_ena   = 1;
                w_wea   = 1;
                w_addra = i[5:0];
                w_dina  = weight_mem[i];
                @(posedge clk); #1;
            end
            w_ena = 0; w_wea = 0;
            @(posedge clk);
        end
    endtask

    //==========================================================================
    // 7. 결과 저장 태스크
    //    c1c2 BRAM Port B 로 26×26 전체 읽어서 conv1_out.hex 저장
    //    레이아웃: word[ch*8 +: 8]  (ch0~3 = [31:0], ch4~7 = [63:32])
    //==========================================================================
    reg [7:0]  out_buf [0:7][0:675];  // [채널][픽셀]
    integer    fd, ch, row, col, px;

    task save_result;
        reg [10:0] addr;
        reg [63:0] word;
        begin
            // Port B 로 순차 읽기 (L=2 → 2클럭 대기)
            for (row = 0; row < 26; row = row + 1) begin
                for (col = 0; col < 26; col = col + 1) begin
                    addr       = {1'b0, row[4:0], col[4:0]};
                    c1c2_addrb = addr;
                    c1c2_enb   = 1;
                    @(posedge clk);
                    @(posedge clk);  // L=2 latency
                    #1;
                    word = c1c2_doutb;
                    px   = row * 26 + col;
                    for (ch = 0; ch < 8; ch = ch + 1)
                        out_buf[ch][px] = word[ch*8 +: 8];
                end
            end
            c1c2_enb = 0;

            // 파일 저장 (채널 순, 676개씩)
            fd = $fopen("conv1_out.hex", "w");
            for (ch = 0; ch < 8; ch = ch + 1)
                for (px = 0; px < 676; px = px + 1)
                    $fwrite(fd, "%02x\n", out_buf[ch][px]);
            $fclose(fd);

            $display("[TB] conv1_out.hex saved.");
        end
    endtask

    //==========================================================================
    // 8. 자극 시퀀스
    //==========================================================================
    initial begin
        $readmemh(`CONV1_INPUT_HEX,  input_mem);
        $readmemh(`CONV1_WEIGHT_HEX, weight_mem);

        // 리셋
        repeat(5) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);

        // BRAM 초기화
        init_input_bram;
        init_weight_bram;
        repeat(2) @(posedge clk);

        // start 펄스
        start = 1; @(posedge clk); start = 0;

        // done 대기
        wait(done);
        repeat(5) @(posedge clk);

        // 결과 저장
        save_result;

        $display("[TB] done at %0t ns.", $time);
        #20 $finish;
    end

    //==========================================================================
    // 9. 타임아웃
    //==========================================================================
    initial begin
        repeat(8000) @(posedge clk);
        $display("[TB] TIMEOUT");
        $finish;
    end

endmodule
