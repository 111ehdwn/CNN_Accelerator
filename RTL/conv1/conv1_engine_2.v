`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv1_engine (Perfect Sync Version)
// Description:
//   - Fixed the premature 'out_sel_r' bug and 1-clk data shift mismatch.
//   - Aligned all control paths (we, addr, sel) with the exact 3-cycle delay
//     of the hardware data path (PE + Adder Tree + Truncate/ReLU).
//////////////////////////////////////////////////////////////////////////////////

module conv1_engine (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output wire        done,

    // ping-pong bank select (외부에서 image 별 토글)
    input  wire        bank_sel,

    // 입력 BRAM (Read, Port B of conv1_input_bram)
    output wire [9:0]        in_bram_addr,
    output wire              in_bram_en,
    input  wire signed [7:0] in_bram_dout,

    // Weight BRAM (Read, Port B of conv1_weight_bram)
    output wire [5:0]  w_bram_addr,
    output wire        w_bram_en,
    input  wire [31:0] w_bram_dout,

<<<<<<< HEAD
    // 출력: 128-bit c1c2 버퍼 인터페이스 (2 pixels per address, byte write enable)
    // 레이아웃: [127:96]=Run2 odd,  [95:64]=Run2 even
    //          [ 63:32]=Run1 odd,  [ 31: 0]=Run1 even
    output wire [8:0]         c1c2_addr,    // pair address (pixel_addr >> 1), max 337
    output wire               c1c2_we,      // write enable (odd pixel 도착 시 1사이클 펄스)
    output wire [15:0]        c1c2_wea,     // byte write enable: Run1=16'h00FF / Run2=16'hFF00
    output wire [127:0]       c1c2_din      // 128-bit 데이터 버스
=======
    // c1c2 BMG Port A (Write, byte-write enable, 64-bit)
    //   Round 0 (sel=0): ch0..3 (= oc0..3) → byte 0..3, wea = 8'b00001111
    //   Round 1 (sel=1): ch4..7 (= oc4..7) → byte 4..7, wea = 8'b11110000
    //   같은 addr 에 2 round 모두 write → BMG byte-write 가 8-byte word merge.
    //   addr 형식: {bank_sel, h[4:0], w[4:0]} padded → bank*1024 + h*32 + w
    output wire        c1c2_we,         // ENA (= 두 round 모두 1)
    output wire [7:0]  c1c2_wea,        // round 별 byte mask
    output wire [10:0] c1c2_addr,       // {bank_sel, h[4:0], w[4:0]}
    output wire [63:0] c1c2_din         // {ch7, ch6, ch5, ch4, ch3, ch2, ch1, ch0}
>>>>>>> 12f287f260ce26553f81628f33c1bef5ec0139cb
);

    //==========================================================================
    // 1. conv1_fsm
    //==========================================================================
    wire        load_start, load_done;
    wire        pipe_en, sel, lb_rst;
    wire        pixel_valid;
    wire [4:0]  out_row, out_col;
    wire        out_valid, out_sel;

    conv1_fsm fsm (
        .clk        (clk),
        .rst        (rst),
        .start      (start),
        .load_start (load_start),
        .load_done  (load_done),
        .pipe_en    (pipe_en),
        .sel        (sel),
        .lb_rst     (lb_rst),
        .pixel_valid(pixel_valid),
        .out_row    (out_row),
        .out_col    (out_col),
        .out_valid  (out_valid),
        .out_sel    (out_sel),
        .done       (done)
    );

    //==========================================================================
    // 2. 입력 BRAM 주소 카운터
    //==========================================================================
    reg [9:0] in_addr;

    always @(posedge clk) begin
        if (rst || lb_rst)
            in_addr <= 10'd0;
        else if (pipe_en) begin
            if (in_addr == 10'd783)
                in_addr <= 10'd0;
            else
                in_addr <= in_addr + 1'b1;
        end
    end

    assign in_bram_addr = in_addr;
    assign in_bram_en   = pipe_en;

    //==========================================================================
    // 3. weight_loader
    //==========================================================================
    wire [24:0]  pe_packed_w;
    wire [17:0]  pe_load_en;
    wire         pe_load_idx;

    conv1_weight_loader #(.NUM_PE(18), .ADDR_W(6)) wloader (
        .clk         (clk),
        .rst         (rst),
        .load_start  (load_start),
        .load_done   (load_done),
        .bram_addr   (w_bram_addr),
        .bram_en     (w_bram_en),
        .bram_dout   (w_bram_dout),
        .pe_packed_w (pe_packed_w),
        .pe_load_en  (pe_load_en),
        .pe_load_idx (pe_load_idx)
    );

    //==========================================================================
    // 4. line_buffer x 2 (27-depth 구동으로 28클럭 지연 유도)
    //
    //   공용 모듈 `line_buffer` (RTL/conv2/) 사용. active-high rst 로 통일됨.
    //   active-low rst_n + active-high lb_rst → 둘 중 하나면 reset:
    //     lb_rst_combined = ~rst_n | lb_rst
    //   (= 옛 `lb_rst_combined_n = rst_n & ~lb_rst` 의 De Morgan 변환)
    //==========================================================================
    wire signed [7:0] lb1_out, lb2_out;
<<<<<<< HEAD
    // active-high 결합: 외부 rst=1 또는 내부 lb_rst=1 이면 리셋
    wire lb_rst_combined = rst | lb_rst;

    conv1_line_buffer #(.WIDTH(8), .DEPTH(27)) lb1 (
=======
    wire lb_rst_combined = ~rst_n | lb_rst;

    line_buffer #(.WIDTH(8), .DEPTH(27)) lb1 (
>>>>>>> 97549af41f2ad568747c77f116cbd6e6bfe5ddac
        .clk(clk), .rst(lb_rst_combined), .en(pipe_en),
        .din(in_bram_dout), .dout(lb1_out)
    );

<<<<<<< HEAD
    conv1_line_buffer #(.WIDTH(8), .DEPTH(27)) lb2 (
=======
    line_buffer #(.WIDTH(8), .DEPTH(27)) lb2 (
>>>>>>> 97549af41f2ad568747c77f116cbd6e6bfe5ddac
        .clk(clk), .rst(lb_rst_combined), .en(pipe_en),
        .din(lb1_out), .dout(lb2_out)
    );

    //==========================================================================
    // 5. window_register
    //
    //   공용 모듈 `window_register` (RTL/conv2/) 사용. active-high rst.
    //==========================================================================
    wire signed [7:0] k0,k1,k2,k3,k4,k5,k6,k7,k8;

<<<<<<< HEAD
    conv1_window_register #(.WIDTH(8)) win (
=======
    window_register #(.WIDTH(8)) win (
>>>>>>> 97549af41f2ad568747c77f116cbd6e6bfe5ddac
        .clk(clk), .rst(lb_rst_combined), .en(pipe_en),
        .row2_in(in_bram_dout), .row1_in(lb1_out), .row0_in(lb2_out),
        .k0(k0),.k1(k1),.k2(k2),
        .k3(k3),.k4(k4),.k5(k5),
        .k6(k6),.k7(k7),.k8(k8)
    );

    wire signed [7:0] kx [0:8];
    assign kx[0]=k0; assign kx[1]=k1; assign kx[2]=k2;
    assign kx[3]=k3; assign kx[4]=k4; assign kx[5]=k5;
    assign kx[6]=k6; assign kx[7]=k7; assign kx[8]=k8;

    //==========================================================================
    // 6. pe_cell x 18  (공용 모듈 `pe_cell` — RTL/core/)
    //
    //   active-high `rst` 로 통일됨 → conv1 의 active-low rst_n 을 `~rst_n` 으로 변환.
    //   PE 는 round 전환 시 weight 유지 필수 → lb_rst 와 결합하지 않음 (시스템 reset 만).
    //==========================================================================
    wire signed [16:0] mul0_g1 [0:8];
    wire signed [16:0] mul1_g1 [0:8];
    wire signed [16:0] mul0_g2 [0:8];
    wire signed [16:0] mul1_g2 [0:8];

    genvar gi;
    generate
        for (gi = 0; gi < 9; gi = gi + 1) begin : gen_g1
<<<<<<< HEAD
            conv1_pe_cell #(.DEPTH(2), .ADDR_W(1)) pe (
                .clk(clk), .rst(rst),
=======
            pe_cell #(.DEPTH(2)) pe (
                .clk(clk), .rst(~rst_n),
>>>>>>> 97549af41f2ad568747c77f116cbd6e6bfe5ddac
                .packed_w(pe_packed_w),
                .load_idx(pe_load_idx),
                .load_en(pe_load_en[gi]),
                .sel(sel),
                .en(pipe_en),
                .x(kx[gi]),
                .mul0(mul0_g1[gi]),
                .mul1(mul1_g1[gi])
            );
        end
        for (gi = 0; gi < 9; gi = gi + 1) begin : gen_g2
<<<<<<< HEAD
            conv1_pe_cell #(.DEPTH(2), .ADDR_W(1)) pe (
                .clk(clk), .rst(rst),
=======
            pe_cell #(.DEPTH(2)) pe (
                .clk(clk), .rst(~rst_n),
>>>>>>> 97549af41f2ad568747c77f116cbd6e6bfe5ddac
                .packed_w(pe_packed_w),
                .load_idx(pe_load_idx),
                .load_en(pe_load_en[gi+9]),
                .sel(sel),
                .en(pipe_en),
                .x(kx[gi]),
                .mul0(mul0_g2[gi]),
                .mul1(mul1_g2[gi])
            );
        end
    endgenerate

    //==========================================================================
    // 7. adder_tree x 2 (1클럭 내부 레지스터 지연 포함)
    //   Conv1 전용 (9:2 토폴로지). RTL/conv1/conv1_adder_tree.v.
    //==========================================================================
    wire signed [23:0] sum0_g1, sum1_g1, sum0_g2, sum1_g2;

    conv1_adder_tree at_g1 (
        .clk(clk), .rst(rst), .en(pipe_en),
        .mul0_0(mul0_g1[0]),.mul0_1(mul0_g1[1]),.mul0_2(mul0_g1[2]),
        .mul0_3(mul0_g1[3]),.mul0_4(mul0_g1[4]),.mul0_5(mul0_g1[5]),
        .mul0_6(mul0_g1[6]),.mul0_7(mul0_g1[7]),.mul0_8(mul0_g1[8]),
        .mul1_0(mul1_g1[0]),.mul1_1(mul1_g1[1]),.mul1_2(mul1_g1[2]),
        .mul1_3(mul1_g1[3]),.mul1_4(mul1_g1[4]),.mul1_5(mul1_g1[5]),
        .mul1_6(mul1_g1[6]),.mul1_7(mul1_g1[7]),.mul1_8(mul1_g1[8]),
        .sum0(sum0_g1), .sum1(sum1_g1)
    );

<<<<<<< HEAD
    _conv1_adder_tree at_g2 (
        .clk(clk), .rst(rst), .en(pipe_en),
=======
    conv1_adder_tree at_g2 (
        .clk(clk), .rst_n(rst_n), .en(pipe_en),
>>>>>>> 97549af41f2ad568747c77f116cbd6e6bfe5ddac
        .mul0_0(mul0_g2[0]),.mul0_1(mul0_g2[1]),.mul0_2(mul0_g2[2]),
        .mul0_3(mul0_g2[3]),.mul0_4(mul0_g2[4]),.mul0_5(mul0_g2[5]),
        .mul0_6(mul0_g2[6]),.mul0_7(mul0_g2[7]),.mul0_8(mul0_g2[8]),
        .mul1_0(mul1_g2[0]),.mul1_1(mul1_g2[1]),.mul1_2(mul1_g2[2]),
        .mul1_3(mul1_g2[3]),.mul1_4(mul1_g2[4]),.mul1_5(mul1_g2[5]),
        .mul1_6(mul1_g2[6]),.mul1_7(mul1_g2[7]),.mul1_8(mul1_g2[8]),
        .sum0(sum0_g2), .sum1(sum1_g2)
    );

    //==========================================================================
    // 8. truncate_relu (공용 모듈 — RTL/core/truncate_relu.v, N=4)
    //
    //   Channel 매핑: ch0=sum0_g1, ch1=sum1_g1, ch2=sum0_g2, ch3=sum1_g2
    //   (Conv1 design.md §5-4 참조)
    //==========================================================================
    wire [95:0] tr_sum_flat = {sum1_g2, sum0_g2, sum1_g1, sum0_g1};
    wire [31:0] tr_out_flat;

<<<<<<< HEAD
    conv1_truncate_relu tr (
        .clk(clk), .rst(rst), .en(pipe_en),
        .sum0(sum0_g1), .sum1(sum1_g1),
        .sum2(sum0_g2), .sum3(sum1_g2),
        .out0(tr_out0), .out1(tr_out1),
        .out2(tr_out2), .out3(tr_out3)
=======
    wire signed [7:0] tr_out0 = tr_out_flat[ 7: 0];
    wire signed [7:0] tr_out1 = tr_out_flat[15: 8];
    wire signed [7:0] tr_out2 = tr_out_flat[23:16];
    wire signed [7:0] tr_out3 = tr_out_flat[31:24];

    truncate_relu #(.N(4)) tr (
        .clk      (clk),
        .rst      (~rst_n),
        .en       (pipe_en),
        .sum_flat (tr_sum_flat),
        .out_flat (tr_out_flat)
>>>>>>> 97549af41f2ad568747c77f116cbd6e6bfe5ddac
    );

    //==========================================================================
<<<<<<< HEAD
    // 9. 제어 신호 동기화 3단 파이프라인 + 짝수 픽셀 버퍼
    //==========================================================================
    // 데이터 레지스터 (tr_out → ch_final, 1클럭)
    reg signed [7:0] ch0_final, ch1_final, ch2_final, ch3_final;

    // 제어 신호 3비트 시프트 레지스터
    reg [2:0] we_pipe;
    reg [2:0] sel_pipe;

    // 주소 3단 파이프라인
=======
    // 9. 제어 신호 동기화를 위한 3단 파이프라인 시프트 체인
    //   chX_final: tr_outX 의 1 cycle 지연 latch (round 0 용)
    //   round 1 은 tr_outX 직접 사용 (1 cycle 보정)
    //==========================================================================
    reg signed [7:0] ch0_final, ch1_final, ch2_final, ch3_final;

    reg [2:0] we_pipe;
    reg [2:0] sel_pipe;

    // padded 형식 주소: h*32+w (BMG bank addr 의 하위 10-bit). 26 valid + 6 pad.
>>>>>>> 12f287f260ce26553f81628f33c1bef5ec0139cb
    reg [9:0] addr_pipe [0:2];

    // 짝수 픽셀 데이터 버퍼 (128-bit 출력용)
    // [63:32] = Run2 even pixel (tr_out 타이밍)
    // [31: 0] = Run1 even pixel (ch_final 타이밍)
    reg [63:0] pixel_buf;

    // 현재 픽셀의 32-bit packed 데이터
    wire [31:0] cur_r1 = {ch3_final, ch2_final, ch1_final, ch0_final}; // Run1: ch_final
    wire [31:0] cur_r2 = {tr_out3,   tr_out2,   tr_out1,   tr_out0};   // Run2: direct tr_out

    always @(posedge clk) begin
        if (rst) begin
            ch0_final <= 8'sd0; ch1_final <= 8'sd0;
            ch2_final <= 8'sd0; ch3_final <= 8'sd0;
<<<<<<< HEAD
            we_pipe      <= 3'b000;
            sel_pipe     <= 3'b000;
=======

            we_pipe   <= 3'b000;
            sel_pipe  <= 3'b000;
>>>>>>> 12f287f260ce26553f81628f33c1bef5ec0139cb
            addr_pipe[0] <= 10'd0; addr_pipe[1] <= 10'd0; addr_pipe[2] <= 10'd0;
            pixel_buf    <= 64'd0;
        end else begin
<<<<<<< HEAD
            // 1) 데이터 패스: tr_out → ch_final (1클럭 레지스터)
=======
>>>>>>> 12f287f260ce26553f81628f33c1bef5ec0139cb
            ch0_final <= tr_out0;
            ch1_final <= tr_out1;
            ch2_final <= tr_out2;
            ch3_final <= tr_out3;

<<<<<<< HEAD
            // 2) 제어 패스: 3클럭 파이프라인
            we_pipe  <= {we_pipe[1:0],  out_valid};
            sel_pipe <= {sel_pipe[1:0], out_sel};
            addr_pipe[0] <= out_row * 10'd26 + {5'd0, out_col};
=======
            we_pipe  <= {we_pipe[1:0],  out_valid};
            sel_pipe <= {sel_pipe[1:0], out_sel};

            // padded h*32+w (multiplier 제거 → shift+concat)
            addr_pipe[0] <= {out_row[4:0], out_col[4:0]};
>>>>>>> 12f287f260ce26553f81628f33c1bef5ec0139cb
            addr_pipe[1] <= addr_pipe[0];
            addr_pipe[2] <= addr_pipe[1];

            // 3) 짝수 픽셀(addr[0]=0) 도착 시 두 라운드 데이터를 함께 버퍼링
            if (we_pipe[2] && !addr_pipe[2][0])
                pixel_buf <= {cur_r2, cur_r1};
        end
    end

    //==========================================================================
<<<<<<< HEAD
    // 10. 128-bit c1c2 출력 매핑
    //     [127:96] = Run2 odd  pixel {tr_out3, tr_out2, tr_out1, tr_out0}
    //     [ 95:64] = Run2 even pixel (pixel_buf[63:32])
    //     [ 63:32] = Run1 odd  pixel {ch3_final, ch2_final, ch1_final, ch0_final}
    //     [ 31: 0] = Run1 even pixel (pixel_buf[31:0])
    //
    //     c1c2_we  : 홀수 픽셀(addr_pipe[2][0]=1)일 때만 1사이클 HIGH
    //     c1c2_wea : Run1 → 16'h00FF (하위 64bit), Run2 → 16'hFF00 (상위 64bit)
    //==========================================================================
    assign c1c2_addr = addr_pipe[2][9:1];
    assign c1c2_we   = we_pipe[2] & addr_pipe[2][0];
    assign c1c2_wea  = sel_pipe[2] ? 16'hFF00 : 16'h00FF;
    assign c1c2_din  = {cur_r2, pixel_buf[63:32], cur_r1, pixel_buf[31:0]};

=======
    // 10. c1c2 BMG Port A 결선
    //
    //   Round 0 (sel_pipe[2]=0): ch0..3 (oc0..3) → byte 0..3, wea = 8'b00001111
    //     - ch0..3 데이터는 ch*_final (1 cycle 지연된 latch) 사용
    //   Round 1 (sel_pipe[2]=1): ch4..7 (oc4..7) → byte 4..7, wea = 8'b11110000
    //     - ch4..7 데이터는 tr_out0..3 직접 (= 1 cycle 보정: round 2 가 round 1 보다
    //       1 cycle 늦게 정렬되는 현상 상쇄)
    //
    //   같은 addr 에 두 round 모두 write → BMG 의 byte-write 가 8-byte word merge.
    //
    //   addr 형식: {bank_sel, addr_pipe[2]} = {bank, h[4:0], w[4:0]}
    //==========================================================================
    wire round0_active = (sel_pipe[2] == 1'b0);

    wire [63:0] din_round0 = {32'd0,
                              ch3_final, ch2_final, ch1_final, ch0_final};
    wire [63:0] din_round1 = {tr_out3, tr_out2, tr_out1, tr_out0,
                              32'd0};

    assign c1c2_we   = we_pipe[2];
    assign c1c2_wea  = round0_active ? 8'b00001111 : 8'b11110000;
    assign c1c2_addr = {bank_sel, addr_pipe[2]};
    assign c1c2_din  = round0_active ? din_round0 : din_round1;

>>>>>>> 12f287f260ce26553f81628f33c1bef5ec0139cb
endmodule