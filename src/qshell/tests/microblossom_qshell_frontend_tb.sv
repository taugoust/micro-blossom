`timescale 1ns / 1ps
module tb;
localparam logic [255:0] GRAPH_ID = 256'hc5165387fab584bd0e1cbe32e5e49b89b3979a56146472a94eb26d6c3b8d074b;
localparam logic [31:0] MAGIC = 32'h3151_424d;
logic aclk=0, aresetn=0;
logic [511:0] s_axis_tdata, m_axis_tdata;
logic [63:0] s_axis_tkeep, m_axis_tkeep;
logic [5:0] s_axis_tid, m_axis_tid;
logic s_axis_tlast,s_axis_tvalid,s_axis_tready,m_axis_tlast,m_axis_tvalid,m_axis_tready;
logic m_axi_awvalid,m_axi_awready,m_axi_awlock;
logic [22:0] m_axi_awaddr;
logic [15:0] m_axi_awid,m_axi_awuser;
logic [7:0] m_axi_awlen;
logic [2:0] m_axi_awsize,m_axi_awprot;
logic [1:0] m_axi_awburst;
logic [3:0] m_axi_awcache,m_axi_awqos;
logic m_axi_wvalid,m_axi_wready,m_axi_wlast;
logic [63:0] m_axi_wdata;
logic [7:0] m_axi_wstrb;
logic m_axi_bvalid,m_axi_bready;
logic [15:0] m_axi_bid;
logic [1:0] m_axi_bresp;
logic m_axi_arvalid,m_axi_arready,m_axi_arlock;
logic [22:0] m_axi_araddr;
logic [15:0] m_axi_arid,m_axi_aruser;
logic [7:0] m_axi_arlen;
logic [2:0] m_axi_arsize,m_axi_arprot;
logic [1:0] m_axi_arburst;
logic [3:0] m_axi_arcache,m_axi_arqos;
logic m_axi_rvalid,m_axi_rready,m_axi_rlast;
logic [63:0] m_axi_rdata;
logic [15:0] m_axi_rid;
logic [1:0] m_axi_rresp;

microblossom_qshell_frontend #(.GRAPH_ID(GRAPH_ID),.TIMEOUT_CYCLES(12)) dut (.*);
always #2 aclk=~aclk;

function automatic logic [511:0] rec(
 input logic [7:0] ver,op,input logic [15:0] flags,
 input logic [31:0] rid,seq,input logic [255:0] graph,
 input logic [63:0] arg0,arg1);
 logic [511:0] v;
 begin
  v='0; v[31:0]=MAGIC; v[39:32]=ver; v[47:40]=op; v[63:48]=flags;
  v[95:64]=rid; v[127:96]=seq; v[383:128]=graph;
  v[447:384]=arg0; v[511:448]=arg1; rec=v;
 end
endfunction

task automatic reset_dut;
 begin
  @(negedge aclk); aresetn=0; repeat(3) @(posedge aclk);
  @(negedge aclk); aresetn=1; @(posedge aclk);
 end
endtask

task automatic send(input logic [511:0] v,input logic [5:0] tid);
 begin
  @(negedge aclk); s_axis_tdata=v; s_axis_tid=tid; s_axis_tvalid=1;
  do @(posedge aclk); while(!s_axis_tready);
  @(negedge aclk); s_axis_tvalid=0;
 end
endtask

task automatic check_response(input logic [511:0] v,input logic [5:0] tid);
 logic [511:0] held;
 begin
  while(!m_axis_tvalid) @(posedge aclk);
  held=m_axis_tdata;
  assert(held==v) else $fatal(1,"response mismatch");
  assert(m_axis_tid==tid && m_axis_tkeep==64'hffff_ffff_ffff_ffff && m_axis_tlast)
   else $fatal(1,"response sideband mismatch");
  repeat(3) begin
   @(posedge aclk);
   assert(m_axis_tvalid && m_axis_tdata==held) else $fatal(1,"response changed under backpressure");
   assert(!s_axis_tready) else $fatal(1,"request accepted while response blocked");
  end
  @(negedge aclk); m_axis_tready=1; @(posedge aclk); @(negedge aclk); m_axis_tready=0;
 end
endtask

task automatic service_write(
 input logic [22:0] address,input logic [2:0] size,
 input logic [63:0] data,input logic [7:0] strobe,input logic [1:0] response);
 begin
  repeat(2) begin @(posedge aclk); assert(!s_axis_tready) else $fatal(1,"write did not backpressure input"); end
  @(negedge aclk); m_axi_awready=1; do @(posedge aclk); while(!m_axi_awvalid);
  assert(m_axi_awaddr==address && m_axi_awsize==size && m_axi_awlen==0 && m_axi_awburst==1)
   else $fatal(1,"AW mismatch");
  @(negedge aclk); m_axi_awready=0; m_axi_wready=1; do @(posedge aclk); while(!m_axi_wvalid);
  assert(m_axi_wdata==data && m_axi_wstrb==strobe && m_axi_wlast) else $fatal(1,"W mismatch");
  @(negedge aclk); m_axi_wready=0; m_axi_bresp=response; m_axi_bvalid=1;
  do @(posedge aclk); while(!m_axi_bready);
  @(negedge aclk); m_axi_bvalid=0; m_axi_bresp=0;
 end
endtask

task automatic service_read(input logic [22:0] address,input logic [2:0] size,input logic [63:0] data);
 begin
  repeat(2) begin @(posedge aclk); assert(!s_axis_tready) else $fatal(1,"read did not backpressure input"); end
  @(negedge aclk); m_axi_arready=1; do @(posedge aclk); while(!m_axi_arvalid);
  assert(m_axi_araddr==address && m_axi_arsize==size && m_axi_arlen==0 && m_axi_arburst==1)
   else $fatal(1,"AR mismatch");
  @(negedge aclk); m_axi_arready=0;
  repeat(2) @(posedge aclk);
  @(negedge aclk); m_axi_rdata=data; m_axi_rvalid=1;
  do @(posedge aclk); while(!m_axi_rready);
  @(negedge aclk); m_axi_rvalid=0;
 end
endtask

initial begin : tests
 logic [511:0] v;
 s_axis_tdata='0; s_axis_tkeep='1; s_axis_tid='0; s_axis_tlast=1; s_axis_tvalid=0;
 m_axis_tready=0;
 m_axi_awready=0; m_axi_wready=0; m_axi_bvalid=0; m_axi_bid=0; m_axi_bresp=0;
 m_axi_arready=0; m_axi_rvalid=0; m_axi_rdata=0; m_axi_rid=0; m_axi_rresp=0; m_axi_rlast=1;
 reset_dut();

 // Ordered multi-record job, independent AW/W handshakes, narrow lane shifts,
 // read-result backpressure, and successful completion.
 send(rec(1,8'h01,0,32'h11223344,0,GRAPH_ID,2,0),6'h15);
 send(rec(1,8'h02,1,32'h11223344,1,GRAPH_ID,64'h12,64'hbeef),6'h16);
 service_write(23'h12,3'd1,64'h0000_0000_beef_0000,8'h0c,0);
 send(rec(1,8'h03,2,32'h11223344,2,GRAPH_ID,64'h24,0),6'h17);
 service_read(23'h24,3'd2,64'hfeed_face_0000_0000);
 check_response(rec(1,8'h83,16'h0102,32'h11223344,2,GRAPH_ID,64'h24,64'hfeed_face),6'h17);
 send(rec(1,8'h04,0,32'h11223344,3,GRAPH_ID,0,0),6'h18);
 check_response(rec(1,8'h84,16'h0100,32'h11223344,3,GRAPH_ID,0,2),6'h18);

 // Graph identity is checked before a job is admitted.
 send(rec(1,8'h01,0,32'h20,0,~GRAPH_ID,0,0),1);
 check_response(rec(1,8'hff,16'h0100,32'h20,0,GRAPH_ID,3,0),1);

 // Version, opcode/flags, framing, and sequence failures become errors.
 send(rec(2,8'h01,0,32'h21,0,GRAPH_ID,0,0),2);
 check_response(rec(1,8'hff,16'h0100,32'h21,0,GRAPH_ID,2,2),2);
 send(rec(1,8'h55,16'h0400,32'h22,0,GRAPH_ID,0,0),3);
 check_response(rec(1,8'hff,16'h0100,32'h22,0,GRAPH_ID,1,64'h0400),3);
 @(negedge aclk); s_axis_tkeep=64'hffff_ffff_ffff_fffe;
 send(rec(1,8'h01,0,32'h23,0,GRAPH_ID,0,0),4);
 @(negedge aclk); s_axis_tkeep='1;
 check_response(rec(1,8'hff,16'h0100,32'h23,0,GRAPH_ID,1,1),4);

 send(rec(1,8'h01,0,32'h30,0,GRAPH_ID,64'hffff_ffff_ffff_ffff,0),5);
 send(rec(1,8'h03,3,32'h30,2,GRAPH_ID,0,0),5);
 check_response(rec(1,8'hff,16'h0100,32'h30,2,GRAPH_ID,4,1),5);

 // Alignment and exact operation-count checks abort malformed jobs.
 send(rec(1,8'h01,0,32'h31,0,GRAPH_ID,1,0),6);
 send(rec(1,8'h02,2,32'h31,1,GRAPH_ID,2,0),6);
 check_response(rec(1,8'hff,16'h0100,32'h31,1,GRAPH_ID,5,2),6);
 send(rec(1,8'h01,0,32'h32,0,GRAPH_ID,1,0),7);
 send(rec(1,8'h04,0,32'h32,1,GRAPH_ID,0,0),7);
 check_response(rec(1,8'hff,16'h0100,32'h32,1,GRAPH_ID,6,0),7);

 // Accelerator failures are surfaced with the original operation sequence.
 send(rec(1,8'h01,0,32'h40,0,GRAPH_ID,1,0),8);
 send(rec(1,8'h02,3,32'h40,1,GRAPH_ID,64'h100,64'h1234),8);
 service_write(23'h100,3'd3,64'h1234,8'hff,2);
 check_response(rec(1,8'hff,16'h0100,32'h40,1,GRAPH_ID,7,2),8);

 // Reset aborts an active job without manufacturing a completion.
 send(rec(1,8'h01,0,32'h50,0,GRAPH_ID,0,0),9);
 reset_dut();
 send(rec(1,8'h04,0,32'h50,1,GRAPH_ID,0,0),9);
 check_response(rec(1,8'hff,16'h0100,32'h50,1,GRAPH_ID,6,4),9);

 // A timed-out AXI operation reports timeout and quarantines the proxy until
 // reset, preventing stale AXI responses from entering a later job.
 send(rec(1,8'h01,0,32'h60,0,GRAPH_ID,64'hffff_ffff_ffff_ffff,0),10);
 send(rec(1,8'h03,3,32'h60,1,GRAPH_ID,0,0),10);
 check_response(rec(1,8'h84,16'h0100,32'h60,1,GRAPH_ID,2,0),10);
 repeat(3) begin @(posedge aclk); assert(!s_axis_tready) else $fatal(1,"timeout did not quarantine frontend"); end
 reset_dut();
 assert(s_axis_tready) else $fatal(1,"reset did not recover frontend");

 $display("MICROBLOSSOM_QSHELL_FRONTEND_PASS");
 $finish;
end
endmodule
