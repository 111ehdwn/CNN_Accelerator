`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: weight_loader_conv2
// Description:
//   Conv2 weight를 BMG IP (Port B)에서 read하여 PE array에 broadcast.
//   시스템 시작 시 1번만 동작 (576 cycle + drain).
//
//   동작 시퀀스:
//     1. loader_start pulse 받으면 LOADING 진입
//     2. 576 cycle 동안 BMG에 addr 0~575 순차 read
//     3. BMG 2-cycle latency 후 c2w_doutb valid
//     4. PE에 broadcast (pe_id, slot_id, packed_w, pe_load_en)
//     5. 576번째 PE load 후 loader_done pulse → FSM
//
//   Address 매핑 (Python pre-pack 순서와 일치):
//     for oc_pair in 0..7 (outer):
//       for ic in 0..7:
//         for kh in 0..2:
//           for kw in 0..2 (inner):
//             addr = ((oc_pair*8 + ic)*3 + kh)*3 + kw
//
//   PE flat ID:
//     pe_id   = (oc_pair * 8 + ic) * 3 + kh   (0~191)
//     slot_id = kw                            (0~2)
//
//   PE array generate 순서 (conv2_engine.v 측):
//     for oc_pair in 0..7
//       for ic in 0..7
//         for kh in 0..2
//           pe_cell with ID = oc_pair*24 + ic*3 + kh
//
//   BMG 2-cycle latency 처리:
//     Cycle T: c2w_addrb 전송, 카운터 (oc_pair, ic, kh, kw) at T
//     Cycle T+2: c2w_doutb valid (mem[addr@T])
//     PE 제어 신호 (pe_id, slot_id, pe_load_en)를 2-cycle shift register로 지연
//     → BMG dout과 PE 신호가 동일 cycle에 valid
//
//   Nested counter (나눗셈 없음, DSP 절약):
//     매 cycle 증가, inner counter wrap 시 outer counter 진행
//////////////////////////////////////////////////////////////////////////////////

module weight_loader_conv2 (
    input  wire        clk,
    input  wire        rst,              // active-high synchronous reset

    //==========================================================================
    // FSM과의 handshake
    //==========================================================================
    input  wire        loader_start,     // 1-cycle pulse, loading 시작
    output reg         loader_done,      // 1-cycle pulse, loading 완료

    //==========================================================================
    // BMG IP Port B (conv2 weight read)
    //   Width: 32-bit (하위 25-bit이 packed Aport)
    //   Depth: 576
    //   Primitive output register: enable
    //==========================================================================
    output reg         c2w_enb,
    output reg  [9:0]  c2w_addrb,
    input  wire [31:0] c2w_doutb,

    //==========================================================================
    // PE broadcast
    //==========================================================================
    output reg  [7:0]  pe_id,            // 0~191 (target PE)
    output reg  [1:0]  slot_id,          // 0~2 (K_col slot, = kw)
    output reg  [24:0] packed_w,         // 25-bit Aport (BMG dout 하위 25-bit)
    output reg         pe_load_en        // 1-cycle pulse per PE
);

    //==========================================================================
    // 1. State 정의
    //==========================================================================
    localparam [1:0] IDLE     = 2'd0;
    localparam [1:0] LOADING  = 2'd1;     // BMG addr 전송 중
    localparam [1:0] DRAIN    = 2'd2;     // 마지막 2 cycle BMG dout 받는 중
    localparam [1:0] FINISH   = 2'd3;     // loader_done pulse cycle

    reg [1:0] state;

    //==========================================================================
    // 2. Nested counter (addr 위치 추적)
    //
    //   매 cycle 증가 (LOADING 동안):
    //     kw 0→1→2 wrap → kh+1
    //     kh 0→1→2 wrap → ic+1
    //     ic 0→1→...→7 wrap → oc_pair+1
    //     oc_pair 7에서 끝 (LOADING → DRAIN)
    //==========================================================================
    reg [2:0] oc_pair_cnt;    // 0~7
    reg [2:0] ic_cnt;         // 0~7
    reg [1:0] kh_cnt;         // 0~2
    reg [1:0] kw_cnt;         // 0~2

    // 모든 카운터가 max인지 (loading 마지막 cycle 검출)
    wire is_last_addr = (oc_pair_cnt == 3'd7) && (ic_cnt == 3'd7) &&
                        (kh_cnt == 2'd2) && (kw_cnt == 2'd2);

    //==========================================================================
    // 3. Addr 계산 (BMG addrb)
    //
    //   addr = ((oc_pair*8 + ic)*3 + kh)*3 + kw
    //
    //   bit-width analysis:
    //     oc_pair*8: 3-bit << 3 = 6-bit
    //     + ic: 6-bit (max 63)
    //     * 3: 6-bit * 2-bit = 8-bit
    //     + kh: 8-bit
    //     * 3: 8-bit * 2-bit = 10-bit
    //     + kw: 10-bit (max 575 < 1024)
    //
    //   *3 = (x << 1) + x (shift + adder, cheap)
    //==========================================================================
    wire [9:0] addr_calc = (((oc_pair_cnt * 4'd8) + ic_cnt) * 2'd3 + kh_cnt) * 2'd3 + kw_cnt;

    //==========================================================================
    // 4. PE ID 계산
    //
    //   pe_id = (oc_pair * 8 + ic) * 3 + kh
    //
    //   bit-width:
    //     oc_pair*8 + ic: 6-bit
    //     * 3: 8-bit
    //     + kh: 8-bit (max 191 < 256)
    //==========================================================================
    wire [7:0] pe_id_calc = ((oc_pair_cnt * 4'd8) + ic_cnt) * 2'd3 + kh_cnt;
    wire [1:0] slot_id_calc = kw_cnt;

    //==========================================================================
    // 5. State + counter update
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state        <= IDLE;
            oc_pair_cnt  <= 3'd0;
            ic_cnt       <= 3'd0;
            kh_cnt       <= 2'd0;
            kw_cnt       <= 2'd0;
        end else begin
            case (state)
                //------------------------------------------------------------------
                // IDLE: loader_start 대기
                //------------------------------------------------------------------
                IDLE: begin
                    if (loader_start) begin
                        state       <= LOADING;
                        oc_pair_cnt <= 3'd0;
                        ic_cnt      <= 3'd0;
                        kh_cnt      <= 2'd0;
                        kw_cnt      <= 2'd0;
                    end
                end

                //------------------------------------------------------------------
                // LOADING: BMG addr 0~575 순차 전송
                //   매 cycle 카운터 증가
                //   마지막 cycle (addr=575)에 DRAIN 전이
                //------------------------------------------------------------------
                LOADING: begin
                    if (is_last_addr) begin
                        // 마지막 addr 전송 cycle, 다음 cycle부터 DRAIN
                        state <= DRAIN;
                    end else begin
                        // Nested counter 증가
                        if (kw_cnt == 2'd2) begin
                            kw_cnt <= 2'd0;
                            if (kh_cnt == 2'd2) begin
                                kh_cnt <= 2'd0;
                                if (ic_cnt == 3'd7) begin
                                    ic_cnt      <= 3'd0;
                                    oc_pair_cnt <= oc_pair_cnt + 3'd1;
                                end else begin
                                    ic_cnt <= ic_cnt + 3'd1;
                                end
                            end else begin
                                kh_cnt <= kh_cnt + 2'd1;
                            end
                        end else begin
                            kw_cnt <= kw_cnt + 2'd1;
                        end
                    end
                end

                //------------------------------------------------------------------
                // DRAIN: BMG 마지막 2 cycle 데이터 도착 대기
                //   PE 신호 shift register가 2 cycle 후 마지막 valid
                //   카운터는 정지
                //------------------------------------------------------------------
                DRAIN: begin
                    state <= FINISH;
                end

                //------------------------------------------------------------------
                // FINISH: loader_done pulse 발생 cycle, IDLE로 복귀
                //------------------------------------------------------------------
                FINISH: begin
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    //==========================================================================
    // 6. BMG addr 전송 (LOADING 동안 enable)
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            c2w_enb   <= 1'b0;
            c2w_addrb <= 10'd0;
        end else begin
            c2w_enb   <= (state == LOADING);
            c2w_addrb <= addr_calc;
        end
    end

    //==========================================================================
    // 7. PE 신호 2-cycle shift register
    //
    //   BMG addrb at cycle T → BMG doutb at cycle T+2
    //   PE 제어 신호도 T+2에 valid 되어야 함
    //
    //   Stage 1: 현재 카운터 (cycle T 값) latch
    //   Stage 2: Stage 1 latch (cycle T+1 → T 값)
    //   Output: Stage 2 (cycle T+2에 T 값)
    //==========================================================================
    reg [7:0] pe_id_d1, pe_id_d2;
    reg [1:0] slot_id_d1, slot_id_d2;
    reg       load_en_d1, load_en_d2;

    always @(posedge clk) begin
        if (rst) begin
            pe_id_d1   <= 8'd0;
            pe_id_d2   <= 8'd0;
            slot_id_d1 <= 2'd0;
            slot_id_d2 <= 2'd0;
            load_en_d1 <= 1'b0;
            load_en_d2 <= 1'b0;
        end else begin
            // Stage 1: 현재 cycle 카운터 → 1 cycle 후 stage 1
            pe_id_d1   <= pe_id_calc;
            slot_id_d1 <= slot_id_calc;
            load_en_d1 <= (state == LOADING);

            // Stage 2: stage 1 → 2 cycle 후 stage 2
            pe_id_d2   <= pe_id_d1;
            slot_id_d2 <= slot_id_d1;
            load_en_d2 <= load_en_d1;
        end
    end

    //==========================================================================
    // 8. PE broadcast output (BMG dout과 동기)
    //
    //   pe_id, slot_id, pe_load_en: stage 2 값 (2 cycle 지연)
    //   packed_w: c2w_doutb 하위 25-bit (자동 동기, 추가 지연 불필요)
    //
    //   매 cycle 새 PE에 broadcast (LOADING 동안 매 cycle valid)
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            pe_id       <= 8'd0;
            slot_id     <= 2'd0;
            packed_w    <= 25'd0;
            pe_load_en  <= 1'b0;
        end else begin
            pe_id       <= pe_id_d2;
            slot_id     <= slot_id_d2;
            packed_w    <= c2w_doutb[24:0];
            pe_load_en  <= load_en_d2;
        end
    end

    //==========================================================================
    // 9. loader_done pulse
    //   FINISH 상태에서 1-cycle pulse
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            loader_done <= 1'b0;
        else
            loader_done <= (state == FINISH);
    end

endmodule