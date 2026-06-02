`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_system_axi_multi.v
// Full system end-to-end TB : PS(AXI) ↔ CSR_AXI ↔ cnn_accelerator
//
//   PS emul:
//     - weight/input : Port A write (AXI BRAM Ctrl emul 생략, 직접 driving)
//     - 제어/상태   : AXI4-Lite (CSR)
//         CTRL  write : enable / start / img_ready
//         STATUS read : done / result / can_load / img_cnt
//     - per image  : can_load(STATUS[5]) polling → input write → img_ready(CTRL[2])
//                    → img_cnt(STATUS[19:6]) 증가 polling → result(STATUS[4:1]) read
//
//   AXI 가 single master 라 sequential 이지만, CSR 제어경로 + result 경로를 실제
//   AXI 트랜잭션으로 검증한다. (overlap throughput 은 tb_cnn_accelerator_multi 에서)
//
//   iverilog: TB/models/bmg_sim_models.v + dsp48e1_model.v 필요.
//////////////////////////////////////////////////////////////////////////////////

`ifdef __ICARUS__
  `define ALL_INPUT_HEX    "data/multi_img/all_input.hex"
  `define CONV1_WEIGHT_HEX "data/weights_simd/conv1_weights_simd.hex"
  `define CONV2_WEIGHT_HEX "data/weights_simd/conv2_weights_simd.hex"
  `define FCW_HEX          "data/weights_simd/fc_weights_simd.hex"
  `define FC_LOGIT_HEX     "data/multi_img/all_fc_logit.hex"
`else
  `define ALL_INPUT_HEX    "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_input.hex"
  `define CONV1_WEIGHT_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_weights_simd.hex"
  `define CONV2_WEIGHT_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_weights_simd.hex"
  `define FCW_HEX          "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/fc_weights_simd.hex"
  `define FC_LOGIT_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_fc_logit.hex"
`endif


module tb_system_axi_multi;

    parameter N_IMAGES = 10;     // AXI sequential 이라 작게
    parameter ACC_W    = 24;

    // Register offsets (byte addr)
    localparam [3:0] CTRL = 4'h0, STAT = 4'h4, TLO = 4'h8, THI = 4'hC;

    //==========================================================================
    // Clock / reset
    //==========================================================================
    reg ACLK    = 1'b0;
    reg ARESETN = 1'b0;
    always #5 ACLK = ~ACLK;

    //==========================================================================
    // AXI4-Lite master signals
    //==========================================================================
    reg  [3:0]  AWADDR = 4'd0;  reg AWVALID = 1'b0;  wire AWREADY;
    reg  [31:0] WDATA  = 32'd0; reg WVALID = 1'b0;   wire WREADY;  reg [3:0] WSTRB = 4'hF;
    wire [1:0]  BRESP;          wire BVALID;         reg BREADY = 1'b0;
    reg  [3:0]  ARADDR = 4'd0;  reg ARVALID = 1'b0;  wire ARREADY;
    wire [31:0] RDATA;          wire [1:0] RRESP;    wire RVALID;  reg RREADY = 1'b0;

    //==========================================================================
    // CSR ↔ PL nets
    //==========================================================================
    wire        enable, start, img_ready;
    wire [3:0]  result;
    wire        img_done, input_consumed;

    //==========================================================================
    // PS-write BMG Port A
    //==========================================================================
    reg         in_ena=0;   reg [3:0] in_wea=0;   reg [8:0]  in_addra=0;   reg [31:0]  in_dina=0;
    reg         c1w_ena=0;   reg [5:0]  c1w_addra=0;   reg [31:0]  c1w_dina=0;
    reg         c2w_ena=0;            reg [9:0]  c2w_addra=0;  reg [31:0]  c2w_dina=0;
    reg         fcw_ena=0;            reg [9:0]  fcw_addra=0;  reg [255:0] fcw_dina=0;

    //==========================================================================
    // DUTs : CSR + cnn_accelerator
    //==========================================================================
    csr_axi_slave_lite_v1_0_csr csr (
        .enable(enable), .start(start), .img_ready(img_ready),
        .result(result), .img_done(img_done), .input_consumed(input_consumed),

        .S_AXI_ACLK(ACLK), .S_AXI_ARESETN(ARESETN),
        .S_AXI_AWADDR(AWADDR), .S_AXI_AWPROT(3'd0), .S_AXI_AWVALID(AWVALID), .S_AXI_AWREADY(AWREADY),
        .S_AXI_WDATA(WDATA), .S_AXI_WSTRB(WSTRB), .S_AXI_WVALID(WVALID), .S_AXI_WREADY(WREADY),
        .S_AXI_BRESP(BRESP), .S_AXI_BVALID(BVALID), .S_AXI_BREADY(BREADY),
        .S_AXI_ARADDR(ARADDR), .S_AXI_ARPROT(3'd0), .S_AXI_ARVALID(ARVALID), .S_AXI_ARREADY(ARREADY),
        .S_AXI_RDATA(RDATA), .S_AXI_RRESP(RRESP), .S_AXI_RVALID(RVALID), .S_AXI_RREADY(RREADY)
    );

    cnn_accelerator cnn (
        .clk(ACLK), .resetn(ARESETN),
        .enable(enable), .start(start), .img_ready(img_ready),
        .result(result), .img_done(img_done), .input_consumed(input_consumed),
        .in_ena(in_ena), .in_wea(in_wea), .in_addra(in_addra), .in_dina(in_dina),
        // weight BRAM 은 ENA+WEA 둘 다 필요 (실 BD 의 AXI BRAM Ctrl WSTRB). full-word write 라
        // wea = {4{ena}} 로 emul (미연결 시 wea=X → weight 가 X 로 적재되어 result=X 버그).
        .c1w_ena(c1w_ena), .c1w_wea({4{c1w_ena}}), .c1w_addra(c1w_addra), .c1w_dina(c1w_dina),
        .c2w_ena(c2w_ena), .c2w_wea({4{c2w_ena}}), .c2w_addra(c2w_addra), .c2w_dina(c2w_dina),
        .fcw_ena(fcw_ena), .fcw_wea({32{fcw_ena}}), .fcw_addra(fcw_addra), .fcw_dina(fcw_dina)
    );

    //==========================================================================
    // TB memory
    //==========================================================================
    reg [7:0]   input_data     [0:N_IMAGES*784-1];
    reg [31:0]  weight1_mem    [0:35];
    reg [31:0]  weight2_mem    [0:575];
    reg [31:0]  fc_weight_simd [0:11519];
    reg signed [23:0] exp_logit [0:N_IMAGES*10-1];

    integer images_pass = 0;
    reg [31:0] rdata;

    //==========================================================================
    // AXI4-Lite write / read tasks
    //==========================================================================
    task axi_write;
        input [3:0]  addr;
        input [31:0] data;
        begin
            @(negedge ACLK);
            AWADDR = addr; AWVALID = 1'b1;
            WDATA  = data; WVALID  = 1'b1; WSTRB = 4'hF;
            BREADY = 1'b1;
            // AXI-compliant: VALID 를 BVALID(write 응답) 볼 때까지 유지.
            //   robust slave handshake (AWVALID·WVALID 둘 다 떠야 awready/wready) 는 transfer
            //   가 1 cycle 뒤라, 기존처럼 1-posedge 후 deassert 하면 write 를 놓친다.
            while (!BVALID) @(negedge ACLK);
            AWVALID = 1'b0; WVALID = 1'b0;   // 응답 도착 = AW/W accepted → deassert
            @(negedge ACLK);                  // BREADY&&BVALID 로 B 응답 소비
            BREADY = 1'b0;
        end
    endtask

    task axi_read;
        input [3:0] addr;
        begin
            @(negedge ACLK);
            ARADDR = addr; ARVALID = 1'b1; RREADY = 1'b1;
            @(posedge ACLK);            // Raddr: AR handshake → rvalid
            @(negedge ACLK); ARVALID = 1'b0;
            @(posedge ACLK);            // Rdata
            rdata = RDATA;
            @(negedge ACLK); RREADY = 1'b0;
        end
    endtask

    //==========================================================================
    // Port A weight/input write tasks
    //==========================================================================
    task load_w1; integer wi; begin
        for (wi=0; wi<36; wi=wi+1) begin
            @(negedge ACLK); c1w_ena=1; c1w_addra=wi[5:0]; c1w_dina=weight1_mem[wi];
        end
        @(negedge ACLK); c1w_ena=0;
    end endtask

    task load_w2; integer wi; begin
        for (wi=0; wi<576; wi=wi+1) begin
            @(negedge ACLK); c2w_ena=1; c2w_addra=wi[9:0]; c2w_dina=weight2_mem[wi];
        end
        @(negedge ACLK); c2w_ena=0;
    end endtask

    task load_fcw;
        integer pair, s, c, k, line_idx;
        reg signed [7:0] w0, w1; reg signed [16:0] w0p; reg signed [7:0] w1p;
        reg [127:0] we, wo;
        reg [255:0] word;
    begin
        for (pair=0; pair<5; pair=pair+1)
          for (s=0; s<144; s=s+1) begin
            we=0; wo=0;
            for (c=0; c<16; c=c+1) begin
                line_idx = pair*144*16 + s*16 + c;
                w0p = $signed(fc_weight_simd[line_idx][16:0]);
                w1p = $signed(fc_weight_simd[line_idx][24:17]);
                w0 = w0p[7:0];
                w1 = w1p + (w0p[16] ? 8'sd1 : 8'sd0);
                we[c*8 +: 8] = w0; wo[c*8 +: 8] = w1;
            end
            word = {wo, we};
            @(negedge ACLK); fcw_ena=1; fcw_addra=pair*144+s; fcw_dina=word;   // 256b full-word
          end
        @(negedge ACLK); fcw_ena=0;
    end endtask

    task write_input; input integer img; integer k; reg bank; begin
        bank = img[0];
        for (k=0; k<196; k=k+1) begin
            @(negedge ACLK); in_ena=1; in_wea=4'hF; in_addra={bank,k[7:0]};
            in_dina = {input_data[img*784+k*4+3], input_data[img*784+k*4+2],
                       input_data[img*784+k*4+1], input_data[img*784+k*4+0]};
        end
        @(negedge ACLK); in_ena=0; in_wea=0;
    end endtask

    function [3:0] exp_argmax; input integer base; integer j;
        reg signed [23:0] best; reg [3:0] bi; begin
        best=exp_logit[base]; bi=0;
        for (j=1;j<10;j=j+1) if (exp_logit[base+j]>best) begin best=exp_logit[base+j]; bi=j[3:0]; end
        exp_argmax=bi;
    end endfunction

    //==========================================================================
    // Main sequence
    //==========================================================================
    integer i, j, logit_mm, prev_cnt, cur_cnt, got_result;
    reg [3:0] exp_cls;
    initial begin
        $display("\n==========================================");
        $display("  Full system AXI TB : CSR ↔ cnn_accelerator  (N=%0d)", N_IMAGES);
        $display("==========================================");

        $readmemh(`ALL_INPUT_HEX,    input_data);
        $readmemh(`CONV1_WEIGHT_HEX, weight1_mem);
        $readmemh(`CONV2_WEIGHT_HEX, weight2_mem);
        $readmemh(`FCW_HEX,          fc_weight_simd);
        $readmemh(`FC_LOGIT_HEX,     exp_logit);

        // Reset
        ARESETN = 1'b0;
        repeat (10) @(posedge ACLK);
        @(negedge ACLK); ARESETN = 1'b1;

        // PS: weight 적재 (Port A)
        load_w1(); load_w2(); load_fcw();
        $display("[TB] weights loaded");

        // PS: enable=1, start pulse (CTRL write)
        axi_write(CTRL, 32'h1);          // enable=1
        axi_write(CTRL, 32'h3);          // enable + start(pulse)
        $display("[TB] CTRL: enable=1, start pulsed");

        prev_cnt = 0;
        for (i = 0; i < N_IMAGES; i = i + 1) begin
            // backpressure: STATUS.can_load(bit5) polling
            rdata = 0;
            while (!rdata[5]) axi_read(STAT);

            write_input(i);
            axi_write(CTRL, 32'h5);      // enable + img_ready(pulse, bit2)

            // img_cnt(STATUS[19:6]) 증가 polling
            cur_cnt = prev_cnt;
            while (cur_cnt == prev_cnt) begin
                axi_read(STAT);
                cur_cnt = rdata[19:6];
            end
            prev_cnt   = cur_cnt;
            got_result = rdata[4:1];

            // logit bit-exact (hierarchical) + result(AXI)
            logit_mm = 0;
            for (j = 0; j < 10; j = j + 1)
                if (cnn.fc.logit_reg[j][23:0] !== exp_logit[i*10 + j]) logit_mm = logit_mm + 1;
            exp_cls = exp_argmax(i*10);

            if (logit_mm == 0 && got_result == exp_cls) begin
                images_pass = images_pass + 1;
                $display("[TB] img %3d : PASS  result(AXI)=%0d  img_cnt=%0d", i, got_result, cur_cnt);
            end else begin
                $display("[TB] img %3d : FAIL  result=%0d exp=%0d logit_mm=%0d", i, got_result, exp_cls, logit_mm);
            end
        end

        // timer read
        axi_read(TLO);
        $display("[TB] timer_lo = %0d", rdata);

        $display("\n=========================================");
        $display("  images PASS : %0d / %0d", images_pass, N_IMAGES);
        if (images_pass == N_IMAGES)
            $display("  *** PASS *** (end-to-end: AXI 제어 + result + logit bit-exact)");
        else
            $display("  *** FAIL ***");
        $display("=========================================");
        $finish;
    end

    initial begin
        #20000000;
        $display("\n[TB] !!! TIMEOUT !!! (images_pass=%0d/%0d)", images_pass, N_IMAGES);
        $finish;
    end

endmodule
