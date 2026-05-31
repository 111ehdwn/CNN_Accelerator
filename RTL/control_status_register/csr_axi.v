
`timescale 1 ns / 1 ps

	module csr_axi #
	(
		// Users to add parameters here

		// User parameters ends
		// Do not modify the parameters beyond this line


		// Parameters of Axi Slave Bus Interface csr
		parameter integer C_csr_DATA_WIDTH	= 32,
		parameter integer C_csr_ADDR_WIDTH	= 4
	)
	(
		// Users to add ports here
		// PL(cnn_accelerator) 인터페이스
        output wire        enable,
        output wire        start,
        output wire        img_ready,
        input  wire [3:0]  result,
        input  wire        img_done,
        input  wire        input_consumed,
        // User ports ends
		// Do not modify the ports beyond this line


		// Ports of Axi Slave Bus Interface csr
		input wire  csr_aclk,
		input wire  csr_aresetn,
		input wire [C_csr_ADDR_WIDTH-1 : 0] csr_awaddr,
		input wire [2 : 0] csr_awprot,
		input wire  csr_awvalid,
		output wire  csr_awready,
		input wire [C_csr_DATA_WIDTH-1 : 0] csr_wdata,
		input wire [(C_csr_DATA_WIDTH/8)-1 : 0] csr_wstrb,
		input wire  csr_wvalid,
		output wire  csr_wready,
		output wire [1 : 0] csr_bresp,
		output wire  csr_bvalid,
		input wire  csr_bready,
		input wire [C_csr_ADDR_WIDTH-1 : 0] csr_araddr,
		input wire [2 : 0] csr_arprot,
		input wire  csr_arvalid,
		output wire  csr_arready,
		output wire [C_csr_DATA_WIDTH-1 : 0] csr_rdata,
		output wire [1 : 0] csr_rresp,
		output wire  csr_rvalid,
		input wire  csr_rready
	);
// Instantiation of Axi Bus Interface csr
	csr_axi_slave_lite_v1_0_csr # (
		.C_S_AXI_DATA_WIDTH(C_csr_DATA_WIDTH),
		.C_S_AXI_ADDR_WIDTH(C_csr_ADDR_WIDTH)
	) csr_axi_slave_lite_v1_0_csr_inst (
	    // inner 의 user ports
        .enable(enable),
        .start(start),
        .img_ready(img_ready),
        .result(result),
        .img_done(img_done),
        .input_consumed(input_consumed),
        // user port ends

        // Original AXI ports
		.S_AXI_ACLK(csr_aclk),
		.S_AXI_ARESETN(csr_aresetn),
		.S_AXI_AWADDR(csr_awaddr),
		.S_AXI_AWPROT(csr_awprot),
		.S_AXI_AWVALID(csr_awvalid),
		.S_AXI_AWREADY(csr_awready),
		.S_AXI_WDATA(csr_wdata),
		.S_AXI_WSTRB(csr_wstrb),
		.S_AXI_WVALID(csr_wvalid),
		.S_AXI_WREADY(csr_wready),
		.S_AXI_BRESP(csr_bresp),
		.S_AXI_BVALID(csr_bvalid),
		.S_AXI_BREADY(csr_bready),
		.S_AXI_ARADDR(csr_araddr),
		.S_AXI_ARPROT(csr_arprot),
		.S_AXI_ARVALID(csr_arvalid),
		.S_AXI_ARREADY(csr_arready),
		.S_AXI_RDATA(csr_rdata),
		.S_AXI_RRESP(csr_rresp),
		.S_AXI_RVALID(csr_rvalid),
		.S_AXI_RREADY(csr_rready)
	);

	// Add user logic here

	// User logic ends

	endmodule
