`timescale 1ns/1ps
// Exercise the complete rendered board wrapper and real envelope/frontend.
// The accelerator is inert: zero-operation jobs must not require decoder work.
package lynxTypes; endpackage
interface host_axis;
 logic [511:0] tdata;
 logic [63:0] tkeep;
 logic [5:0] tid;
 logic tlast, tvalid, tready;
endinterface
interface unused_control;
 logic idle;
 task automatic tie_off_m(); idle = 0; endtask
 task automatic tie_off_s(); idle = 0; endtask
endinterface
module rendered_host(input logic aclk, aresetn,
 host_axis axis_host_recv[1], host_axis axis_host_send[1]);
 unused_control notify(), sq_rd(), sq_wr(), cq_rd(), cq_wr(), axi_ctrl();
 `include "vfpga_top.svh"
endmodule
module tb_host_identity;
 `include "qshell_abi_generated.svh"
 logic aclk=0, aresetn=0;
 host_axis rx[1](), tx[1]();
 rendered_host dut(aclk, aresetn, rx, tx);
 logic [255:0] correct_graph, wrong_graph;
 always #2 aclk=~aclk;
 initial begin #40000; $fatal(1,"protocol watchdog"); end
 function automatic logic [383:0] header(input int seqno);
  logic [383:0] h;
  h='0;
  h[QSHELL_MAGIC_LSB +: QSHELL_MAGIC_W]=QSHELL_MAGIC;
  h[QSHELL_ABI_VERSION_LSB +: QSHELL_ABI_VERSION_W]=QSHELL_ABI_VERSION[7:0];
  h[QSHELL_RECORD_CLASS_LSB +: QSHELL_RECORD_CLASS_W]=QSHELL_CLASS_SYNDROME;
  h[QSHELL_HEADER_BYTES_LSB +: QSHELL_HEADER_BYTES_W]=QSHELL_HEADER_BYTES[15:0];
  h[QSHELL_PAYLOAD_BYTES_LSB +: QSHELL_PAYLOAD_BYTES_W]=64;
  h[QSHELL_CONTEXT_ID_LSB +: QSHELL_CONTEXT_ID_W]=7;
  h[QSHELL_ROUND_ID_LSB +: QSHELL_ROUND_ID_W]=42;
  h[QSHELL_SCHEMA_ID_LSB +: QSHELL_SCHEMA_ID_W]=QSHELL_SCHEMA_MICROBLOSSOM_COMMAND;
  h[QSHELL_SOURCE_ENDPOINT_ID_LSB +: QSHELL_SOURCE_ENDPOINT_ID_W]=18;
  h[QSHELL_DESTINATION_ENDPOINT_ID_LSB +: QSHELL_DESTINATION_ENDPOINT_ID_W]=257;
  h[QSHELL_RECORD_SEQUENCE_LSB +: QSHELL_RECORD_SEQUENCE_W]=seqno;
  return h;
 endfunction
 task automatic beat(input logic [511:0] data, input logic [63:0] keep, input logic last);
  @(negedge aclk);
  rx[0].tdata=data; rx[0].tkeep=keep; rx[0].tlast=last; rx[0].tvalid=1;
  do @(posedge aclk); while(!rx[0].tready);
  @(negedge aclk); rx[0].tvalid=0;
 endtask
 task automatic command(input logic [255:0] graph, input logic [7:0] opcode, input int seqno);
  logic [511:0] record;
  logic [383:0] outer_header;
  outer_header=header(seqno);
  if(opcode==4) outer_header[QSHELL_FLAGS_LSB +: QSHELL_FLAGS_W]=QSHELL_FLAG_END_OF_ROUND;
  record='0;
  record[31:0]=32'h3151424d; record[39:32]=1; record[47:40]=opcode;
  record[95:64]=123; record[127:96]=seqno; record[383:128]=graph;
  beat({record[127:0],outer_header}, '1, 0);
  beat({128'd0,record[511:128]},64'h0000ffffffffffff,1);
 endtask
 task automatic response(input logic [7:0] opcode, input logic [63:0] arg0);
  logic [127:0] prefix;
  logic [511:0] record;
  while(!tx[0].tvalid) @(negedge aclk);
  assert(tx[0].tkeep=='1 && !tx[0].tlast && tx[0].tid==5) else $fatal(1,"first beat framing");
  assert(tx[0].tdata[QSHELL_SCHEMA_ID_LSB +: QSHELL_SCHEMA_ID_W]==QSHELL_SCHEMA_MICROBLOSSOM_RESPONSE)
   else $fatal(1,"response schema");
  prefix=tx[0].tdata[511:384];
  @(posedge aclk); @(negedge aclk);
  while(!tx[0].tvalid) @(negedge aclk);
  assert(tx[0].tkeep==64'h0000ffffffffffff && tx[0].tlast && tx[0].tid==5) else $fatal(1,"last beat framing");
  record={tx[0].tdata[383:0],prefix};
  assert(record[47:40]==opcode && record[447:384]==arg0) else $fatal(1,"wrong protocol response %h",record);
  assert(record[383:128]==correct_graph) else $fatal(1,"response graph identity");
  @(posedge aclk); @(negedge aclk);
 endtask
 initial begin
  if(!$value$plusargs("correct=%h",correct_graph) || !$value$plusargs("wrong=%h",wrong_graph)) $fatal(1,"missing graph identities");
  rx[0].tdata=0; rx[0].tkeep=0; rx[0].tid=5; rx[0].tlast=0; rx[0].tvalid=0; tx[0].tready=1;
  repeat(10) @(negedge aclk); aresetn=1; repeat(20) @(negedge aclk);
  command(wrong_graph,1,0); response(8'hff,3);
  command(correct_graph,1,0);
  command(correct_graph,4,1); response(8'h84,0);
  command(wrong_graph,1,0); response(8'hff,3);
  $display("RENDERED_HOST_GRAPH_PROTOCOL_PASS"); $finish;
 end
endmodule
