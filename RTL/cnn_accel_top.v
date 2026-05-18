`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: cnn_accel_top
//   - Top IP for Team Assignment 2 (CNN_Accelerator)
//   - Contains: BRAM1 (input), BRAM2 (output), cnn_accelerator
//   - Port A of each BRAM is connected internally to cnn_accelerator (PL-side logic)
//   - Port B of each BRAM is exposed externally to be connected to AXI BRAM
//     Controller in the Block Design
//   - start / done are connected to the external Control/Status Register IP
//////////////////////////////////////////////////////////////////////////////////

module cnn_accel_top(
    input  wire        clk,
    input  wire        resetn,

    // ===== Control / Status =====
    input  wire        start,    // from CSR
    output wire        done,     // to CSR

    // ===== BRAM1 Port B (external, to AXI BRAM Controller #1 -> PS write) =====
    input  wire        b1_clkb,
    input  wire        b1_enb,
    input  wire        b1_web,   // 1-bit (Byte Write En Not Used)
    input  wire [13:0] b1_addrb,
    input  wire [7:0]  b1_dinb,
    output wire [7:0]  b1_doutb,

    // ===== BRAM2 Port B (external, to AXI BRAM Controller #2 -> PS read) =====
    input  wire        b2_clkb,
    input  wire        b2_enb,
    input  wire        b2_web,   // 1-bit
    input  wire [13:0] b2_addrb,
    input  wire [7:0]  b2_dinb,
    output wire [7:0]  b2_doutb
);

    //=================================================================
    // Internal nets between cnn_accelerator and BRAMs (Port A side)
    //=================================================================
    // BRAM1 Port A
    wire [13:0] b1_addra;
    wire        b1_ena;
    wire        b1_wea;
    wire [7:0]  b1_dina;
    wire [7:0]  b1_douta;

    // BRAM2 Port A
    wire [13:0] b2_addra;
    wire        b2_ena;
    wire        b2_wea;
    wire [7:0]  b2_dina;
    wire [7:0]  b2_douta;   // unused (write-only)

    //=================================================================
    // cnn_accelerator :
    //=================================================================
    cnn_accelerator u_cnn_accel(

    );

    //=================================================================
    // BRAM1 :
    //=================================================================
    BRAM1 u_bram1(
        // Port A (PL side)
        .clka  (clk),
        .ena   (b1_ena),
        .wea   (b1_wea),
        .addra (b1_addra),
        .dina  (b1_dina),
        .douta (b1_douta),
        // Port B (AXI side)
        .clkb  (b1_clkb),
        .enb   (b1_enb),
        .web   (b1_web),
        .addrb (b1_addrb),
        .dinb  (b1_dinb),
        .doutb (b1_doutb)
    );

    //=================================================================
    // BRAM2 :
    //=================================================================
    BRAM2 u_bram2(
        // Port A (PL side)
        .clka  (clk),
        .ena   (b2_ena),
        .wea   (b2_wea),
        .addra (b2_addra),
        .dina  (b2_dina),
        .douta (b2_douta),
        // Port B (AXI side)
        .clkb  (b2_clkb),
        .enb   (b2_enb),
        .web   (b2_web),
        .addrb (b2_addrb),
        .dinb  (b2_dinb),
        .doutb (b2_doutb)
    );

endmodule