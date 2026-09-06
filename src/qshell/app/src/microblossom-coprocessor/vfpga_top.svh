// Graph-specific CPU-assisted QShell MicroBlossom application for Coyote region 0.

import lynxTypes::*;

microblossom_coprocessor_application #(
    .DATA_W(AXI_DATA_BITS),
    .ID_W($bits(axis_host_recv[0].tid))
) inst_microblossom_coprocessor_application (
    .aclk(aclk),
    .aresetn(aresetn),
    .coprocessor_bound(coprocessor_status[0].bound),
    .coprocessor_ready(coprocessor_status[0].ready),
    .coprocessor_fault(coprocessor_status[0].fault),
    .host_request_tdata(axis_host_recv[0].tdata),
    .host_request_tkeep(axis_host_recv[0].tkeep),
    .host_request_tid(axis_host_recv[0].tid),
    .host_request_tlast(axis_host_recv[0].tlast),
    .host_request_tvalid(axis_host_recv[0].tvalid),
    .host_request_tready(axis_host_recv[0].tready),
    .host_result_tdata(axis_host_send[0].tdata),
    .host_result_tkeep(axis_host_send[0].tkeep),
    .host_result_tid(axis_host_send[0].tid),
    .host_result_tlast(axis_host_send[0].tlast),
    .host_result_tvalid(axis_host_send[0].tvalid),
    .host_result_tready(axis_host_send[0].tready),
    .coprocessor_send_tdata(axis_coprocessor_send[0].tdata),
    .coprocessor_send_tkeep(axis_coprocessor_send[0].tkeep),
    .coprocessor_send_tid(axis_coprocessor_send[0].tid),
    .coprocessor_send_tlast(axis_coprocessor_send[0].tlast),
    .coprocessor_send_tvalid(axis_coprocessor_send[0].tvalid),
    .coprocessor_send_tready(axis_coprocessor_send[0].tready),
    .coprocessor_recv_tdata(axis_coprocessor_recv[0].tdata),
    .coprocessor_recv_tkeep(axis_coprocessor_recv[0].tkeep),
    .coprocessor_recv_tid(axis_coprocessor_recv[0].tid),
    .coprocessor_recv_tlast(axis_coprocessor_recv[0].tlast),
    .coprocessor_recv_tvalid(axis_coprocessor_recv[0].tvalid),
    .coprocessor_recv_tready(axis_coprocessor_recv[0].tready),
    .mmio_awaddr(s_axi_coprocessor_mmio[0].awaddr),
    .mmio_awprot(s_axi_coprocessor_mmio[0].awprot),
    .mmio_awvalid(s_axi_coprocessor_mmio[0].awvalid),
    .mmio_awready(s_axi_coprocessor_mmio[0].awready),
    .mmio_wdata(s_axi_coprocessor_mmio[0].wdata),
    .mmio_wstrb(s_axi_coprocessor_mmio[0].wstrb),
    .mmio_wvalid(s_axi_coprocessor_mmio[0].wvalid),
    .mmio_wready(s_axi_coprocessor_mmio[0].wready),
    .mmio_bresp(s_axi_coprocessor_mmio[0].bresp),
    .mmio_bvalid(s_axi_coprocessor_mmio[0].bvalid),
    .mmio_bready(s_axi_coprocessor_mmio[0].bready),
    .mmio_araddr(s_axi_coprocessor_mmio[0].araddr),
    .mmio_arprot(s_axi_coprocessor_mmio[0].arprot),
    .mmio_arvalid(s_axi_coprocessor_mmio[0].arvalid),
    .mmio_arready(s_axi_coprocessor_mmio[0].arready),
    .mmio_rdata(s_axi_coprocessor_mmio[0].rdata),
    .mmio_rresp(s_axi_coprocessor_mmio[0].rresp),
    .mmio_rvalid(s_axi_coprocessor_mmio[0].rvalid),
    .mmio_rready(s_axi_coprocessor_mmio[0].rready)
);

always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();
always_comb axi_ctrl.tie_off_s();
