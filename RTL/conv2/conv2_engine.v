`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv2_engine
// Description:
//   Conv2 top-level integration.
//   Layer: input (8 IC × 26 × 26) INT8 → output (16 OC × 24 × 24) INT8.
//
//   Sub-module 인스턴스화 + 신호 라우팅 + delay pipeline 만 담당.
//   상세 timing 은 `conv2_timing.md`, 설계 의도는 `conv2_design.md` 참조.
//
//   Pipeline depth (PE input @ T → c2pool mem updated):
//     PE 4 + adder 5 + kcol_acc 1 + truncate_relu 1 + BRAM write 1 = 12 cycle
//
//   sel/pe_en 의 9-cycle delay pipeline 으로 kcol_acc 의 kw_phase/en 정렬.
//   adder.en 은 4-cycle delay (pipeline 끝까지 마지막 데이터 흘리기 위해).
//   kcol_out_valid 가 truncate_relu.en 으로, 그 1-cycle 지연이 c2pool_we 로.
//   c2pool_write_addr 는 c2pool_we 마다 +1, DRAIN→DONE 에서 0 reset.
//   rdone/wdone 은 output_pixel_cnt / write_addr transition 으로 생성.
//
//   외부 BMG IP 가정 (Vivado Block Memory Generator):
//     conv2_weight_bram: SDP, 32-bit × 576, Common Clock,
//                        Port B Primitive Output Register Enable,
//                        Byte Write Disable (wea 1-bit).
//     (c1c2/c2pool BMG 는 외부에서 인스턴스화, 본 모듈은 wire 만 노출.)
//////////////////////////////////////////////////////////////////////////////////

module conv2_engine #(
    // ★200MHz Step 2: PE broadcast(sel/pe_en/pe_x) 입력단에 추가할 register 단수(N).
    //   0 = 원래 타이밍 (Step2 off, Step1b 만 적용).
    //   1,2,... = sel/pe_en/pe_x 를 +N register 복제(max_fanout) + conv2_fsm DRAIN +N.
    //   compute 결과는 N 무관 bit-exact (latency 만 +N/image 증가). 자세한 내용 §7.5.
    parameter PE_BC_DELAY = 1
) (
    input  wire         clk,
    input  wire         rst,                  // active-high synchronous
    input  wire         start,                // PS 로부터 1-cycle pulse

    //==========================================================================
    // Conv2 weight BMG Port A (PS write via AXI BRAM Ctrl)
    //==========================================================================
    input  wire         c2w_ena,
    input  wire [3:0]   c2w_wea,              // byte-write (AXI WSTRB[3:0])
    input  wire [9:0]   c2w_addra,
    input  wire [31:0]  c2w_dina,

    //==========================================================================
    // c1c2 buffer Port B (read, L=2)
    //==========================================================================
    output wire         c1c2_re,              // ENA = REGCE = shift_en
    output wire [10:0]  c1c2_addr,            // {input_bank_sel, row[4:0], col[4:0]}
    input  wire [63:0]  c1c2_dout,            // 8 IC × 8b packed

    //==========================================================================
    // c2pool buffer Port A (write)
    //==========================================================================
    output wire         c2pool_we,
    output wire [10:0]  c2pool_addr,          // {output_bank_sel, write_addr[9:0]}
    output wire [127:0] c2pool_din,           // 16 OC × 8b packed

    //==========================================================================
    // Handshake (양방향, 1-cycle pulse)
    //==========================================================================
    input  wire         prior_wdone,
    output wire         rdone,
    input  wire         succ_rdone,
    output wire         wdone
);

    //==========================================================================
    // FSM ↔ datapath 신호
    //==========================================================================
    wire [1:0]  fsm_sel;
    wire [1:0]  fsm_col_sel;
    // ★200MHz: shift_en(=state decode)이 8 ic 의 line_buffer/window CE-gen 으로 die 전역
    //   fanout → far-ic route 가 워스트(state→shift_en→lb2 CE, route 86%). max_fanout 으로
    //   decode 를 ic 클러스터 근처에 복제(zero-latency, 기능 불변; state 도 max_fanout=32 복제됨).
    (* max_fanout = 16 *) wire fsm_shift_en;
    wire        fsm_pe_en;
    wire [4:0]  fsm_row_cnt;
    wire [4:0]  fsm_col_cnt;
    wire [9:0]  fsm_output_pixel_cnt;
    wire        fsm_input_bank_sel;
    wire        fsm_output_bank_sel;
    wire        loader_start;
    wire        loader_done;

    //==========================================================================
    // Weight loader → PE broadcast 신호
    //==========================================================================
    wire        c2w_enb;
    wire [9:0]  c2w_addrb;
    wire [31:0] c2w_doutb;
    wire [7:0]  wl_pe_id;
    wire [1:0]  wl_slot_id;
    wire [24:0] wl_packed_w;
    wire        wl_pe_load_en;

    //==========================================================================
    // 1. FSM
    //==========================================================================
    conv2_fsm #(.PE_BC_DELAY(PE_BC_DELAY)) fsm_inst (
        .clk             (clk),
        .rst             (rst),
        .start           (start),

        .loader_start    (loader_start),
        .loader_done     (loader_done),

        .prior_wdone     (prior_wdone),
        .rdone           (rdone),
        .input_bank_sel  (fsm_input_bank_sel),

        .succ_rdone      (succ_rdone),
        .wdone           (wdone),
        .output_bank_sel (fsm_output_bank_sel),

        .sel             (fsm_sel),
        .col_sel         (fsm_col_sel),
        .shift_en        (fsm_shift_en),
        .pe_en           (fsm_pe_en),

        .row_cnt         (fsm_row_cnt),
        .col_cnt         (fsm_col_cnt),
        .output_pixel_cnt(fsm_output_pixel_cnt)
    );

    //==========================================================================
    // 2. Weight loader (시스템 시작 1회, 576 + drain cycle)
    //==========================================================================
    weight_loader_conv2 wl_inst (
        .clk          (clk),
        .rst          (rst),

        .loader_start (loader_start),
        .loader_done  (loader_done),

        .c2w_enb      (c2w_enb),
        .c2w_addrb    (c2w_addrb),
        .c2w_doutb    (c2w_doutb),

        .pe_id        (wl_pe_id),
        .slot_id      (wl_slot_id),
        .packed_w     (wl_packed_w),
        .pe_load_en   (wl_pe_load_en)
    );

    //==========================================================================
    // 3. Conv2 weight BMG IP
    //   Vivado Block Memory Generator (외부 IP 인스턴스)
    //   - SDP, common clock, Port B Primitive Output Register Enable (L=2)
    //   - Byte Write Disable → wea 는 1-bit
    //   - REGCEB 상수 1 (마지막 weight 가 output reg 에 도달하도록 필수)
    //
    //   IP 이름 (conv2_weight_bram) 은 Vivado IP integrator 에서 일치해야 함.
    //==========================================================================
    //   ★ Port A: ENA=c2w_ena, WEA=c2w_wea[3:0] byte-write (AXI WSTRB 직결).
    //     ena 미결선 시 floating 0 → write 안 됨 → weight 전부 0 → 출력 0.
    conv2_weight_bram c2w_bmg_inst (
        .clka  (clk),
        .ena   (c2w_ena),                 // Port A clock + enable
        .wea   (c2w_wea),                 // 4-bit byte-write (AXI WSTRB)
        .addra (c2w_addra),
        .dina  (c2w_dina),

        .clkb  (clk),
        .enb   (c2w_enb),
        .addrb (c2w_addrb),
        .doutb (c2w_doutb),
        .regceb(1'b1)
    );

    //==========================================================================
    // 4. c1c2 BRAM read interface
    //==========================================================================
    assign c1c2_re   = fsm_shift_en;
    assign c1c2_addr = {fsm_input_bank_sel, fsm_row_cnt, fsm_col_cnt};

    //==========================================================================
    // 5. PE load enable decoder (wl_pe_id → 192-bit one-hot)
    //   weight_loader 가 PE 별로 broadcast 하지만 각 PE 는 자신의 ID 일 때만 latch.
    //   192 comparator (각 PE 마다) 대신 8→192 decoder 1개로 자원 절약.
    //==========================================================================
    reg [191:0] pe_load_en_dec;
    always @(*) begin
        pe_load_en_dec = 192'd0;
        if (wl_pe_load_en) pe_load_en_dec[wl_pe_id] = 1'b1;
    end

    //==========================================================================
    // 5.5 ★200MHz Step 1b: weight broadcast +1 register stage
    //   weight-load broadcast(packed_w fo=192 / slot_id / load_en_dec)는 192 PE
    //   가 die 전역 DSP 컬럼에 깔려 route 가 die-spanning → WNS 워스트(-2.99).
    //   register 1단 추가 + 복제(max_fanout)로 긴 route 를 둘로 분할.
    //   weight-load 는 시스템 시작 1회 (loader_done → 첫 compute 까지 수백+ cycle
    //   여유) 라 +1 cycle 무해. 3 신호를 동일하게 +1 지연 → PE latch tuple 정렬 보존.
    //   (compute 경로(sel/x)는 §7.5 Step 2 에서 별도 지연 — load 와 시간상 분리.)
    //==========================================================================
    reg [191:0]                     pe_load_en_dec_r;   // 각 bit = 1 PE 전용 (저fanout)
    (* max_fanout = 32 *) reg [24:0] wl_packed_w_r;      // fo=192 → 복제
    (* max_fanout = 32 *) reg [1:0]  wl_slot_id_r;       // fo=192 → 복제
    always @(posedge clk) begin
        if (rst) begin
            pe_load_en_dec_r <= 192'd0;
            wl_packed_w_r    <= 25'd0;
            wl_slot_id_r     <= 2'd0;
        end else begin
            pe_load_en_dec_r <= pe_load_en_dec;
            wl_packed_w_r    <= wl_packed_w;
            wl_slot_id_r     <= wl_slot_id;
        end
    end

    //==========================================================================
    // 6. Line buffer + window register chain (per IC, 8 instance)
    //   c1c2_dout 의 8-bit slice [ic*8 +: 8] → lb1 → lb2 → window
    //==========================================================================
    wire signed [7:0] win_k [0:7][0:8];   // [IC][k_index 0..8]

    genvar ic_g, kh_g, op_g, oc_g;
    generate
        for (ic_g = 0; ic_g < 8; ic_g = ic_g + 1) begin : gen_per_ic
            wire [7:0] bram_byte = c1c2_dout[ic_g*8 +: 8];
            wire [7:0] lb1_out;
            wire [7:0] lb2_out;

            line_buffer #(.WIDTH(8), .DEPTH(25)) lb1_inst (
                .clk  (clk),
                .rst  (rst),
                .en   (fsm_shift_en),
                .din  (bram_byte),
                .dout (lb1_out)
            );

            line_buffer #(.WIDTH(8), .DEPTH(25)) lb2_inst (
                .clk  (clk),
                .rst  (rst),
                .en   (fsm_shift_en),
                .din  (lb1_out),
                .dout (lb2_out)
            );

            window_register #(.WIDTH(8)) win_inst (
                .clk     (clk),
                .rst     (rst),
                .en      (fsm_shift_en),
                .row2_in (bram_byte),
                .row1_in (lb1_out),
                .row0_in (lb2_out),
                .k0      (win_k[ic_g][0]),
                .k1      (win_k[ic_g][1]),
                .k2      (win_k[ic_g][2]),
                .k3      (win_k[ic_g][3]),
                .k4      (win_k[ic_g][4]),
                .k5      (win_k[ic_g][5]),
                .k6      (win_k[ic_g][6]),
                .k7      (win_k[ic_g][7]),
                .k8      (win_k[ic_g][8])
            );
        end
    endgenerate

    //==========================================================================
    // 7. col_sel mux per (K_row, IC) — pe_x[kh][ic]
    //   col_sel=0/1/2 → window 의 col 0/1/2.
    //   각 PE [kh, ic, *] 는 OC_pair 8개에 broadcast.
    //
    //   k_index mapping (window_register 의 출력 순서):
    //     k0=row0 col0, k1=row0 col1, k2=row0 col2,
    //     k3=row1 col0, k4=row1 col1, k5=row1 col2,
    //     k6=row2 col0, k7=row2 col1, k8=row2 col2,
    //     → kh 행, col=col_sel 의 cell = win_k[ic][kh*3 + col_sel]
    //==========================================================================
    wire signed [7:0] pe_x [0:2][0:7];   // [K_row][IC]

    generate
        for (kh_g = 0; kh_g < 3; kh_g = kh_g + 1) begin : gen_mux_kh
            for (ic_g = 0; ic_g < 8; ic_g = ic_g + 1) begin : gen_mux_ic
                assign pe_x[kh_g][ic_g] =
                    (fsm_col_sel == 2'd0) ? win_k[ic_g][kh_g*3 + 0] :
                    (fsm_col_sel == 2'd1) ? win_k[ic_g][kh_g*3 + 1] :
                                            win_k[ic_g][kh_g*3 + 2];
            end
        end
    endgenerate

    //==========================================================================
    // 7.5 ★200MHz Step 2: PE broadcast 입력단 register pipeline (depth = PE_BC_DELAY)
    //   compute 제어/activation broadcast (sel / pe_en / pe_x) 는 192 PE 로 die 전역
    //   분산 → route 지배 (WNS -2.72, DSP 94% die-spanning). PE 입력 직전에 register
    //   N 단 + 복제(max_fanout) 삽입하여 broadcast route 를 PE 클러스터 근처 replica
    //   에서 출발하도록 단축. col_sel·shift_en·FSM·window·c1c2 read 는 원래 타이밍
    //   유지(pe_x mux 출력만 지연).
    //
    //   ★정렬 불변식: sel/pe_en/pe_x 를 *동일한* N cycle 지연 → PE 가 보는
    //   {weight(sel), activation(x)} tuple 은 N cycle 전 fsm-activity 와 동일 →
    //   곱셈 시퀀스 bit-exact (latency 만 +N). downstream(sel_pipe/pe_en_pipe →
    //   adder_en/kcol_en/kcol_kw_phase)은 §9 에서 지연된 pe_*_bc 에서 tap → 전체
    //   +N 균일 시프트(상대 정렬 보존). c2pool write/wdone 도 자동 +N; FSM DRAIN 은
    //   PE_BC_DELAY 만큼 연장(conv2_fsm) 하여 마지막 write 가 write_addr reset 전에
    //   완료되도록 보장. rdone(c1c2 read facing)은 미지연 read 라 불변.
    //==========================================================================
    wire [191:0] pe_x_flat;            // 24 mux 출력(3 K_row × 8 IC) × 8b packed
    generate
        for (kh_g = 0; kh_g < 3; kh_g = kh_g + 1) begin : gen_pex_pack
            for (ic_g = 0; ic_g < 8; ic_g = ic_g + 1) begin : gen_pex_pack_ic
                assign pe_x_flat[(kh_g*8 + ic_g)*8 +: 8] = pe_x[kh_g][ic_g];
            end
        end
    endgenerate

    wire [1:0]   pe_sel_bc;            // PE 192개가 보는 weight selector
    wire         pe_en_bc;             // PE 192개가 보는 clock enable
    wire [191:0] pe_x_flat_bc;         // 지연된 activation (packed)

    generate
        if (PE_BC_DELAY == 0) begin : gen_bc_passthru
            assign pe_sel_bc    = fsm_sel;
            assign pe_en_bc     = fsm_pe_en;
            assign pe_x_flat_bc = pe_x_flat;
        end else begin : gen_bc_delay
            (* max_fanout = 32 *) reg [1:0] sel_sr   [1:PE_BC_DELAY];  // fo=192 → 복제
            (* max_fanout = 32 *) reg       pe_en_sr [1:PE_BC_DELAY];  // fo=192 → 복제
            reg [191:0]                     pe_x_sr  [1:PE_BC_DELAY];  // 각 8b slice fo=8
            integer d;
            always @(posedge clk) begin
                if (rst) begin
                    for (d = 1; d <= PE_BC_DELAY; d = d + 1) begin
                        sel_sr[d]   <= 2'd0;
                        pe_en_sr[d]  <= 1'b0;
                        pe_x_sr[d]   <= 192'd0;
                    end
                end else begin
                    sel_sr[1]  <= fsm_sel;
                    pe_en_sr[1] <= fsm_pe_en;
                    pe_x_sr[1]  <= pe_x_flat;
                    for (d = 2; d <= PE_BC_DELAY; d = d + 1) begin
                        sel_sr[d]   <= sel_sr[d-1];
                        pe_en_sr[d]  <= pe_en_sr[d-1];
                        pe_x_sr[d]   <= pe_x_sr[d-1];
                    end
                end
            end
            assign pe_sel_bc    = sel_sr[PE_BC_DELAY];
            assign pe_en_bc     = pe_en_sr[PE_BC_DELAY];
            assign pe_x_flat_bc = pe_x_sr[PE_BC_DELAY];
        end
    endgenerate

    wire signed [7:0] pe_x_d [0:2][0:7];   // 지연된 activation (PE 입력, unpacked)
    generate
        for (kh_g = 0; kh_g < 3; kh_g = kh_g + 1) begin : gen_pex_unpack
            for (ic_g = 0; ic_g < 8; ic_g = ic_g + 1) begin : gen_pex_unpack_ic
                assign pe_x_d[kh_g][ic_g] = pe_x_flat_bc[(kh_g*8 + ic_g)*8 +: 8];
            end
        end
    endgenerate

    //==========================================================================
    // 8. PE array (192 = 8 OC_pair × 8 IC × 3 K_row)
    //   각 PE: DEPTH=3 (K_col weight slot 3개)
    //   pe_id = (oc_pair * 8 + ic) * 3 + kh  (weight_loader 와 매핑)
    //==========================================================================
    wire signed [16:0] pe_mul0 [0:7][0:7][0:2];   // [OC_pair][IC][K_row], OC = op
    wire signed [16:0] pe_mul1 [0:7][0:7][0:2];   //                       OC = op+8

    generate
        for (op_g = 0; op_g < 8; op_g = op_g + 1) begin : gen_pe_op
            for (ic_g = 0; ic_g < 8; ic_g = ic_g + 1) begin : gen_pe_ic
                for (kh_g = 0; kh_g < 3; kh_g = kh_g + 1) begin : gen_pe_kh
                    pe_cell #(.DEPTH(3)) pe_inst (
                        .clk      (clk),
                        .rst      (rst),
                        .packed_w (wl_packed_w_r),                                  // Step1b: +1 reg
                        .load_idx (wl_slot_id_r),                                   // Step1b: +1 reg
                        .load_en  (pe_load_en_dec_r[(op_g*8 + ic_g)*3 + kh_g]),     // Step1b: +1 reg
                        .sel      (pe_sel_bc),                                      // Step2: +N reg
                        .en       (pe_en_bc),                                       // Step2: +N reg
                        .x        (pe_x_d[kh_g][ic_g]),                             // Step2: +N reg
                        .mul0     (pe_mul0[op_g][ic_g][kh_g]),
                        .mul1     (pe_mul1[op_g][ic_g][kh_g])
                    );
                end
            end
        end
    endgenerate

    //==========================================================================
    // 9. Delay pipeline (sel, pe_en → 하위 stage 의 en/kw_phase)
    //
    //   ★Step2: 지연된 PE-입력(pe_sel_bc/pe_en_bc = fsm 신호 +PE_BC_DELAY)에서 tap →
    //   pe_en_pipe[k] @ cycle T = pe_en_bc @ (T-1-k) = fsm_pe_en @ (T-1-k-PE_BC_DELAY)
    //   sel_pipe[k]   @ cycle T = pe_sel_bc @ (T-1-k) = fsm_sel   @ (T-1-k-PE_BC_DELAY)
    //   → PE 입력 timeline 기준 상대 정렬은 PE_BC_DELAY 무관하게 동일(전체 +N 시프트).
    //
    //   사용:
    //     adder_en       = pe_en_pipe[3]   (4-cycle = PE latency)
    //     kcol_en        = pe_en_pipe[8]   (9-cycle = PE 4 + adder 5)
    //     kcol_kw_phase  = sel_pipe[8]
    //   → 마지막 ADV 의 pe_en=1 도 정확히 9 cycle 후 kcol_acc 까지 도달.
    //==========================================================================
    reg [1:0] sel_pipe   [0:8];
    reg       pe_en_pipe [0:8];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 9; i = i + 1) begin
                sel_pipe[i]   <= 2'd0;
                pe_en_pipe[i] <= 1'b0;
            end
        end else begin
            sel_pipe[0]   <= pe_sel_bc;    // Step2: 지연된 PE-입력 timeline 에서 tap
            pe_en_pipe[0] <= pe_en_bc;     //        → downstream 전체 +N 균일 시프트
            for (i = 1; i < 9; i = i + 1) begin
                sel_pipe[i]   <= sel_pipe[i-1];
                pe_en_pipe[i] <= pe_en_pipe[i-1];
            end
        end
    end

    // adder_tree 는 5-stage pipeline. 마지막 valid PE 출력 (DRAIN 진입 직전) 이
    // sum register 까지 propagate 하려면 en=1 이 5 cycle 연속 유지되어야 함.
    // pe_en_pipe[3] 만 사용하면 마지막 입력 후 1 cycle 만에 en=0 → s1 에서 stuck.
    // → pe_en_pipe[3..7] 5-cycle window OR 로 확장.
    wire       adder_en      = pe_en_pipe[3] | pe_en_pipe[4] | pe_en_pipe[5]
                             | pe_en_pipe[6] | pe_en_pipe[7];
    wire       kcol_en       = pe_en_pipe[8];
    wire [1:0] kcol_kw_phase = sel_pipe[8];

    //==========================================================================
    // 10. krow_ic_adder_tree (16 instance, OC 0..15)
    //   OC < 8 : pe_mul0 of (op=OC, ic, kh) for all 24 (3 kh × 8 ic)
    //   OC ≥ 8 : pe_mul1 of (op=OC-8, ic, kh) for all 24
    //   순서: in_flat[(kh*8 + ic)*17 +: 17] = mul value
    //==========================================================================
    wire signed [21:0] adder_out [0:15];

    generate
        for (oc_g = 0; oc_g < 16; oc_g = oc_g + 1) begin : gen_adder
            wire [24*17-1:0] adder_in_flat;

            for (kh_g = 0; kh_g < 3; kh_g = kh_g + 1) begin : gen_adder_kh
                for (ic_g = 0; ic_g < 8; ic_g = ic_g + 1) begin : gen_adder_ic
                    if (oc_g < 8) begin : gen_low
                        assign adder_in_flat[(kh_g*8 + ic_g)*17 +: 17] =
                            pe_mul0[oc_g][ic_g][kh_g];
                    end else begin : gen_high
                        assign adder_in_flat[(kh_g*8 + ic_g)*17 +: 17] =
                            pe_mul1[oc_g - 8][ic_g][kh_g];
                    end
                end
            end

            krow_ic_adder_tree adder_inst (
                .clk     (clk),
                .rst     (rst),
                .en      (adder_en),
                .in_flat (adder_in_flat),
                .sum     (adder_out[oc_g])
            );
        end
    endgenerate

    //==========================================================================
    // 11. kcol_accumulator (16 instance, OC 0..15)
    //   3-cycle 누적 (K_col 0/1/2). kw_phase=2 cycle 에서 out_valid pulse.
    //==========================================================================
    wire signed [23:0] kcol_out       [0:15];
    wire               kcol_out_valid [0:15];

    generate
        for (oc_g = 0; oc_g < 16; oc_g = oc_g + 1) begin : gen_kcol
            kcol_accumulator kacc_inst (
                .clk      (clk),
                .rst      (rst),
                .en       (kcol_en),
                .in       (adder_out[oc_g]),
                .kw_phase (kcol_kw_phase),
                .out      (kcol_out[oc_g]),
                .out_valid(kcol_out_valid[oc_g])
            );
        end
    endgenerate

    //==========================================================================
    // 12. truncate_relu (N=16, single instance)
    //   16 instance 의 out_valid 가 동시에 fire 하므로 [0] 만 en 으로 사용.
    //==========================================================================
    wire [16*24-1:0] tr_sum_flat;
    wire [16*8-1:0]  tr_out_flat;

    generate
        for (oc_g = 0; oc_g < 16; oc_g = oc_g + 1) begin : gen_tr_pack
            assign tr_sum_flat[oc_g*24 +: 24] = kcol_out[oc_g];
        end
    endgenerate

    truncate_relu #(.N(16)) tr_inst (
        .clk      (clk),
        .rst      (rst),
        .en       (kcol_out_valid[0]),
        .sum_flat (tr_sum_flat),
        .out_flat (tr_out_flat)
    );

    //==========================================================================
    // 13. c2pool write 신호 (we, addr, din)
    //   c2pool_we_reg = kcol_out_valid[0] 1-cycle 지연 (truncate_relu latency 보정)
    //   c2pool_write_addr 는 c2pool_we_reg 마다 +1; opc reset event 에서 0.
    //==========================================================================
    reg        c2pool_we_reg;
    reg [9:0]  c2pool_write_addr;
    reg [9:0]  opc_d1;

    always @(posedge clk) begin
        if (rst) c2pool_we_reg <= 1'b0;
        else     c2pool_we_reg <= kcol_out_valid[0];
    end

    always @(posedge clk) begin
        if (rst) opc_d1 <= 10'd0;
        else     opc_d1 <= fsm_output_pixel_cnt;
    end

    // opc 가 0 이 아니었다가 0 으로 reset 되는 edge = DRAIN 종료 cycle
    wire opc_reset_event = (opc_d1 != 10'd0) && (fsm_output_pixel_cnt == 10'd0);

    always @(posedge clk) begin
        if (rst)                  c2pool_write_addr <= 10'd0;
        else if (opc_reset_event) c2pool_write_addr <= 10'd0;
        else if (c2pool_we_reg)   c2pool_write_addr <= c2pool_write_addr + 10'd1;
    end

    assign c2pool_we   = c2pool_we_reg;
    assign c2pool_addr = {fsm_output_bank_sel, c2pool_write_addr};
    assign c2pool_din  = tr_out_flat;

    //==========================================================================
    // 14. rdone / wdone pulse (1-cycle each)
    //   rdone: opc 가 575 → 576 transition 의 다음 cycle (= DRAIN entry 이후)
    //   wdone: 마지막 c2pool write (write_addr=575 && we=1) 의 다음 cycle
    //==========================================================================
    wire rdone_event = (opc_d1 == 10'd575) && (fsm_output_pixel_cnt == 10'd576);
    wire wdone_event = c2pool_we_reg && (c2pool_write_addr == 10'd575);

    reg rdone_reg;
    reg wdone_reg;
    always @(posedge clk) begin
        if (rst) begin
            rdone_reg <= 1'b0;
            wdone_reg <= 1'b0;
        end else begin
            rdone_reg <= rdone_event;
            wdone_reg <= wdone_event;
        end
    end

    assign rdone = rdone_reg;
    assign wdone = wdone_reg;

endmodule
