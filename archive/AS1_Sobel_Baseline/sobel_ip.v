`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2026/05/13 14:54:02
// Design Name:
// Module Name: sobel_ip
//
// sobel_ip.v
//   - 102x102 grayscale → 100x100 Sobel edge detection
//   - Output stationary, direct 3x3 convolution
//   - 2 line buffers (circular, BRAM 추론) + 9 window FFs
//////////////////////////////////////////////////////////////////////////////////


module sobel_ip(
    input wire clk, // clock
    input wire resetn,
    input wire start,
    output wire done,

    // BRAM1 port, PL side (read-only)
    output wire [13:0] b1_addra,
    output wire        b1_ena,
    output wire        b1_wea,  // dont use! read-only! (just placeholder)
    output wire [7:0]  b1_dina, // dont use! read-only! (just placeholder)
    input  wire [7:0]  b1_douta,

    // BRAM2 port, PL side (write-only)
    output wire [13:0] b2_addra,
    output wire        b2_ena,
    output wire        b2_wea,
    output wire [7:0]  b2_dina,
    input  wire [7:0]  b2_dout  // dont use! write-only! (just placeholder)
);
    // 0. State Definitions
    localparam IDLE = 1'b0;
    localparam RUN  = 1'b1;
    reg state = 1'b0;
    reg done_q = 1'b0;

    // 1. State Transition (FSM)
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state <= IDLE;
        end else begin
            case (state)
                IDLE: if (start)  state <= RUN;
                RUN:  if (done_q) state <= IDLE;
            endcase
        end
    end

    assign done = done_q;

    //===================================================================================================================
    // 2. Raster Scan => x, y coordinate counter (implementation via divider and multiplier is very inefficient!)
    //  - rs_cnt: BRAM1 address
    //  - col: x coordinate
    //  - row: y coordinate
    //  - (x & col) increment - right, (y & row) increment - down
    //  - rs_cnt = row(y) * 102 + col(x)
    //===================================================================================================================
    reg [13:0] rs_cnt;
    reg [6:0] row; // 0~101, 7bit
    reg [6:0] col; // 0~101, 7bit

    wire pipe_en = (state == RUN);  // IMPORTANT! [BRAM1 -> lb1 -> lb2] pipeline enable signal!

    always @(posedge clk) begin
        if (state == IDLE) begin
            rs_cnt <= 14'b0;
            row    <= 7'b0;
            col    <= 7'b0;
        end else if (state == RUN && rs_cnt < 14'd10404) begin
            rs_cnt <= rs_cnt + 1'b1;
            if (col == 7'd101) begin
                col <= 7'd0;
                row <= row + 7'd1;
            end else begin
                col <= col + 7'd1;
            end
        end
    end

    assign b1_addra = rs_cnt;
    assign b1_ena   = pipe_en && (rs_cnt < 10404); // enable bram 1: state is RUN & rs_cnt is below 102*102
    assign b1_wea   = 1'b0;
    assign b1_dina  = 8'h0;

    //===================================================================================================================
    // 3. Two Line Buffer Instances & delay col, row (BRAM read latency = 1 cycle)
    //  - architecture: BRAM -> lb1(102 cycles) -> lb2(102 cycles)
    //===================================================================================================================
    reg [6:0] col_d; // column(x coordinate) - delay
    reg [6:0] row_d; // row(y coordinate) - delay

    always @(posedge clk) begin
        col_d <= col;
        row_d <= row;
    end

    wire [7:0] lb1_out;
    wire [7:0] lb2_out;

    // NOTE: DEPTH is set to 101 (not 102) because the line_buffer's registered
    // output (dout reg) introduces an additional 1-cycle latency when its output
    // is consumed by the next sequential stage. Total effective delay through
    // the buffer chain = DEPTH + 1 = 102 cycles, which exactly matches one row.
    line_buffer #(.WIDTH(8), .DEPTH(101)) lb1(
        .clk (clk),
        .en  (pipe_en),
        .din (b1_douta),
        .dout(lb1_out)
    );
    line_buffer #(.WIDTH(8), .DEPTH(101)) lb2(
        .clk (clk),
        .en  (pipe_en),
        .din (lb1_out),
        .dout(lb2_out)
    );

    //===================================================================================================================
    // 4. 3x3 Window Shift Register (9 FFs)
    //  - win_r0: l2 output flow (smallest y coordinate row)
    //  - win_r1: l1 output flow
    //  - win_r2: BRAM1 output flow(biggest y coordinate row)
    //===================================================================================================================
    reg [7:0] win_r0 [0:2];  // [0]=left, [1]=center, [2]=right(new)
    reg [7:0] win_r1 [0:2];
    reg [7:0] win_r2 [0:2];

    always @(posedge clk) begin
        if (pipe_en) begin
            // win_r0: flow from l2
            win_r0[0] <= win_r0[1];
            win_r0[1] <= win_r0[2];
            win_r0[2] <= lb2_out;

            // win_r1: flow from l1
            win_r1[0] <= win_r1[1];
            win_r1[1] <= win_r1[2];
            win_r1[2] <= lb1_out;

            // win_r2: flow from BRAM1
            win_r2[0] <= win_r2[1];
            win_r2[1] <= win_r2[2];
            win_r2[2] <= b1_douta;
        end
    end

    //===================================================================================================================
    // 5. Sobel Computation (PIPELINED: 2 stages)
    //  - Matrix Convention
    //    p00 p01 p02
    //    p10 p11 p12
    //    p20 p21 p22
    //  - Stage A: Gx, Gy 계산 후 레지스터링
    //  - Stage B: |Gx| + |Gy| + Saturation 후 레지스터링
    //  - 총 2 cycle 추가 latency (좌표도 2단 추가 지연 필요, 섹션 6 참고)
    //===================================================================================================================
    // 9-bit signed extension (0을 MSB에 붙임)
    wire signed [8:0] p00 = {1'b0, win_r0[0]};
    wire signed [8:0] p01 = {1'b0, win_r0[1]};
    wire signed [8:0] p02 = {1'b0, win_r0[2]};
    wire signed [8:0] p10 = {1'b0, win_r1[0]};
    wire signed [8:0] p12 = {1'b0, win_r1[2]};
    wire signed [8:0] p20 = {1'b0, win_r2[0]};
    wire signed [8:0] p21 = {1'b0, win_r2[1]};
    wire signed [8:0] p22 = {1'b0, win_r2[2]};

    // --- Stage A: Gx, Gy 계산 후 레지스터링 ---
    reg signed [11:0] gx_r, gy_r;
    always @(posedge clk) begin
        if (pipe_en) begin
            gx_r <= (p02 - p00) + ((p12 - p10) <<< 1) + (p22 - p20);
            gy_r <= (p20 - p00) + ((p21 - p01) <<< 1) + (p22 - p02);
        end
    end

    // --- Stage B: |Gx| + |Gy| + Saturation 후 레지스터링 ---
    wire [10:0] abs_gx  = gx_r[11] ? (~gx_r[10:0] + 1'b1) : gx_r[10:0];
    wire [10:0] abs_gy  = gy_r[11] ? (~gy_r[10:0] + 1'b1) : gy_r[10:0];
    wire [11:0] sum_w   = abs_gx + abs_gy;
    wire [7:0]  sat_w   = (sum_w > 12'd255) ? 8'd255 : sum_w[7:0];

    reg [7:0] sat_r;
    always @(posedge clk) begin
        if (pipe_en) sat_r <= sat_w;
    end

    //===================================================================================================================
    // 6. BRAM2 Write & Done Signal
    //  - 파이프라인 2단 추가로 인해, 좌표는 (col_d → col_d1 → col_d2 → col_d3)로 총 3단 지연
    //  - col_d3, row_d3는 sat_r과 동일 사이클에 BRAM2 입력에 도달함
    //  - w_valid: sat_r에 해당하는 좌표가 (2~101, 2~101) 범위일 때만 1
    //  - w_addr: 0~9999 sequential, w_valid==1일 때만 증가
    //===================================================================================================================
    reg [6:0] col_d1, row_d1;
    reg [6:0] col_d2, row_d2;   // Stage A 정렬용 추가
    reg [6:0] col_d3, row_d3;   // Stage B 정렬용 추가
    always @(posedge clk) begin
        col_d1 <= col_d;   row_d1 <= row_d;
        col_d2 <= col_d1;  row_d2 <= row_d1;
        col_d3 <= col_d2;  row_d3 <= row_d2;
    end

    // create valid signal(w_valid) - sat_r과 정렬된 좌표(col_d3, row_d3) 사용
    wire w_valid = pipe_en && (row_d3 >= 7'd2) && (row_d3 <= 101)
                           && (col_d3 >= 7'd2) && (col_d3 <= 101);

    // write address: 0 ~ 9999
    reg [13:0] w_addr;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            w_addr <= 14'd0;
        end else if (state == IDLE) begin
            w_addr <= 14'd0;
        end else if (w_valid) begin
            w_addr <= w_addr + 1'b1;
        end
    end

    // BRAM2 interface
    assign b2_addra = w_addr;
    assign b2_ena   = w_valid;
    assign b2_wea   = w_valid;
    assign b2_dina  = sat_r;       // <-- 변경: sat_out → sat_r (Stage B 레지스터 출력)

    // done_q: last valid write => set to 1
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            done_q <= 1'b0;
        end else if (state == IDLE) begin
            done_q <= 1'b0;
        end else if (w_valid && w_addr == 14'd9999) begin
            done_q <= 1'b1;
        end
    end
endmodule
