`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// bmg_sim_models.v — iverilog 전용 Block Memory Generator behavioral 모델 모음
//
//   ★ Vivado 시뮬/합성에서는 이 파일을 소스에서 제외할 것.
//     (실제 Block Memory Generator IP 인스턴스를 사용)
//
//   목적: iverilog 로 통합 TB(tb_conv1_conv2_maxpool_fc_multi 등)의 elaborate /
//         handshake-flow 검증. 포트 폭/이름과 read latency(L)만 실제 BMG 와 일치.
//
//   포함 모델 (포트/폭/L 은 각 engine·TB 인스턴스 기준):
//     bram_input        32b×512 wr / 8b×2048 rd  (asymmetric, L=1)
//     conv1_weight_bram 32b×64                    (SDP, L=2, regceb)
//     bram_c1_to_c2     64b×2048                  (byte-write 8b, L=2)
//     conv2_weight_bram 32b×1024                  (SDP, L=2, regceb)
//     bram_c2_to_pool   128b×2048                 (L=1)
//     fc_weight_bram    256b×1024                 (SDP, L=1)
//////////////////////////////////////////////////////////////////////////////////

// ===========================================================================
// bram_input : Port A 32-bit write (×512 word), Port B 8-bit read (×2048), L=1
//   word write → 4 byte little-endian. byte read.
// ===========================================================================
module bram_input (
    input  wire        clka,
    input  wire        ena,
    input  wire [3:0]  wea,                 // byte-write (AXI WSTRB 직결)
    input  wire [8:0]  addra,
    input  wire [31:0] dina,

    input  wire        clkb,
    input  wire        enb,
    input  wire [10:0] addrb,
    output reg  signed [7:0] doutb
);
    reg [7:0] mem [0:2047];

    always @(posedge clka) begin
        if (ena) begin
            if (wea[0]) mem[{addra, 2'b00} + 11'd0] <= dina[7:0];
            if (wea[1]) mem[{addra, 2'b00} + 11'd1] <= dina[15:8];
            if (wea[2]) mem[{addra, 2'b00} + 11'd2] <= dina[23:16];
            if (wea[3]) mem[{addra, 2'b00} + 11'd3] <= dina[31:24];
        end
    end

    always @(posedge clkb) begin
        if (enb) doutb <= mem[addrb];
    end
endmodule


// ===========================================================================
// conv1_weight_bram : SDP 32b × 64, L=2 (Primitive Output Register Enable)
// ===========================================================================
module conv1_weight_bram (
    input  wire        clka,
    input  wire        ena,
    input  wire [3:0]  wea,                 // byte-write (AXI WSTRB 직결)
    input  wire [5:0]  addra,
    input  wire [31:0] dina,

    input  wire        clkb,
    input  wire        enb,
    input  wire [5:0]  addrb,
    output reg  [31:0] doutb,
    input  wire        regceb
);
    reg [31:0] mem [0:63];
    reg [31:0] pre;

    always @(posedge clka) if (ena) begin
        if (wea[0]) mem[addra][ 7: 0] <= dina[ 7: 0];
        if (wea[1]) mem[addra][15: 8] <= dina[15: 8];
        if (wea[2]) mem[addra][23:16] <= dina[23:16];
        if (wea[3]) mem[addra][31:24] <= dina[31:24];
    end

    always @(posedge clkb) begin
        if (enb)    pre   <= mem[addrb];   // stage 1
        if (regceb) doutb <= pre;          // stage 2 (output reg)
    end
endmodule


// ===========================================================================
// bram_c1_to_c2 : 64b × 2048, byte-write (wea 8-bit), L=2 (no regceb pin)
// ===========================================================================
module bram_c1_to_c2 (
    input  wire        clka,
    input  wire        ena,
    input  wire [7:0]  wea,
    input  wire [10:0] addra,
    input  wire [63:0] dina,

    input  wire        clkb,
    input  wire        enb,
    input  wire [10:0] addrb,
    output reg  [63:0] doutb
);
    reg [63:0] mem [0:2047];
    reg [63:0] pre;
    integer b;

    // 실제 BMG 기본 초기값(0) 모사 — conv1 이 write 안 하는 padding 영역이 X 로 남지 않게.
    integer mi_init;
    initial for (mi_init = 0; mi_init < 2048; mi_init = mi_init + 1) mem[mi_init] = 64'd0;

    always @(posedge clka) begin
        if (ena) begin
            for (b = 0; b < 8; b = b + 1)
                if (wea[b]) mem[addra][b*8 +: 8] <= dina[b*8 +: 8];
        end
    end

    // L=2: enb 게이트 2-stage
    always @(posedge clkb) begin
        if (enb) begin
            pre   <= mem[addrb];
            doutb <= pre;
        end
    end
endmodule


// ===========================================================================
// conv2_weight_bram : SDP 32b × 1024, L=2 (regceb)
// ===========================================================================
module conv2_weight_bram (
    input  wire        clka,
    input  wire        ena,
    input  wire [3:0]  wea,                 // byte-write (AXI WSTRB 직결)
    input  wire [9:0]  addra,
    input  wire [31:0] dina,

    input  wire        clkb,
    input  wire        enb,
    input  wire [9:0]  addrb,
    output reg  [31:0] doutb,
    input  wire        regceb
);
    reg [31:0] mem [0:1023];
    reg [31:0] pre;

    always @(posedge clka) if (ena) begin
        if (wea[0]) mem[addra][ 7: 0] <= dina[ 7: 0];
        if (wea[1]) mem[addra][15: 8] <= dina[15: 8];
        if (wea[2]) mem[addra][23:16] <= dina[23:16];
        if (wea[3]) mem[addra][31:24] <= dina[31:24];
    end

    always @(posedge clkb) begin
        if (enb)    pre   <= mem[addrb];
        if (regceb) doutb <= pre;
    end
endmodule


// ===========================================================================
// bram_c2_to_pool : 128b × 2048, L=1 (wea 1-bit, byte-write disable)
// ===========================================================================
module bram_c2_to_pool (
    input  wire         clka,
    input  wire         ena,
    input  wire         wea,
    input  wire [10:0]  addra,
    input  wire [127:0] dina,

    input  wire         clkb,
    input  wire         enb,
    input  wire [10:0]  addrb,
    output reg  signed [127:0] doutb
);
    reg [127:0] mem [0:2047];

    always @(posedge clka) if (ena && wea) mem[addra] <= dina;

    always @(posedge clkb) if (enb) doutb <= mem[addrb];
endmodule


// ===========================================================================
// fc_weight_bram : SDP 256b × 1024, L=1 (no regceb pin)
//   (tb_fc_engine.v 의 behavioral 정의와 동일 거동)
// ===========================================================================
module fc_weight_bram (   // ASYMMETRIC: Port A 32b write (×5760) / Port B 256b read (×720)
    input  wire         clka,
    input  wire         ena,
    input  wire [3:0]   wea,                // byte-write (AXI WSTRB 직결)
    input  wire [12:0]  addra,
    input  wire [31:0]  dina,

    input  wire         clkb,
    input  wire         enb,
    input  wire [9:0]   addrb,
    output reg  [255:0] doutb
);
    reg [31:0] mem [0:5759];   // 5760 = 720 × (256/32)
    integer k;

    always @(posedge clka) if (ena) begin
        if (wea[0]) mem[addra][ 7: 0] <= dina[ 7: 0];
        if (wea[1]) mem[addra][15: 8] <= dina[15: 8];
        if (wea[2]) mem[addra][23:16] <= dina[23:16];
        if (wea[3]) mem[addra][31:24] <= dina[31:24];
    end

    // 256b read = 8 × 32b, LSB-first (narrow port 낮은 주소 ↔ wide port LSB)
    always @(posedge clkb) if (enb)
        for (k = 0; k < 8; k = k + 1)
            doutb[k*32 +: 32] <= mem[addrb*8 + k];
endmodule


// ===========================================================================
// bram_pool_to_fc : 128b × 512, L=1 (maxpool write Port A / fc read Port B)
//   cnn_accelerator 의 inter-layer poolfc 버퍼.
// ===========================================================================
module bram_pool_to_fc (
    input  wire         clka,
    input  wire         ena,
    input  wire         wea,
    input  wire [8:0]   addra,
    input  wire [127:0] dina,

    input  wire         clkb,
    input  wire         enb,
    input  wire [8:0]   addrb,
    output reg  [127:0] doutb
);
    reg [127:0] mem [0:511];

    always @(posedge clka) if (ena && wea) mem[addra] <= dina;

    always @(posedge clkb) if (enb) doutb <= mem[addrb];
endmodule
