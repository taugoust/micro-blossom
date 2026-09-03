// Host-driven MicroBlossom application using current QShell records.

import lynxTypes::*;

`include "hdl/microblossom_graph_identity.svh"

localparam int MICROBLOSSOM_AXIS_ID_W = $bits(axis_host_recv[0].tid);

microblossom_qshell_application #(
    .AXIS_ID_W(MICROBLOSSOM_AXIS_ID_W),
    .TIMEOUT_CYCLES(1024),
    .GRAPH_ID(MICROBLOSSOM_GRAPH_ID)
) inst_microblossom_qshell_application (
    .aclk(aclk),
    .aresetn(aresetn),
    .s_axis_tdata(axis_host_recv[0].tdata),
    .s_axis_tkeep(axis_host_recv[0].tkeep),
    .s_axis_tid(axis_host_recv[0].tid),
    .s_axis_tlast(axis_host_recv[0].tlast),
    .s_axis_tvalid(axis_host_recv[0].tvalid),
    .s_axis_tready(axis_host_recv[0].tready),
    .m_axis_tdata(axis_host_send[0].tdata),
    .m_axis_tkeep(axis_host_send[0].tkeep),
    .m_axis_tid(axis_host_send[0].tid),
    .m_axis_tlast(axis_host_send[0].tlast),
    .m_axis_tvalid(axis_host_send[0].tvalid),
    .m_axis_tready(axis_host_send[0].tready)
);

always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();
always_comb axi_ctrl.tie_off_s();

`ifdef EN_MEM
for (genvar card = 0; card < N_CARD_AXI; card++) begin : gen_tie_off_card
    always_comb begin
        axis_card_send[card].tie_off_m();
        axis_card_recv[card].tready = 1'b1;
    end
end
`endif

`ifdef EN_RDMA
always_comb rq_rd.tie_off_s();
for (genvar rdma = 0; rdma < N_RDMA_AXI; rdma++) begin : gen_tie_off_rdma
    always_comb begin
        axis_rreq_send[rdma].tie_off_m();
        axis_rreq_recv[rdma].tready = 1'b1;
        axis_rrsp_send[rdma].tie_off_m();
        axis_rrsp_recv[rdma].tready = 1'b1;
    end
end
`endif

`ifdef EN_NET
always_comb rq_wr.tie_off_s();
`endif

`ifdef EN_TCP
for (genvar tcp = 0; tcp < N_TCP_AXI; tcp++) begin : gen_tie_off_tcp
    always_comb begin
        axis_tcp_send[tcp].tie_off_m();
        axis_tcp_recv[tcp].tready = 1'b1;
    end
end
`endif

`ifdef EN_SNIFFER
always_comb begin
    axis_rx_sniffer.tready = 1'b1;
    axis_tx_sniffer.tready = 1'b1;
    filter_config.tie_off_m();
end
`endif
