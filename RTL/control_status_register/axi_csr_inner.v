
`timescale 1 ns / 1 ps

//////////////////////////////////////////////////////////////////////////////////
// csr_slave_lite_v1_0_CSR_AXI — CNN Accelerator 제어/상태 레지스터 (AXI4-Lite slave)
//
//   Register map (C_S_AXI_ADDR_WIDTH=4 → 4 word):
//     0x00 CTRL  (R/W) : [0] enable    (level)
//                        [1] start     (write-1 → 1-cycle pulse, auto-clear)
//                        [2] img_ready (write-1 → 1-cycle pulse, auto-clear)
//     0x04 STATUS (R)  : [0]    done       (img_cnt==10000 latch)
//                        [4:1]  result     (마지막 image 분류 결과, img_done 시 latch)
//                        [5]    can_load   (적재가능: 발행-consumed < 2)
//                        [19:6] img_cnt    (14-bit, 처리 완료 image 수)
//     0x08 TIMER_LO (R): timer[31:0]
//     0x0C TIMER_HI (R): {16'b0, timer[47:32]}
//
//   PL(cnn_accelerator) 인터페이스:
//     out : enable, start, img_ready
//     in  : result[3:0], img_done, input_consumed
//
//   reset_n 은 외부 보드 버튼 (S_AXI_ARESETN 과 별개로 PL 에 직결 — 본 CSR 미관여).
//////////////////////////////////////////////////////////////////////////////////

	module csr_slave_lite_v1_0_CSR_AXI #
	(
		// Users to add parameters here

		// User parameters ends
		// Do not modify the parameters beyond this line

		// Width of S_AXI data bus
		parameter integer C_S_AXI_DATA_WIDTH	= 32,
		// Width of S_AXI address bus
		parameter integer C_S_AXI_ADDR_WIDTH	= 4
	)
	(
		// ===== PL (cnn_accelerator) 인터페이스 =====
		output wire        enable,
		output wire        start,
		output wire        img_ready,
		input  wire [3:0]  result,
		input  wire        img_done,
		input  wire        input_consumed,

		// Global Clock Signal
		input wire  S_AXI_ACLK,
		// Global Reset Signal. This Signal is Active LOW
		input wire  S_AXI_ARESETN,
		// Write address (issued by master, acceped by Slave)
		input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,
		// Write channel Protection type. This signal indicates the
    		// privilege and security level of the transaction, and whether
    		// the transaction is a data access or an instruction access.
		input wire [2 : 0] S_AXI_AWPROT,
		// Write address valid. This signal indicates that the master signaling
    		// valid write address and control information.
		input wire  S_AXI_AWVALID,
		// Write address ready. This signal indicates that the slave is ready
    		// to accept an address and associated control signals.
		output wire  S_AXI_AWREADY,
		// Write data (issued by master, acceped by Slave)
		input wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,
		// Write strobes. This signal indicates which byte lanes hold
    		// valid data. There is one write strobe bit for each eight
    		// bits of the write data bus.
		input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
		// Write valid. This signal indicates that valid write
    		// data and strobes are available.
		input wire  S_AXI_WVALID,
		// Write ready. This signal indicates that the slave
    		// can accept the write data.
		output wire  S_AXI_WREADY,
		// Write response. This signal indicates the status
    		// of the write transaction.
		output wire [1 : 0] S_AXI_BRESP,
		// Write response valid. This signal indicates that the channel
    		// is signaling a valid write response.
		output wire  S_AXI_BVALID,
		// Response ready. This signal indicates that the master
    		// can accept a write response.
		input wire  S_AXI_BREADY,
		// Read address (issued by master, acceped by Slave)
		input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,
		// Protection type. This signal indicates the privilege
    		// and security level of the transaction, and whether the
    		// transaction is a data access or an instruction access.
		input wire [2 : 0] S_AXI_ARPROT,
		// Read address valid. This signal indicates that the channel
    		// is signaling valid read address and control information.
		input wire  S_AXI_ARVALID,
		// Read address ready. This signal indicates that the slave is
    		// ready to accept an address and associated control signals.
		output wire  S_AXI_ARREADY,
		// Read data (issued by slave)
		output wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,
		// Read response. This signal indicates the status of the
    		// read transfer.
		output wire [1 : 0] S_AXI_RRESP,
		// Read valid. This signal indicates that the channel is
    		// signaling the required read data.
		output wire  S_AXI_RVALID,
		// Read ready. This signal indicates that the master can
    		// accept the read data and response information.
		input wire  S_AXI_RREADY
	);

	// AXI4LITE signals
	reg [C_S_AXI_ADDR_WIDTH-1 : 0] 	axi_awaddr;
	reg  	axi_awready;
	reg  	axi_wready;
	reg [1 : 0] 	axi_bresp;
	reg  	axi_bvalid;
	reg [C_S_AXI_ADDR_WIDTH-1 : 0] 	axi_araddr;
	reg  	axi_arready;
	reg [1 : 0] 	axi_rresp;
	reg  	axi_rvalid;

	// Example-specific design signals
	// local parameter for addressing 32 bit / 64 bit C_S_AXI_DATA_WIDTH
	// ADDR_LSB is used for addressing 32/64 bit registers/memories
	// ADDR_LSB = 2 for 32 bits (n downto 2)
	// ADDR_LSB = 3 for 64 bits (n downto 3)
	localparam integer ADDR_LSB = (C_S_AXI_DATA_WIDTH/32) + 1;
	localparam integer OPT_MEM_ADDR_BITS = 1;

	// Register select index
	localparam [1:0] REG_CTRL = 2'h0,
	                 REG_STAT = 2'h1,
	                 REG_TLO  = 2'h2,
	                 REG_THI  = 2'h3;

	// I/O Connections assignments
	assign S_AXI_AWREADY	= axi_awready;
	assign S_AXI_WREADY	= axi_wready;
	assign S_AXI_BRESP	= axi_bresp;
	assign S_AXI_BVALID	= axi_bvalid;
	assign S_AXI_ARREADY	= axi_arready;
	assign S_AXI_RRESP	= axi_rresp;
	assign S_AXI_RVALID	= axi_rvalid;

	//state machine variables
	reg [1:0] state_write;
	reg [1:0] state_read;
	localparam Idle = 2'b00, Raddr = 2'b10, Rdata = 2'b11, Waddr = 2'b10, Wdata = 2'b11;

	// ============================================================================
	// AXI Write 채널 FSM (제공 베이스 유지)
	// ============================================================================
	always @(posedge S_AXI_ACLK)
	  begin
	     if (S_AXI_ARESETN == 1'b0)
	       begin
	         axi_awready <= 0;
	         axi_wready <= 0;
	         axi_bvalid <= 0;
	         axi_bresp <= 0;
	         axi_awaddr <= 0;
	         state_write <= Idle;
	       end
	     else
	       begin
	         case(state_write)
	           Idle:
	             begin
	               if(S_AXI_ARESETN == 1'b1)
	                 begin
	                   axi_awready <= 1'b1;
	                   axi_wready <= 1'b1;
	                   state_write <= Waddr;
	                 end
	               else state_write <= state_write;
	             end
	           Waddr:
	             begin
	               if (S_AXI_AWVALID && S_AXI_AWREADY)
	                  begin
	                    axi_awaddr <= S_AXI_AWADDR;
	                    if(S_AXI_WVALID)
	                      begin
	                        axi_awready <= 1'b1;
	                        state_write <= Waddr;
	                        axi_bvalid <= 1'b1;
	                      end
	                    else
	                      begin
	                        axi_awready <= 1'b0;
	                        state_write <= Wdata;
	                        if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
	                      end
	                  end
	               else
	                  begin
	                    state_write <= state_write;
	                    if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
	                   end
	             end
	          Wdata:
	             begin
	               if (S_AXI_WVALID)
	                 begin
	                   state_write <= Waddr;
	                   axi_bvalid <= 1'b1;
	                   axi_awready <= 1'b1;
	                 end
	                else
	                 begin
	                   state_write <= state_write;
	                   if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
	                 end
	             end
	          endcase
	        end
	      end

	// ============================================================================
	// Write address index (현재 write 가 가리키는 register)
	// ============================================================================
	wire [OPT_MEM_ADDR_BITS:0] wr_index =
	       (S_AXI_AWVALID) ? S_AXI_AWADDR[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB]
	                       : axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB];
	wire wr_en = S_AXI_WVALID;

	// ============================================================================
	// CTRL register : enable(level), start/img_ready(1-cycle pulse)
	// ============================================================================
	reg ctrl_enable;
	reg ctrl_start;
	reg ctrl_img_ready;

	always @(posedge S_AXI_ACLK) begin
	    if (!S_AXI_ARESETN) begin
	        ctrl_enable    <= 1'b0;
	        ctrl_start     <= 1'b0;
	        ctrl_img_ready <= 1'b0;
	    end else begin
	        // start / img_ready 는 매 cycle 0 으로 떨어뜨려 1-cycle pulse 보장
	        ctrl_start     <= 1'b0;
	        ctrl_img_ready <= 1'b0;
	        if (wr_en && (wr_index == REG_CTRL)) begin
	            ctrl_enable    <= S_AXI_WDATA[0];   // level
	            ctrl_start     <= S_AXI_WDATA[1];   // pulse
	            ctrl_img_ready <= S_AXI_WDATA[2];   // pulse
	        end
	    end
	end

	assign enable    = ctrl_enable;
	assign start     = ctrl_start;
	assign img_ready = ctrl_img_ready;

	// ============================================================================
	// Status counters / latch
	// ============================================================================
	// img_cnt : img_done 누적 (0~10000)
	reg [13:0] img_cnt;
	always @(posedge S_AXI_ACLK) begin
	    if (!S_AXI_ARESETN)       img_cnt <= 14'd0;
	    else if (img_done && img_cnt < 14'd10000)
	                              img_cnt <= img_cnt + 14'd1;
	end

	// done : img_cnt == 10000 latch
	reg done_latch;
	always @(posedge S_AXI_ACLK) begin
	    if (!S_AXI_ARESETN)            done_latch <= 1'b0;
	    else if (img_cnt == 14'd10000) done_latch <= 1'b1;
	end

	// result : img_done 시 latch
	reg [3:0] result_latch;
	always @(posedge S_AXI_ACLK) begin
	    if (!S_AXI_ARESETN) result_latch <= 4'd0;
	    else if (img_done)  result_latch <= result;
	end

	// can_load : (img_ready 발행 - input_consumed) < 2  (input BRAM 2-bank backpressure)
	reg [2:0] inflight;   // 적재했지만 conv1 read 전인 image 수
	always @(posedge S_AXI_ACLK) begin
	    if (!S_AXI_ARESETN) inflight <= 3'd0;
	    else begin
	        case ({ctrl_img_ready, input_consumed})
	            2'b10:   inflight <= inflight + 3'd1;
	            2'b01:   inflight <= (inflight == 0) ? 3'd0 : inflight - 3'd1;
	            default: inflight <= inflight;   // 2'b11 / 2'b00 : 유지
	        endcase
	    end
	end
	wire can_load = (inflight < 3'd2);

	// timer : 첫 start pulse 부터 done 까지 free-running 48-bit
	reg [47:0] timer;
	reg        timer_run;
	always @(posedge S_AXI_ACLK) begin
	    if (!S_AXI_ARESETN) begin
	        timer     <= 48'd0;
	        timer_run <= 1'b0;
	    end else begin
	        if (ctrl_start) timer_run <= 1'b1;          // 첫 start 에 가동
	        if (timer_run && !done_latch)
	            timer <= timer + 48'd1;
	    end
	end

	// ============================================================================
	// AXI Read 채널 FSM (제공 베이스 유지)
	// ============================================================================
	always @(posedge S_AXI_ACLK)
	  begin
	    if (S_AXI_ARESETN == 1'b0)
	      begin
	         axi_arready <= 1'b0;
	         axi_rvalid <= 1'b0;
	         axi_rresp <= 1'b0;
	         state_read <= Idle;
	      end
	    else
	      begin
	        case(state_read)
	          Idle:
	            begin
	              if (S_AXI_ARESETN == 1'b1)
	                begin
	                  state_read <= Raddr;
	                  axi_arready <= 1'b1;
	                end
	              else state_read <= state_read;
	            end
	          Raddr:
	            begin
	              if (S_AXI_ARVALID && S_AXI_ARREADY)
	                begin
	                  state_read <= Rdata;
	                  axi_araddr <= S_AXI_ARADDR;
	                  axi_rvalid <= 1'b1;
	                  axi_arready <= 1'b0;
	                end
	              else state_read <= state_read;
	            end
	          Rdata:
	            begin
	              if (S_AXI_RVALID && S_AXI_RREADY)
	                begin
	                  axi_rvalid <= 1'b0;
	                  axi_arready <= 1'b1;
	                  state_read <= Raddr;
	                end
	              else state_read <= state_read;
	            end
	         endcase
	        end
	      end

	// ============================================================================
	// Read data mux
	// ============================================================================
	wire [OPT_MEM_ADDR_BITS:0] rd_index =
	       axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB];

	wire [31:0] ctrl_rb = {29'd0, ctrl_img_ready, ctrl_start, ctrl_enable};
	wire [31:0] status  = {12'd0, img_cnt, can_load, result_latch, done_latch};

	assign S_AXI_RDATA =
	       (rd_index == REG_CTRL) ? ctrl_rb                       :
	       (rd_index == REG_STAT) ? status                        :
	       (rd_index == REG_TLO ) ? timer[31:0]                   :
	       (rd_index == REG_THI ) ? {16'd0, timer[47:32]}         : 32'd0;

	endmodule
