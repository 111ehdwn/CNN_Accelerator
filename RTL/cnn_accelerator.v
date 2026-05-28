`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: cnn_accelerator
//   - Top IP for Team Assignment 2 (CNN_Accelerator)
//   - Contains:
//////////////////////////////////////////////////////////////////////////////////

module cnn_accelerator(
    input  wire        clk,
    input  wire        resetn

    // ===== Control / Status =====

    // ===== BRAM1 Port B (external, to AXI BRAM Controller #1 -> PS write) =====

    // ===== BRAM2 Port B (external, to AXI BRAM Controller #2 -> PS read) =====
);
    wire reset = ~resetn;


endmodule