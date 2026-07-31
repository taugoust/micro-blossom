`timescale 1ns / 1ps

// Board-independent composition of the protocol-v1 frontend and one generated
// 64-bit AXI4 MicroBlossom accelerator. The stream on this module is the
// internal 64-byte MBQ1 record stream; an outer QShell envelope adapter is
// intentionally separate and will be selected by the shared QShell ABI work.
module microblossom_qshell_core #(
    parameter int AXIS_ID_W = 6,
    parameter int TIMEOUT_CYCLES = 1024,
    parameter logic [255:0] GRAPH_ID = '0
) (
    input  logic                 aclk,
    input  logic                 slow_clk,
    input  logic                 aresetn,

    input  logic [511:0]         s_axis_tdata,
    input  logic [63:0]          s_axis_tkeep,
    input  logic [AXIS_ID_W-1:0] s_axis_tid,
    input  logic                 s_axis_tlast,
    input  logic                 s_axis_tvalid,
    output logic                 s_axis_tready,

    output logic [511:0]         m_axis_tdata,
    output logic [63:0]          m_axis_tkeep,
    output logic [AXIS_ID_W-1:0] m_axis_tid,
    output logic                 m_axis_tlast,
    output logic                 m_axis_tvalid,
    input  logic                 m_axis_tready
);

// The generated d3 MicroBlossomBus has a fixed 23-bit AXI4 address port.
localparam int AXI_ADDR_W = 23;

logic                  m_axi_awvalid;
logic                  m_axi_awready;
logic [AXI_ADDR_W-1:0] m_axi_awaddr;
logic [15:0]           m_axi_awid;
logic [7:0]            m_axi_awlen;
logic [2:0]            m_axi_awsize;
logic [1:0]            m_axi_awburst;
logic                  m_axi_awlock;
logic [3:0]            m_axi_awcache;
logic [3:0]            m_axi_awqos;
logic [15:0]           m_axi_awuser;
logic [2:0]            m_axi_awprot;
logic                  m_axi_wvalid;
logic                  m_axi_wready;
logic [63:0]           m_axi_wdata;
logic [7:0]            m_axi_wstrb;
logic                  m_axi_wlast;
logic                  m_axi_bvalid;
logic                  m_axi_bready;
logic [15:0]           m_axi_bid;
logic [1:0]            m_axi_bresp;
logic                  m_axi_arvalid;
logic                  m_axi_arready;
logic [AXI_ADDR_W-1:0] m_axi_araddr;
logic [15:0]           m_axi_arid;
logic [7:0]            m_axi_arlen;
logic [2:0]            m_axi_arsize;
logic [1:0]            m_axi_arburst;
logic                  m_axi_arlock;
logic [3:0]            m_axi_arcache;
logic [3:0]            m_axi_arqos;
logic [15:0]           m_axi_aruser;
logic [2:0]            m_axi_arprot;
logic                  m_axi_rvalid;
logic                  m_axi_rready;
logic [63:0]           m_axi_rdata;
logic [15:0]           m_axi_rid;
logic [1:0]            m_axi_rresp;
logic                  m_axi_rlast;

microblossom_qshell_frontend #(
    .AXIS_ID_W(AXIS_ID_W),
    .AXI_ADDR_W(AXI_ADDR_W),
    .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
    .GRAPH_ID(GRAPH_ID)
) inst_frontend (.*);

MicroBlossomBus inst_accelerator (
    .s0_awvalid(m_axi_awvalid),
    .s0_awready(m_axi_awready),
    .s0_awaddr(m_axi_awaddr),
    .s0_awid(m_axi_awid),
    .s0_awlen(m_axi_awlen),
    .s0_awsize(m_axi_awsize),
    .s0_awburst(m_axi_awburst),
    .s0_awlock(m_axi_awlock),
    .s0_awcache(m_axi_awcache),
    .s0_awqos(m_axi_awqos),
    .s0_awuser(m_axi_awuser),
    .s0_awprot(m_axi_awprot),
    .s0_wvalid(m_axi_wvalid),
    .s0_wready(m_axi_wready),
    .s0_wdata(m_axi_wdata),
    .s0_wstrb(m_axi_wstrb),
    .s0_wlast(m_axi_wlast),
    .s0_bvalid(m_axi_bvalid),
    .s0_bready(m_axi_bready),
    .s0_bid(m_axi_bid),
    .s0_bresp(m_axi_bresp),
    .s0_arvalid(m_axi_arvalid),
    .s0_arready(m_axi_arready),
    .s0_araddr(m_axi_araddr),
    .s0_arid(m_axi_arid),
    .s0_arlen(m_axi_arlen),
    .s0_arsize(m_axi_arsize),
    .s0_arburst(m_axi_arburst),
    .s0_arlock(m_axi_arlock),
    .s0_arcache(m_axi_arcache),
    .s0_arqos(m_axi_arqos),
    .s0_aruser(m_axi_aruser),
    .s0_arprot(m_axi_arprot),
    .s0_rvalid(m_axi_rvalid),
    .s0_rready(m_axi_rready),
    .s0_rdata(m_axi_rdata),
    .s0_rid(m_axi_rid),
    .s0_rresp(m_axi_rresp),
    .s0_rlast(m_axi_rlast),
    .slow_clk(slow_clk),
    .reset(!aresetn),
    .clk(aclk)
);

endmodule
