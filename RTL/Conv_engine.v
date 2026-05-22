`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv1_engine
// Description:
//   - Conv1 최상위 모듈: 모든 서브모듈 인스턴스화 및 배선 연결
//   - 입력: (1, 28, 28) INT8
//   - 출력: (8, 26, 26) INT8 → ping-pong buffer에 쓰기
//
//   서브모듈:
//     line_buffer × 2       : 3행 window 구성
//     window_register        : 3×3 = 9픽셀 동시 출력
//     weight_loader          : BRAM → pe_cell reg1/reg2 적재
//     pe_cell × 18          : DSP 곱셈 (묶음1: pe[0~8], 묶음2: pe[9~17])
//     adder_tree × 2        : 묶음별 9개 psum 합산
//     truncate_relu          : >>10, saturate, ReLU
//     conv1_fsm              : 전체 제어
//
//   출력 메모리 주소:
//     addr = (out_sel ? 4 : 0)*676 + out_ch_base*676 + out_row*26 + out_col
//     sel=0: oc0(addr+0*676), oc1(addr+1*676), oc2(addr+2*676), oc3(addr+3*676)
//     sel=1: oc4(addr+0*676), oc5(addr+1*676), oc6(addr+2*676), oc7(addr+3*676)
//////////////////////////////////////////////////////////////////////////////////

module conv1_engine (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output wire        done,

    // 입력 BRAM 인터페이스 (읽기 전용)
    output wire [9:0]  in_bram_addr,   // 0~783 (28×28)
    output wire        in_bram_en,
    input  wire signed [7:0] in_bram_dout,

    // weight BRAM 인터페이스 (읽기 전용)
    output wire [5:0]  w_bram_addr,    // 0~35
    output wire        w_bram_en,
    input  wire [24:0] w_bram_dout,

    // 출력 BRAM 인터페이스 (쓰기 전용)
    // 8채널 × 26 × 26 = 5408 픽셀
    output wire [12:0] out_bram_addr,
    output wire        out_bram_we,
    output wire signed [7:0] out_bram_din
);

    //==========================================================================
    // 1. conv1_fsm
    //==========================================================================
    wire        load_start, load_done;
    wire        pipe_en, sel;
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
        .pixel_valid(pixel_valid),
        .out_row    (out_row),
        .out_col    (out_col),
        .out_valid  (out_valid),
        .out_sel    (out_sel),
        .done       (done)
    );

    //==========================================================================
    // 2. 입력 BRAM 래스터 스캔 주소
    //    FSM의 row, col을 직접 사용
    //    (conv1_fsm 내부 row, col을 engine으로 노출해야 함)
    //    → 여기서는 fsm에서 pipe_en 구간 동안 순차 카운터로 생성
    //==========================================================================
    reg [9:0] in_addr;   // 0~783

    always @(posedge clk) begin
        if (rst)
            in_addr <= 10'd0;
        else if (pipe_en) begin
            if (in_addr == 10'd783)
                in_addr <= 10'd0;
            else
                in_addr <= in_addr + 1'b1;
        end else
            in_addr <= 10'd0;
    end

    assign in_bram_addr = in_addr;
    assign in_bram_en   = pipe_en;

    //==========================================================================
    // 3. weight_loader
    //==========================================================================
    wire [24:0]      pe_packed_a;
    wire [17:0]      pe_weight_load1;
    wire [17:0]      pe_weight_load2;

    weight_loader #(
        .NUM_PE (18),
        .ADDR_W (6)
    ) wloader (
        .clk            (clk),
        .rst            (rst),
        .load_start     (load_start),
        .load_done      (load_done),
        .bram_addr      (w_bram_addr),
        .bram_en        (w_bram_en),
        .bram_dout      (w_bram_dout),
        .pe_packed_a    (pe_packed_a),
        .pe_weight_load1(pe_weight_load1),
        .pe_weight_load2(pe_weight_load2)
    );

    //==========================================================================
    // 4. line_buffer × 2
    //    입력: in_bram_dout (BRAM 읽기 레이턴시 1사이클 있음)
    //==========================================================================
    wire signed [7:0] lb1_out, lb2_out;

    line_buffer #(.WIDTH(8), .DEPTH(27)) lb1 (
        .clk  (clk),
        .en   (pipe_en),
        .din  (in_bram_dout),
        .dout (lb1_out)
    );

    line_buffer #(.WIDTH(8), .DEPTH(27)) lb2 (
        .clk  (clk),
        .en   (pipe_en),
        .din  (lb1_out),
        .dout (lb2_out)
    );

    //==========================================================================
    // 5. window_register
    //==========================================================================
    wire signed [7:0] k0, k1, k2, k3, k4, k5, k6, k7, k8;

    window_register #(.WIDTH(8)) win (
        .clk     (clk),
        .en      (pipe_en),
        .row2_in (in_bram_dout),
        .row1_in (lb1_out),
        .row0_in (lb2_out),
        .k0(k0), .k1(k1), .k2(k2),
        .k3(k3), .k4(k4), .k5(k5),
        .k6(k6), .k7(k7), .k8(k8)
    );

    //==========================================================================
    // 6. pe_cell × 18
    //    묶음1: pe[0~8]  → oc0,oc1 (reg1) / oc4,oc5 (reg2)
    //    묶음2: pe[9~17] → oc2,oc3 (reg1) / oc6,oc7 (reg2)
    //==========================================================================
    wire signed [7:0] k [0:8];
    assign k[0]=k0; assign k[1]=k1; assign k[2]=k2;
    assign k[3]=k3; assign k[4]=k4; assign k[5]=k5;
    assign k[6]=k6; assign k[7]=k7; assign k[8]=k8;

    // 묶음1 psum (oc0/oc4, oc1/oc5)
    wire signed [16:0] psum0_g1 [0:8];
    wire signed [16:0] psum1_g1 [0:8];

    // 묶음2 psum (oc2/oc6, oc3/oc7)
    wire signed [16:0] psum0_g2 [0:8];
    wire signed [16:0] psum1_g2 [0:8];

    genvar gi;
    generate
        // 묶음1: pe_cell[0~8]
        for (gi = 0; gi < 9; gi = gi+1) begin : gen_pe_g1
            pe_cell pe (
                .clk          (clk),
                .rst          (rst),
                .packed_a     (pe_packed_a),
                .weight_load1 (pe_weight_load1[gi]),
                .weight_load2 (pe_weight_load2[gi]),
                .sel          (sel),
                .en           (pipe_en),
                .x            (k[gi]),
                .psum0        (psum0_g1[gi]),
                .psum1        (psum1_g1[gi])
            );
        end

        // 묶음2: pe_cell[9~17]
        for (gi = 0; gi < 9; gi = gi+1) begin : gen_pe_g2
            pe_cell pe (
                .clk          (clk),
                .rst          (rst),
                .packed_a     (pe_packed_a),
                .weight_load1 (pe_weight_load1[gi+9]),
                .weight_load2 (pe_weight_load2[gi+9]),
                .sel          (sel),
                .en           (pipe_en),
                .x            (k[gi]),
                .psum0        (psum0_g2[gi]),
                .psum1        (psum1_g2[gi])
            );
        end
    endgenerate

    //==========================================================================
    // 7. adder_tree × 2
    //==========================================================================
    wire signed [23:0] sum0_g1, sum1_g1;
    wire signed [23:0] sum0_g2, sum1_g2;

    adder_tree at_g1 (
        .clk    (clk), .rst (rst), .en (pipe_en),
        .psum0_0(psum0_g1[0]), .psum0_1(psum0_g1[1]), .psum0_2(psum0_g1[2]),
        .psum0_3(psum0_g1[3]), .psum0_4(psum0_g1[4]), .psum0_5(psum0_g1[5]),
        .psum0_6(psum0_g1[6]), .psum0_7(psum0_g1[7]), .psum0_8(psum0_g1[8]),
        .psum1_0(psum1_g1[0]), .psum1_1(psum1_g1[1]), .psum1_2(psum1_g1[2]),
        .psum1_3(psum1_g1[3]), .psum1_4(psum1_g1[4]), .psum1_5(psum1_g1[5]),
        .psum1_6(psum1_g1[6]), .psum1_7(psum1_g1[7]), .psum1_8(psum1_g1[8]),
        .sum0   (sum0_g1),
        .sum1   (sum1_g1)
    );

    adder_tree at_g2 (
        .clk    (clk), .rst (rst), .en (pipe_en),
        .psum0_0(psum0_g2[0]), .psum0_1(psum0_g2[1]), .psum0_2(psum0_g2[2]),
        .psum0_3(psum0_g2[3]), .psum0_4(psum0_g2[4]), .psum0_5(psum0_g2[5]),
        .psum0_6(psum0_g2[6]), .psum0_7(psum0_g2[7]), .psum0_8(psum0_g2[8]),
        .psum1_0(psum1_g2[0]), .psum1_1(psum1_g2[1]), .psum1_2(psum1_g2[2]),
        .psum1_3(psum1_g2[3]), .psum1_4(psum1_g2[4]), .psum1_5(psum1_g2[5]),
        .psum1_6(psum1_g2[6]), .psum1_7(psum1_g2[7]), .psum1_8(psum1_g2[8]),
        .sum0   (sum0_g2),
        .sum1   (sum1_g2)
    );

    //==========================================================================
    // 8. truncate_relu
    //==========================================================================
    wire signed [7:0] out0, out1, out2, out3;

    truncate_relu tr (
        .clk  (clk),
        .rst  (rst),
        .en   (pipe_en),
        .sum0 (sum0_g1),   // oc0 or oc4
        .sum1 (sum1_g1),   // oc1 or oc5
        .sum2 (sum0_g2),   // oc2 or oc6
        .sum3 (sum1_g2),   // oc3 or oc7
        .out0 (out0),
        .out1 (out1),
        .out2 (out2),
        .out3 (out3)
    );

    //==========================================================================
    // 9. 출력 BRAM 쓰기
    //
    //   출력 layout: (OC, H, W) = (8, 26, 26)
    //   oc별 base: oc_base = oc_idx * 676
    //
    //   sel=0: out0→oc0, out1→oc1, out2→oc2, out3→oc3
    //   sel=1: out0→oc4, out1→oc5, out2→oc6, out3→oc7
    //
    //   한 번에 1채널씩 쓰기 (4채널을 4사이클에 나눠 씀)
    //   → 출력 BRAM 포트 1개로 충분
    //==========================================================================
    reg [1:0]  wr_ch;      // 0~3: 4채널 순차 쓰기 카운터
    reg        wr_valid;
    reg [12:0] wr_addr;
    reg signed [7:0] wr_din;

    // 픽셀 base 주소 = row*26 + col
    wire [9:0] pix_base = out_row * 26 + out_col;

    // oc base (676 = 26×26)
    // sel=0: oc0=0, oc1=676, oc2=1352, oc3=2028
    // sel=1: oc4=2704, oc5=3380, oc6=4056, oc7=4732
    wire [12:0] oc_base [0:3];
    assign oc_base[0] = out_sel ? 13'd2704 : 13'd0;
    assign oc_base[1] = out_sel ? 13'd3380 : 13'd676;
    assign oc_base[2] = out_sel ? 13'd4056 : 13'd1352;
    assign oc_base[3] = out_sel ? 13'd4732 : 13'd2028;

    always @(posedge clk) begin
        if (rst) begin
            wr_ch    <= 2'd0;
            wr_valid <= 1'b0;
            wr_addr  <= 13'd0;
            wr_din   <= 8'sd0;
        end else begin
            wr_valid <= 1'b0;

            if (out_valid) begin
                // 4채널 순차 쓰기 시작
                wr_ch    <= 2'd0;
                wr_valid <= 1'b1;
                wr_addr  <= oc_base[0] + pix_base;
                wr_din   <= out0;
            end else if (wr_ch > 2'd0 && wr_ch <= 2'd3) begin
                wr_valid <= 1'b1;
                wr_addr  <= oc_base[wr_ch] + pix_base;
                case (wr_ch)
                    2'd1: wr_din <= out1;
                    2'd2: wr_din <= out2;
                    2'd3: wr_din <= out3;
                    default: wr_din <= 8'sd0;
                endcase
                wr_ch <= wr_ch + 1'b1;
            end

            if (out_valid) wr_ch <= 2'd1;
        end
    end

    assign out_bram_addr = wr_addr;
    assign out_bram_we   = wr_valid;
    assign out_bram_din  = wr_din;

endmodule