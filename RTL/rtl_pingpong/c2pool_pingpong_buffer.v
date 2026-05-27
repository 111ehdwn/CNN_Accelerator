`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: c2pool_pingpong_buffer
// Description:
//   Conv2 output activation -> Maxpool input activation ping-pong buffer
//
//   Purpose:
//     - Conv2 writes 24x24x16 activation into one bank.
//     - Maxpool reads 24x24x16 activation from the other valid bank.
//     - This buffer directly supplies c2pool_rd_data to maxpool_engine.
//
//   Data format:
//     - DATA_WIDTH = 128
//     - 1 word = 16 channels x 8-bit
//
//   Address format:
//     - local address: 0 ~ 575
//     - physical address = {bank_sel, local_addr[9:0]}
//     - bank 0 physical range: 0    ~ 575    valid
//     - bank 1 physical range: 1024 ~ 1599   valid
//
//   Important:
//     - Maxpool must generate local address only.
//     - Do NOT add bank offset inside maxpool_fsm.
//     - This buffer attaches read_bank_sel internally.
//
//   Read latency:
//     - 1-cycle synchronous read.
//     - This matches current maxpool_fsm timing.
//       phase 0: issue p00 address
//       phase 1: receive p00 data
//////////////////////////////////////////////////////////////////////////////////

module c2pool_pingpong_buffer #(
    parameter DATA_WIDTH       = 128,
    parameter ADDR_WIDTH       = 11,
    parameter LOCAL_ADDR_WIDTH = 10,
    parameter DEPTH            = 2048
)(
    input  wire                         clk,
    input  wire                         rst,    // active-high synchronous reset

    //==========================================================================
    // Conv2 write side
    //==========================================================================
    input  wire                         conv2_we,
    input  wire [ADDR_WIDTH-1:0]        conv2_waddr,  // {write_bank_sel, local_addr[9:0]}
    input  wire [DATA_WIDTH-1:0]        conv2_wdata,
    input  wire                         conv2_wdone,

    output wire                         conv2_can_write,

    //==========================================================================
    // Maxpool read side
    //
    // Connect to maxpool_engine:
    //   maxpool_rd_addr <- c2pool_rd_addr
    //   maxpool_rd_en   <- c2pool_rd_en
    //   maxpool_rd_data -> c2pool_rd_data
    //==========================================================================
    input  wire                         maxpool_rd_en,
    input  wire [LOCAL_ADDR_WIDTH-1:0]  maxpool_rd_addr,   // local addr only, 0~575
    output reg  signed [DATA_WIDTH-1:0] maxpool_rd_data,

    input  wire                         maxpool_rdone,

    //==========================================================================
    // Handshake / start signal to Maxpool
    //
    // maxpool_start is level signal.
    // Maxpool can start whenever current read bank is valid.
    //==========================================================================
    output wire                         maxpool_start,

    //==========================================================================
    // Feedback to Conv2 FSM
    //
    // Connect maxpool_rdone also to conv2_engine.succ_rdone.
    //==========================================================================
    output wire                         succ_rdone_to_conv2,

    //==========================================================================
    // Debug / status
    //==========================================================================
    output wire                         maxpool_read_bank_sel,
    output wire [1:0]                   bank_valid
);

    //==========================================================================
    // 1. Memory
    //==========================================================================
    reg signed [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    //==========================================================================
    // 2. Bank control
    //==========================================================================
    reg       read_bank_sel;
    reg [1:0] valid_reg;

    assign maxpool_read_bank_sel = read_bank_sel;
    assign bank_valid            = valid_reg;

    wire conv2_write_bank_sel;
    assign conv2_write_bank_sel = conv2_waddr[ADDR_WIDTH-1];

    // Conv2가 쓰려는 bank가 비어 있을 때만 write 가능
    assign conv2_can_write = (valid_reg[conv2_write_bank_sel] == 1'b0);

    // Maxpool이 읽을 수 있는 bank가 준비되었는지
    wire maxpool_can_read;
    assign maxpool_can_read = valid_reg[read_bank_sel];

    assign maxpool_start = maxpool_can_read;

    assign succ_rdone_to_conv2 = maxpool_rdone;

    // Maxpool physical read address
    wire [ADDR_WIDTH-1:0] maxpool_phys_raddr;
    assign maxpool_phys_raddr = {read_bank_sel, maxpool_rd_addr};

    //==========================================================================
    // 3. Conv2 write
    //==========================================================================
    always @(posedge clk) begin
        if (conv2_we && conv2_can_write) begin
            mem[conv2_waddr] <= conv2_wdata;
        end
    end

    //==========================================================================
    // 4. Maxpool read path
    //
    //   1-cycle latency:
    //
    //   cycle N:
    //     maxpool_rd_en   = 1
    //     maxpool_rd_addr = A
    //
    //   cycle N+1:
    //     maxpool_rd_data = mem[{read_bank_sel, A}]
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            maxpool_rd_data <= {DATA_WIDTH{1'b0}};
        end else begin
            if (maxpool_rd_en && maxpool_can_read) begin
                maxpool_rd_data <= mem[maxpool_phys_raddr];
            end
        end
    end

    //==========================================================================
    // 5. Bank valid next-state logic
    //
    //   conv2_wdone:
    //     Conv2가 방금 쓴 bank를 valid 처리
    //
    //   maxpool_rdone:
    //     Maxpool이 방금 읽은 bank를 empty 처리
    //==========================================================================
    reg [1:0] valid_next;

    always @(*) begin
        valid_next = valid_reg;

        if (maxpool_rdone) begin
            valid_next[read_bank_sel] = 1'b0;
        end

        if (conv2_wdone && conv2_can_write) begin
            valid_next[conv2_write_bank_sel] = 1'b1;
        end
    end

    //==========================================================================
    // 6. Bank select update
    //
    //   Conv2 write bank:
    //     conv2_fsm의 output_bank_sel이 담당
    //
    //   Maxpool read bank:
    //     이 buffer가 담당
    //
    //   maxpool_rdone 발생 시 다음 bank로 toggle.
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            read_bank_sel <= 1'b0;
            valid_reg     <= 2'b00;
        end else begin
            valid_reg <= valid_next;

            if (maxpool_rdone) begin
                read_bank_sel <= ~read_bank_sel;
            end
        end
    end

endmodule