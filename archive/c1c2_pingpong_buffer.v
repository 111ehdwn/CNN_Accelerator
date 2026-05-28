`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: c1c2_pingpong_buffer
// Description:
//   Conv1 output activation -> Conv2 input activation ping-pong buffer
//
//   Purpose:
//     - Conv1 writes activation feature map into one bank.
//     - Conv2 reads activation feature map from the other valid bank.
//     - Two banks are alternated using ping-pong control.
//
//   Data format:
//     - DATA_WIDTH = 64
//     - 1 word = 8 input channels x 8-bit
//
//   Address format:
//     - addr[10]   = bank select
//     - addr[9:5]  = row, 0~25 valid
//     - addr[4:0]  = col, 0~25 valid
//
//   Important:
//     - Conv2 expects c1c2 buffer read latency L=2.
//     - This module models BMG-like registered read:
//         stage 1: memory read register
//         stage 2: output register
//
//   Connection:
//     Conv1 side:
//       conv1_we / conv1_wrow / conv1_wcol / conv1_wdata / conv1_wdone
//
//     Conv2 side:
//       conv2_re / conv2_addr / conv2_rdata / conv2_rdone
//
//     Handshake:
//       conv1_wdone -> prior_wdone -> Conv2 FSM
//       conv2_rdone -> frees current read bank
//////////////////////////////////////////////////////////////////////////////////

module c1c2_pingpong_buffer #(
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 11,
    parameter DEPTH      = 2048
)(
    input  wire                  clk,
    input  wire                  rst,    // active-high synchronous reset

    //==========================================================================
    // Conv1 write side
    //==========================================================================
    input  wire                  conv1_we,
    input  wire [4:0]            conv1_wrow,
    input  wire [4:0]            conv1_wcol,
    input  wire [DATA_WIDTH-1:0] conv1_wdata,
    input  wire                  conv1_wdone,

    output wire                  conv1_can_write,
    output wire                  conv1_write_bank_sel,

    //==========================================================================
    // Conv2 read side
    //   Connect to conv2_engine:
    //     conv2_re    <- c1c2_re
    //     conv2_addr  <- c1c2_addr
    //     conv2_rdata -> c1c2_dout
    //==========================================================================
    input  wire                  conv2_re,
    input  wire [ADDR_WIDTH-1:0] conv2_addr,
    output reg  [DATA_WIDTH-1:0] conv2_rdata,
    input  wire                  conv2_rdone,

    //==========================================================================
    // Handshake to Conv2 FSM
    //   Connect to conv2_engine prior_wdone
    //==========================================================================
    output reg                   prior_wdone,

    //==========================================================================
    // Debug / status
    //==========================================================================
    output wire                  conv2_read_bank_sel,
    output wire [1:0]            bank_valid
);

    //==========================================================================
    // 1. Memory
    //
    //   Total address space:
    //     bank 0: 0    ~ 1023
    //     bank 1: 1024 ~ 2047
    //
    //   실제 유효 영역:
    //     each bank uses row 0~25, col 0~25
    //     address = {bank, row[4:0], col[4:0]}
    //             = bank * 1024 + row * 32 + col
    //==========================================================================
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    //==========================================================================
    // 2. Bank control
    //==========================================================================
    reg       write_bank_sel;
    reg       read_bank_sel;
    reg [1:0] valid_reg;

    assign conv1_write_bank_sel = write_bank_sel;
    assign conv2_read_bank_sel  = read_bank_sel;
    assign bank_valid           = valid_reg;

    // 현재 write bank가 비어 있을 때만 Conv1 write 가능
    assign conv1_can_write = (valid_reg[write_bank_sel] == 1'b0);

    //==========================================================================
    // 3. Conv1 write address
    //
    //   Conv2 read address와 반드시 동일한 layout 사용.
    //
    //   Correct:
    //     {bank, row, col}
    //
    //   Wrong:
    //     bank * 676 + row * 26 + col
    //==========================================================================
    wire [ADDR_WIDTH-1:0] conv1_waddr;

    assign conv1_waddr = {write_bank_sel, conv1_wrow, conv1_wcol};

    //==========================================================================
    // 4. Conv1 write
    //==========================================================================
    always @(posedge clk) begin
        if (conv1_we && conv1_can_write) begin
            mem[conv1_waddr] <= conv1_wdata;
        end
    end

    //==========================================================================
    // 5. Conv2 read path, BMG-like L=2
    //
    //   This models:
    //     - BRAM primitive read register
    //     - BRAM output register
    //
    //   Timing concept:
    //
    //     cycle N:
    //       conv2_re   = 1
    //       conv2_addr = A
    //
    //     cycle N+1:
    //       mem[A] is loaded into read_data_stage
    //
    //     cycle N+2:
    //       Conv2 can use conv2_rdata through its line_buffer/window pipeline
    //
    //   Important:
    //     Do NOT delay address by two cycles and then read mem.
    //     That makes the visible data one cycle too late for the current Conv2 FSM.
    //==========================================================================
    reg [DATA_WIDTH-1:0] read_data_stage;
    reg                  re_d1;

    always @(posedge clk) begin
        if (rst) begin
            read_data_stage <= {DATA_WIDTH{1'b0}};
            conv2_rdata     <= {DATA_WIDTH{1'b0}};
            re_d1           <= 1'b0;
        end else begin
            // stage 1: memory read
            if (conv2_re) begin
                read_data_stage <= mem[conv2_addr];
            end

            // delay enable by 1 cycle
            re_d1 <= conv2_re;

            // stage 2: output register
            if (re_d1) begin
                conv2_rdata <= read_data_stage;
            end
        end
    end

    //==========================================================================
    // 6. Bank valid next-state logic
    //
    //   conv1_wdone:
    //     current write bank becomes valid
    //
    //   conv2_rdone:
    //     current read bank becomes empty
    //
    //   If both happen in the same cycle, both updates are reflected.
    //==========================================================================
    reg [1:0] valid_next;

    always @(*) begin
        valid_next = valid_reg;

        // Conv2 finished reading current read bank
        if (conv2_rdone) begin
            valid_next[read_bank_sel] = 1'b0;
        end

        // Conv1 finished writing current write bank
        if (conv1_wdone && conv1_can_write) begin
            valid_next[write_bank_sel] = 1'b1;
        end
    end

    //==========================================================================
    // 7. Bank select toggle + prior_wdone generation
    //
    //   prior_wdone is a 1-cycle pulse to Conv2 FSM.
    //   Conv2 FSM internally counts this pulse using prior_diff.
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            write_bank_sel <= 1'b0;
            read_bank_sel  <= 1'b0;
            valid_reg      <= 2'b00;
            prior_wdone    <= 1'b0;
        end else begin
            valid_reg   <= valid_next;
            prior_wdone <= 1'b0;

            // Conv1 completed one full bank
            if (conv1_wdone && conv1_can_write) begin
                prior_wdone    <= 1'b1;
                write_bank_sel <= ~write_bank_sel;
            end

            // Conv2 completed reading one full bank
            if (conv2_rdone) begin
                read_bank_sel <= ~read_bank_sel;
            end
        end
    end

endmodule