`timescale 1ns/1ps
module tb_coprocessor_mmio;
logic clk=0, resetn=0; always #5 clk=~clk;
logic [11:0] s_axi_awaddr; logic [2:0] s_axi_awprot; logic s_axi_awvalid; logic s_axi_awready;
logic [63:0] s_axi_wdata; logic [7:0] s_axi_wstrb; logic s_axi_wvalid; logic s_axi_wready;
logic [1:0] s_axi_bresp; logic s_axi_bvalid; logic s_axi_bready;
logic [11:0] s_axi_araddr; logic [2:0] s_axi_arprot; logic s_axi_arvalid; logic s_axi_arready;
logic [63:0] s_axi_rdata; logic [1:0] s_axi_rresp; logic s_axi_rvalid; logic s_axi_rready;
logic m_axi_awvalid,m_axi_awready=1; logic [22:0] m_axi_awaddr; logic [15:0] m_axi_awid;
logic [7:0] m_axi_awlen; logic [2:0] m_axi_awsize; logic [1:0] m_axi_awburst; logic m_axi_awlock;
logic [3:0] m_axi_awcache,m_axi_awqos; logic [15:0] m_axi_awuser; logic [2:0] m_axi_awprot;
logic m_axi_wvalid,m_axi_wready=1; logic [63:0] m_axi_wdata; logic [7:0] m_axi_wstrb; logic m_axi_wlast;
logic m_axi_bvalid=0,m_axi_bready; logic [15:0] m_axi_bid=0; logic [1:0] m_axi_bresp=0;
logic m_axi_arvalid,m_axi_arready=1; logic [22:0] m_axi_araddr; logic [15:0] m_axi_arid;
logic [7:0] m_axi_arlen; logic [2:0] m_axi_arsize; logic [1:0] m_axi_arburst; logic m_axi_arlock;
logic [3:0] m_axi_arcache,m_axi_arqos; logic [15:0] m_axi_aruser; logic [2:0] m_axi_arprot;
logic m_axi_rvalid=0,m_axi_rready; logic [63:0] m_axi_rdata=64'h1234; logic [15:0] m_axi_rid=0;
logic [1:0] m_axi_rresp=0; logic m_axi_rlast=1;

microblossom_coprocessor_mmio dut(.aclk(clk),.aresetn(resetn),.*);

task automatic write(input [11:0] addr,input [63:0] data,input [1:0] expected);
 begin
  $display("WRITE_START %h", addr);
  @(negedge clk); s_axi_awaddr=addr;s_axi_awvalid=1;s_axi_wdata=data;s_axi_wstrb=8'hff;s_axi_wvalid=1;
  wait(s_axi_awready&&s_axi_wready); $display("HOST_WRITE_READY"); @(negedge clk);s_axi_awvalid=0;s_axi_wvalid=0;
  if(expected==0) begin wait(m_axi_awvalid&&m_axi_wvalid); $display("APP_WRITE_VALID"); assert(m_axi_awaddr == (addr == 12'h010 ? 23'h001000 : 23'h020010));
   @(negedge clk);m_axi_bvalid=1; end
  wait(s_axi_bvalid); $display("HOST_WRITE_RESPONSE"); assert(s_axi_bresp==expected); s_axi_bready=1; @(posedge clk); @(negedge clk); s_axi_bready=0; m_axi_bvalid=0; $display("WRITE_DONE %h", addr);
 end
endtask

task automatic read(input [11:0] addr,input [22:0] translated,input [1:0] expected);
 begin
  $display("READ_START %h", addr);
  @(negedge clk);s_axi_araddr=addr;s_axi_arvalid=1; wait(s_axi_arready); @(negedge clk);s_axi_arvalid=0;
  if(expected==0) begin wait(m_axi_arvalid);assert(m_axi_araddr==translated);@(negedge clk);m_axi_rvalid=1; end
  wait(s_axi_rvalid);assert(s_axi_rresp==expected);if(expected==0)assert(s_axi_rdata==64'h1234);s_axi_rready=1;@(posedge clk);@(negedge clk);s_axi_rready=0;m_axi_rvalid=0;$display("READ_DONE %h", addr);
 end
endtask

initial begin
 #10000 $fatal(1, "MMIO_TEST_TIMEOUT");
end
initial begin
 s_axi_awaddr=0;s_axi_awprot=0;s_axi_awvalid=0;s_axi_wdata=0;s_axi_wstrb=0;s_axi_wvalid=0;
 s_axi_bready=0;s_axi_araddr=0;s_axi_arprot=0;s_axi_arvalid=0;s_axi_rready=0;
 repeat(3)@(negedge clk);resetn=1;
 write(12'h010,64'h55,0); write(12'h020,64'h2,0); write(12'h088,0,3);
 read(12'h000,23'h000008,0); read(12'h008,23'h000010,0); read(12'h028,23'h020020,0); read(12'h088,0,3);
 $display("MICROBLOSSOM_COPROCESSOR_MMIO_PASS");$finish;
end
endmodule
