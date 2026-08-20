`timescale 1ns / 1ps

// CPU-assisted MicroBlossom application. Canonical QShell records pass intact
// between the resident router and the bound co-processor. The selected CPU gets
// only the compact, graph-specific accelerator MMIO window implemented below.
module microblossom_coprocessor_application #(
    parameter int DATA_W = 512,
    parameter int ID_W = 6
) (
    input logic aclk,
    input logic aresetn,
    input logic coprocessor_bound,
    input logic coprocessor_ready,
    input logic coprocessor_fault,

    input logic [DATA_W-1:0] host_request_tdata,
    input logic [DATA_W/8-1:0] host_request_tkeep,
    input logic [ID_W-1:0] host_request_tid,
    input logic host_request_tlast,
    input logic host_request_tvalid,
    output logic host_request_tready,
    output logic [DATA_W-1:0] host_result_tdata,
    output logic [DATA_W/8-1:0] host_result_tkeep,
    output logic [ID_W-1:0] host_result_tid,
    output logic host_result_tlast,
    output logic host_result_tvalid,
    input logic host_result_tready,

    output logic [DATA_W-1:0] coprocessor_send_tdata,
    output logic [DATA_W/8-1:0] coprocessor_send_tkeep,
    output logic [ID_W-1:0] coprocessor_send_tid,
    output logic coprocessor_send_tlast,
    output logic coprocessor_send_tvalid,
    input logic coprocessor_send_tready,
    input logic [DATA_W-1:0] coprocessor_recv_tdata,
    input logic [DATA_W/8-1:0] coprocessor_recv_tkeep,
    input logic [ID_W-1:0] coprocessor_recv_tid,
    input logic coprocessor_recv_tlast,
    input logic coprocessor_recv_tvalid,
    output logic coprocessor_recv_tready,

    input logic [11:0] mmio_awaddr,
    input logic [2:0] mmio_awprot,
    input logic mmio_awvalid,
    output logic mmio_awready,
    input logic [63:0] mmio_wdata,
    input logic [7:0] mmio_wstrb,
    input logic mmio_wvalid,
    output logic mmio_wready,
    output logic [1:0] mmio_bresp,
    output logic mmio_bvalid,
    input logic mmio_bready,
    input logic [11:0] mmio_araddr,
    input logic [2:0] mmio_arprot,
    input logic mmio_arvalid,
    output logic mmio_arready,
    output logic [63:0] mmio_rdata,
    output logic [1:0] mmio_rresp,
    output logic mmio_rvalid,
    input logic mmio_rready
);

logic active;
logic fast_aresetn;
logic slow_clk;
logic slow_aresetn;

logic m_axi_awvalid;
logic m_axi_awready;
logic [22:0] m_axi_awaddr;
logic [15:0] m_axi_awid;
logic [7:0] m_axi_awlen;
logic [2:0] m_axi_awsize;
logic [1:0] m_axi_awburst;
logic m_axi_awlock;
logic [3:0] m_axi_awcache;
logic [3:0] m_axi_awqos;
logic [15:0] m_axi_awuser;
logic [2:0] m_axi_awprot;
logic m_axi_wvalid;
logic m_axi_wready;
logic [63:0] m_axi_wdata;
logic [7:0] m_axi_wstrb;
logic m_axi_wlast;
logic m_axi_bvalid;
logic m_axi_bready;
logic [15:0] m_axi_bid;
logic [1:0] m_axi_bresp;
logic m_axi_arvalid;
logic m_axi_arready;
logic [22:0] m_axi_araddr;
logic [15:0] m_axi_arid;
logic [7:0] m_axi_arlen;
logic [2:0] m_axi_arsize;
logic [1:0] m_axi_arburst;
logic m_axi_arlock;
logic [3:0] m_axi_arcache;
logic [3:0] m_axi_arqos;
logic [15:0] m_axi_aruser;
logic [2:0] m_axi_arprot;
logic m_axi_rvalid;
logic m_axi_rready;
logic [63:0] m_axi_rdata;
logic [15:0] m_axi_rid;
logic [1:0] m_axi_rresp;
logic m_axi_rlast;

assign active = coprocessor_bound && coprocessor_ready && !coprocessor_fault;

always_comb begin
    coprocessor_send_tdata = host_request_tdata;
    coprocessor_send_tkeep = host_request_tkeep;
    coprocessor_send_tid = host_request_tid;
    coprocessor_send_tlast = host_request_tlast;
    coprocessor_send_tvalid = host_request_tvalid && active;
    host_request_tready = coprocessor_send_tready && active;

    host_result_tdata = coprocessor_recv_tdata;
    host_result_tkeep = coprocessor_recv_tkeep;
    host_result_tid = coprocessor_recv_tid;
    host_result_tlast = coprocessor_recv_tlast;
    host_result_tvalid = coprocessor_recv_tvalid && active;
    coprocessor_recv_tready = host_result_tready && active;
end

microblossom_qshell_clock_div2 inst_clock_divider (
    .aclk(aclk), .aresetn(aresetn), .fast_aresetn(fast_aresetn),
    .slow_clk(slow_clk), .slow_aresetn(slow_aresetn)
);

microblossom_coprocessor_mmio inst_mmio (
    .aclk(aclk), .aresetn(fast_aresetn),
    .s_axi_awaddr(mmio_awaddr), .s_axi_awprot(mmio_awprot),
    .s_axi_awvalid(mmio_awvalid), .s_axi_awready(mmio_awready),
    .s_axi_wdata(mmio_wdata), .s_axi_wstrb(mmio_wstrb),
    .s_axi_wvalid(mmio_wvalid), .s_axi_wready(mmio_wready),
    .s_axi_bresp(mmio_bresp), .s_axi_bvalid(mmio_bvalid), .s_axi_bready(mmio_bready),
    .s_axi_araddr(mmio_araddr), .s_axi_arprot(mmio_arprot),
    .s_axi_arvalid(mmio_arvalid), .s_axi_arready(mmio_arready),
    .s_axi_rdata(mmio_rdata), .s_axi_rresp(mmio_rresp),
    .s_axi_rvalid(mmio_rvalid), .s_axi_rready(mmio_rready),
    .*
);

MicroBlossomBus inst_accelerator (
    .s0_awvalid(m_axi_awvalid), .s0_awready(m_axi_awready), .s0_awaddr(m_axi_awaddr),
    .s0_awid(m_axi_awid), .s0_awlen(m_axi_awlen), .s0_awsize(m_axi_awsize),
    .s0_awburst(m_axi_awburst), .s0_awlock(m_axi_awlock), .s0_awcache(m_axi_awcache),
    .s0_awqos(m_axi_awqos), .s0_awuser(m_axi_awuser), .s0_awprot(m_axi_awprot),
    .s0_wvalid(m_axi_wvalid), .s0_wready(m_axi_wready), .s0_wdata(m_axi_wdata),
    .s0_wstrb(m_axi_wstrb), .s0_wlast(m_axi_wlast), .s0_bvalid(m_axi_bvalid),
    .s0_bready(m_axi_bready), .s0_bid(m_axi_bid), .s0_bresp(m_axi_bresp),
    .s0_arvalid(m_axi_arvalid), .s0_arready(m_axi_arready), .s0_araddr(m_axi_araddr),
    .s0_arid(m_axi_arid), .s0_arlen(m_axi_arlen), .s0_arsize(m_axi_arsize),
    .s0_arburst(m_axi_arburst), .s0_arlock(m_axi_arlock), .s0_arcache(m_axi_arcache),
    .s0_arqos(m_axi_arqos), .s0_aruser(m_axi_aruser), .s0_arprot(m_axi_arprot),
    .s0_rvalid(m_axi_rvalid), .s0_rready(m_axi_rready), .s0_rdata(m_axi_rdata),
    .s0_rid(m_axi_rid), .s0_rresp(m_axi_rresp), .s0_rlast(m_axi_rlast),
    .slow_clk(slow_clk), .slow_reset(!slow_aresetn), .reset(!fast_aresetn), .clk(aclk)
);

`ifndef SYNTHESIS
assert property (@(posedge aclk) disable iff (!aresetn || !active)
    coprocessor_send_tvalid && !coprocessor_send_tready |=>
    coprocessor_send_tvalid && $stable({coprocessor_send_tdata,
                                        coprocessor_send_tkeep,
                                        coprocessor_send_tid,
                                        coprocessor_send_tlast}));
assert property (@(posedge aclk) disable iff (!aresetn || !active)
    host_result_tvalid && !host_result_tready |=>
    host_result_tvalid && $stable({host_result_tdata, host_result_tkeep,
                                   host_result_tid, host_result_tlast}));
`endif

endmodule
