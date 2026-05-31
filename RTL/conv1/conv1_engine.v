`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv1_engine
// Description:
//   - Fixed the premature 'out_sel_r' bug and 1-clk data shift mismatch.
//   - Aligned all control paths (we, addr, sel) with the exact 3-cycle delay
//     of the hardware data path (PE + Adder Tree + Truncate/ReLU).
//   - 4-way handshake (prior_wdone / succ_rdone / rdone / wdone) + internal
//     ping-pong bank (input_bank_sel / bank_sel toggle FF on rdone / wdone).
//   - bank_sel 은 addr_pipe 와 같은 3-stage shift (bank_sel_pipe) 통해
//     c1c2_addr 에 사용 → wdone 직후의 we_pipe trailing 마지막 write 가
//     새 bank 로 들어가는 race 봉쇄. docs/conv1_timing_table.md 참조.
//////////////////////////////////////////////////////////////////////////////////

module conv1_engine (
    input  wire        clk,
    input  wire        rst,                  // active-high synchronous (시스템 통일)
    input  wire        start,                // legacy system init (사용 X)
    output wire        done,                 // legacy (debug)

    // 4-way handshake (conv2/maxpool 패턴, race-free)
    //   prior_wdone : 외부에서 image 시작 trigger (TB 또는 PS)
    //   succ_rdone  : Conv2.rdone direct wire (c1c2 read 완료 알림)
    //   rdone       : Conv1 의 input bram read 완료 1-cycle pulse
    //   wdone       : Conv1 의 c1c2 write 완료 1-cycle pulse → Conv2.prior_wdone direct wire
    input  wire        prior_wdone,
    input  wire        succ_rdone,
    output wire        rdone,
    output wire        wdone,

    // ping-pong bank — 내부 toggle FF (race-free)
    //   conv2 와 동일 패턴: input_bank_sel = rdone count[0], bank_sel = wdone count[0]
    //   외부에서 driving 하지 않으므로 dispatcher 가 도중에 bank 를 덮어쓰는 race 없음.
    //   필요하면 debug 용 output 으로 노출 가능 (현재는 internal-only).

    // 입력 BRAM (Read, Port B of bram_input, depth 2048 = 2 bank × 1024)
    output wire [10:0]       in_bram_addr,    // {input_bank_sel, in_addr[9:0]}
    output wire              in_bram_en,
    input  wire signed [7:0] in_bram_dout,

    // Weight BRAM (Read, Port B of conv1_weight_bram)
    output wire [5:0]  w_bram_addr,
    output wire        w_bram_en,
    input  wire [31:0] w_bram_dout,

    // c1c2 BMG Port A (Write, byte-write enable, 64-bit)
    //   Round 0 (sel=0): ch0..3 (= oc0..3) → byte 0..3, wea = 8'b00001111
    //   Round 1 (sel=1): ch4..7 (= oc4..7) → byte 4..7, wea = 8'b11110000
    //   같은 addr 에 2 round 모두 write → BMG byte-write 가 8-byte word merge.
    //   addr 형식: {bank_sel, h[4:0], w[4:0]} padded → bank*1024 + h*32 + w
    output wire        c1c2_we,         // ENA (= 두 round 모두 1)
    output wire [7:0]  c1c2_wea,        // round 별 byte mask
    output wire [10:0] c1c2_addr,       // {bank_sel, h[4:0], w[4:0]}
    output wire [63:0] c1c2_din         // {ch7, ch6, ch5, ch4, ch3, ch2, ch1, ch0}
);

    //==========================================================================
    // 1. conv1_fsm
    //==========================================================================
    wire        load_start, load_done;
    wire        pipe_en, sel, lb_rst;
    wire [4:0]  out_row, out_col;
    wire        out_valid, out_sel;

    conv1_fsm fsm (
        .clk          (clk),
        .rst          (rst),
        .start        (start),
        .prior_wdone  (prior_wdone),
        .succ_rdone   (succ_rdone),
        .rdone        (rdone),
        .wdone        (wdone),
        .load_start   (load_start),
        .load_done    (load_done),
        .pipe_en      (pipe_en),
        .sel          (sel),
        .lb_rst       (lb_rst),
        .out_row      (out_row),
        .out_col      (out_col),
        .out_valid    (out_valid),
        .out_sel      (out_sel),
        .done         (done)
    );

    //==========================================================================
    // 1.5. Ping-pong bank toggle FF (internal, race-free)
    //
    //   conv2_fsm 패턴 차용 (RTL/conv2/conv2_fsm.v §8):
    //     input_bank_sel : bram_input 의 read bank — rdone (input read 완료) 시 토글
    //     bank_sel       : c1c2 BMG  의 write bank — wdone (c1c2 write 완료) 시 토글
    //
    //   rdone / wdone 은 image 당 1-cycle pulse (FSM 의 RUN2→FLUSH2 / DONE 에서 NBA<=1).
    //   따라서 image 별로 정확히 한 번 토글되며, image 처리 도중에는 stable.
    //   bram_input write side 의 bank 는 외부 (TB / PS) 가 image 카운터 LSB 로 맞춰주면
    //   같은 시작점 (reset 후 둘 다 0) 에서 1씩 증가하므로 자동 sync 된다.
    //==========================================================================
    reg input_bank_sel;
    reg bank_sel;

    always @(posedge clk) begin
        if (rst)
            input_bank_sel <= 1'b0;
        else if (rdone)
            input_bank_sel <= ~input_bank_sel;
    end

    always @(posedge clk) begin
        if (rst)
            bank_sel <= 1'b0;
        else if (wdone)
            bank_sel <= ~bank_sel;
    end

    //==========================================================================
    // 2. 입력 BRAM 주소 카운터
    //
    //   ★ Image 단위 reset: 새 image 처리 시작 시 in_addr=0.
    //   conv2 의 row_cnt/col_cnt reset at DRAIN end (state == DRAIN && drain_cnt == 11)
    //   과 같은 image-end reset 패턴. (RTL/conv2/conv2_fsm.v §6 참조)
    //
    //   조건:
    //     - rst              : system reset
    //     - lb_rst           : RUN1 → RUN2 사이 LBRST (round 전환)
    //     - bank_change      : input_bank_sel toggle edge (rdone 직후, FLUSH2 중)
    //     - load_start       : IDLE→LOAD 전환 (image 처리 시작점, 가장 안전)
    //
    //   이전 image 의 FLUSH2 trailing 으로 in_addr 가 비-0 으로 남으면 다음 image 의
    //   RUN1 read 가 shift 되어 conv1 출력 전체가 column-offset 됨 → multi-image 시뮬
    //   img 1+ 의 c1c2 round 0 corruption 의 직접 원인.
    //
    //   bank_change 만으로는 FLUSH2 의 잔여 4 cycle 증가분 때문에 in_addr=4 로 남음.
    //   load_start (= 다음 image 의 LOAD 진입) 가 추가로 0 으로 리셋해서 RUN1 first
    //   cycle 에 in_addr=0 보장.
    //==========================================================================
    reg [9:0] in_addr;
    reg       input_bank_sel_d;

    wire bank_change = (input_bank_sel != input_bank_sel_d);

    always @(posedge clk) begin
        if (rst) input_bank_sel_d <= 1'b0;
        else     input_bank_sel_d <= input_bank_sel;
    end

    always @(posedge clk) begin
        if (rst || lb_rst || bank_change || load_start)
            in_addr <= 10'd0;
        else if (pipe_en) begin
            if (in_addr == 10'd783)
                in_addr <= 10'd0;
            else
                in_addr <= in_addr + 1'b1;
        end
    end

    // bank_sel prepended → 11-bit addr for BMG ping-pong
    assign in_bram_addr = {input_bank_sel, in_addr};
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
    //   공용 모듈 `line_buffer` (RTL/core/) 사용. active-high rst 통일.
    //   lb_rst_combined = rst | lb_rst (시스템 rst 또는 RUN2 전 lb_rst 둘 중 하나)
    //==========================================================================
    wire signed [7:0] lb1_out, lb2_out;
    wire lb_rst_combined = rst | lb_rst;

    line_buffer #(.WIDTH(8), .DEPTH(27)) lb1 (
        .clk(clk), .rst(lb_rst_combined), .en(pipe_en),
        .din(in_bram_dout), .dout(lb1_out)
    );

    line_buffer #(.WIDTH(8), .DEPTH(27)) lb2 (
        .clk(clk), .rst(lb_rst_combined), .en(pipe_en),
        .din(lb1_out), .dout(lb2_out)
    );

    //==========================================================================
    // 5. window_register
    //
    //   공용 모듈 `window_register` (RTL/conv2/) 사용. active-high rst.
    //==========================================================================
    wire signed [7:0] k0,k1,k2,k3,k4,k5,k6,k7,k8;

    window_register #(.WIDTH(8)) win (
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
            pe_cell #(.DEPTH(2)) pe (
                .clk(clk), .rst(rst),
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
            pe_cell #(.DEPTH(2)) pe (
                .clk(clk), .rst(rst),
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

    conv1_adder_tree at_g2 (
        .clk(clk), .rst(rst), .en(pipe_en),
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

    wire signed [7:0] tr_out0 = tr_out_flat[ 7: 0];
    wire signed [7:0] tr_out1 = tr_out_flat[15: 8];
    wire signed [7:0] tr_out2 = tr_out_flat[23:16];
    wire signed [7:0] tr_out3 = tr_out_flat[31:24];

    truncate_relu #(.N(4)) tr (
        .clk      (clk),
        .rst      (rst),
        .en       (pipe_en),
        .sum_flat (tr_sum_flat),
        .out_flat (tr_out_flat)
    );

    //==========================================================================
    // 9. 제어 신호 동기화를 위한 3단 파이프라인 시프트 체인
    //   chX_final: tr_outX 의 1 cycle 지연 latch (round 0 용)
    //   round 1 은 tr_outX 직접 사용 (1 cycle 보정)
    //==========================================================================
    reg signed [7:0] ch0_final, ch1_final, ch2_final, ch3_final;

    reg [2:0] we_pipe;
    reg [2:0] sel_pipe;

    // padded 형식 주소: h*32+w (BMG bank addr 의 하위 10-bit). 26 valid + 6 pad.
    reg [9:0] addr_pipe [0:2];

    // bank_sel pipe — addr_pipe / we_pipe 와 같은 3-stage shift 라인.
    //   wdone 시점에 internal bank_sel 이 토글되지만, c1c2_addr 에 즉시 사용하면
    //   we_pipe trailing (= scan_done + 9 cycle 의 마지막 write) 가 새 bank 로 가버림.
    //   addr_pipe 와 동일한 stage 수만큼 지연시켜 timing 정렬.
    //   docs/conv1_timing_table.md §3, §6 참조.
    reg [2:0] bank_sel_pipe;

    always @(posedge clk) begin
        if (rst) begin
            ch0_final <= 8'sd0; ch1_final <= 8'sd0;
            ch2_final <= 8'sd0; ch3_final <= 8'sd0;

            we_pipe   <= 3'b000;
            sel_pipe  <= 3'b000;
            addr_pipe[0] <= 10'd0; addr_pipe[1] <= 10'd0; addr_pipe[2] <= 10'd0;
            bank_sel_pipe <= 3'b000;
        end else begin
            ch0_final <= tr_out0;
            ch1_final <= tr_out1;
            ch2_final <= tr_out2;
            ch3_final <= tr_out3;

            we_pipe  <= {we_pipe[1:0],  out_valid};
            sel_pipe <= {sel_pipe[1:0], out_sel};

            // padded h*32+w (multiplier 제거 → shift+concat)
            addr_pipe[0] <= {out_row[4:0], out_col[4:0]};
            addr_pipe[1] <= addr_pipe[0];
            addr_pipe[2] <= addr_pipe[1];

            // bank_sel 도 같은 3-stage 지연
            bank_sel_pipe <= {bank_sel_pipe[1:0], bank_sel};
        end
    end

    //==========================================================================
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
    assign c1c2_addr = {bank_sel_pipe[2], addr_pipe[2]};   // ★ bank 도 addr_pipe 와 같은 3-stage 지연
    assign c1c2_din  = round0_active ? din_round0 : din_round1;

endmodule