`timescale 1ns / 1ps

// Complete board-independent MicroBlossom application datapath. Board wrappers
// connect these raw stream signals to Coyote's AXI4SR interfaces unchanged.
module microblossom_qshell_application #(
    parameter int AXIS_ID_W = 6,
    parameter int TIMEOUT_CYCLES = 1024,
    parameter logic [255:0] GRAPH_ID = '0
) (
    input  logic                  aclk,
    input  logic                  aresetn,

    input  logic [511:0]          s_axis_tdata,
    input  logic [63:0]           s_axis_tkeep,
    input  logic [AXIS_ID_W-1:0]  s_axis_tid,
    input  logic                  s_axis_tlast,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,

    output logic [511:0]          m_axis_tdata,
    output logic [63:0]           m_axis_tkeep,
    output logic [AXIS_ID_W-1:0]  m_axis_tid,
    output logic                  m_axis_tlast,
    output logic                  m_axis_tvalid,
    input  logic                  m_axis_tready
);

logic fast_aresetn;
logic slow_clk;
logic slow_aresetn;
logic [511:0] mbq_request_tdata;
logic [63:0] mbq_request_tkeep;
logic [AXIS_ID_W-1:0] mbq_request_tid;
logic mbq_request_tlast;
logic mbq_request_tvalid;
logic mbq_request_tready;
logic [511:0] mbq_response_tdata;
logic [63:0] mbq_response_tkeep;
logic [AXIS_ID_W-1:0] mbq_response_tid;
logic mbq_response_tlast;
logic mbq_response_tvalid;
logic mbq_response_tready;

microblossom_qshell_clock_div2 inst_clock_divider (
    .aclk(aclk),
    .aresetn(aresetn),
    .fast_aresetn(fast_aresetn),
    .slow_clk(slow_clk),
    .slow_aresetn(slow_aresetn)
);

microblossom_qshell_envelope_v2 #(
    .AXIS_ID_W(AXIS_ID_W)
) inst_envelope (
    .aclk(aclk),
    .aresetn(fast_aresetn),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tid(s_axis_tid),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tid(m_axis_tid),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .mbq_s_axis_tdata(mbq_request_tdata),
    .mbq_s_axis_tkeep(mbq_request_tkeep),
    .mbq_s_axis_tid(mbq_request_tid),
    .mbq_s_axis_tlast(mbq_request_tlast),
    .mbq_s_axis_tvalid(mbq_request_tvalid),
    .mbq_s_axis_tready(mbq_request_tready),
    .mbq_m_axis_tdata(mbq_response_tdata),
    .mbq_m_axis_tkeep(mbq_response_tkeep),
    .mbq_m_axis_tid(mbq_response_tid),
    .mbq_m_axis_tlast(mbq_response_tlast),
    .mbq_m_axis_tvalid(mbq_response_tvalid),
    .mbq_m_axis_tready(mbq_response_tready)
);

microblossom_qshell_core #(
    .AXIS_ID_W(AXIS_ID_W),
    .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
    .GRAPH_ID(GRAPH_ID)
) inst_core (
    .aclk(aclk),
    .slow_clk(slow_clk),
    .aresetn(fast_aresetn),
    .slow_aresetn(slow_aresetn),
    .s_axis_tdata(mbq_request_tdata),
    .s_axis_tkeep(mbq_request_tkeep),
    .s_axis_tid(mbq_request_tid),
    .s_axis_tlast(mbq_request_tlast),
    .s_axis_tvalid(mbq_request_tvalid),
    .s_axis_tready(mbq_request_tready),
    .m_axis_tdata(mbq_response_tdata),
    .m_axis_tkeep(mbq_response_tkeep),
    .m_axis_tid(mbq_response_tid),
    .m_axis_tlast(mbq_response_tlast),
    .m_axis_tvalid(mbq_response_tvalid),
    .m_axis_tready(mbq_response_tready)
);

endmodule
