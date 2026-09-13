`timescale 1ns / 1ps

// Maps the bounded logical co-processor AXI-Lite aperture onto the sparse,
// graph-specific MicroBlossom AXI4 register map. Only registers required by
// the primal firmware are reachable; all other addresses fail with DECERR.
module microblossom_coprocessor_mmio (
    input logic aclk,
    input logic aresetn,

    input logic [11:0] s_axi_awaddr,
    input logic [2:0] s_axi_awprot,
    input logic s_axi_awvalid,
    output logic s_axi_awready,
    input logic [63:0] s_axi_wdata,
    input logic [7:0] s_axi_wstrb,
    input logic s_axi_wvalid,
    output logic s_axi_wready,
    output logic [1:0] s_axi_bresp,
    output logic s_axi_bvalid,
    input logic s_axi_bready,
    input logic [11:0] s_axi_araddr,
    input logic [2:0] s_axi_arprot,
    input logic s_axi_arvalid,
    output logic s_axi_arready,
    output logic [63:0] s_axi_rdata,
    output logic [1:0] s_axi_rresp,
    output logic s_axi_rvalid,
    input logic s_axi_rready,

    output logic m_axi_awvalid,
    input logic m_axi_awready,
    output logic [22:0] m_axi_awaddr,
    output logic [15:0] m_axi_awid,
    output logic [7:0] m_axi_awlen,
    output logic [2:0] m_axi_awsize,
    output logic [1:0] m_axi_awburst,
    output logic m_axi_awlock,
    output logic [3:0] m_axi_awcache,
    output logic [3:0] m_axi_awqos,
    output logic [15:0] m_axi_awuser,
    output logic [2:0] m_axi_awprot,
    output logic m_axi_wvalid,
    input logic m_axi_wready,
    output logic [63:0] m_axi_wdata,
    output logic [7:0] m_axi_wstrb,
    output logic m_axi_wlast,
    input logic m_axi_bvalid,
    output logic m_axi_bready,
    input logic [15:0] m_axi_bid,
    input logic [1:0] m_axi_bresp,
    output logic m_axi_arvalid,
    input logic m_axi_arready,
    output logic [22:0] m_axi_araddr,
    output logic [15:0] m_axi_arid,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic m_axi_arlock,
    output logic [3:0] m_axi_arcache,
    output logic [3:0] m_axi_arqos,
    output logic [15:0] m_axi_aruser,
    output logic [2:0] m_axi_arprot,
    input logic m_axi_rvalid,
    output logic m_axi_rready,
    input logic [63:0] m_axi_rdata,
    input logic [15:0] m_axi_rid,
    input logic [1:0] m_axi_rresp,
    input logic m_axi_rlast
);

localparam logic [1:0] OKAY = 2'b00;
localparam logic [1:0] DECERR = 2'b11;

typedef enum logic [1:0] {W_COLLECT, W_SEND, W_RESPONSE, W_ERROR} write_state_t;
typedef enum logic [1:0] {R_COLLECT, R_SEND, R_RESPONSE, R_ERROR} read_state_t;
write_state_t write_state;
read_state_t read_state;
logic aw_held;
logic w_held;
logic aw_sent;
logic w_sent;
logic [11:0] held_awaddr;
logic [2:0] held_awprot;
logic [63:0] held_wdata;
logic [7:0] held_wstrb;
logic [22:0] write_address;
logic [22:0] read_address;
logic [2:0] held_arprot;

function automatic logic address_valid(input logic [11:0] address);
    case (address)
        12'h000, 12'h008, 12'h010, 12'h018,
        12'h020, 12'h028, 12'h030: address_valid = 1'b1;
        default: address_valid = 1'b0;
    endcase
endfunction

function automatic logic write_valid(input logic [11:0] address);
    case (address)
        12'h010, 12'h018, 12'h020: write_valid = 1'b1;
        default: write_valid = 1'b0;
    endcase
endfunction

function automatic logic [22:0] translate(input logic [11:0] address);
    case (address)
        12'h000: translate = 23'h000008; // hardware information word 0
        12'h008: translate = 23'h000010; // hardware information word 1
        12'h010: translate = 23'h001000; // instruction/context command
        12'h018: translate = 23'h020000; // clear accumulated growth
        12'h020: translate = 23'h020010; // maximum growth
        12'h028: translate = 23'h020020; // obstacle readout low
        12'h030: translate = 23'h020028; // obstacle readout high
        default: translate = '0;
    endcase
endfunction

always_comb begin
    s_axi_awready = write_state == W_COLLECT && !aw_held;
    s_axi_wready = write_state == W_COLLECT && !w_held;
    s_axi_bvalid = write_state == W_RESPONSE ? m_axi_bvalid : write_state == W_ERROR;
    s_axi_bresp = write_state == W_RESPONSE ? m_axi_bresp :
                  write_state == W_ERROR ? DECERR : OKAY;
    s_axi_arready = read_state == R_COLLECT;
    s_axi_rvalid = read_state == R_RESPONSE ? m_axi_rvalid : read_state == R_ERROR;
    s_axi_rdata = read_state == R_RESPONSE ? m_axi_rdata : '0;
    s_axi_rresp = read_state == R_RESPONSE ? m_axi_rresp :
                  read_state == R_ERROR ? DECERR : OKAY;

    m_axi_awvalid = write_state == W_SEND && !aw_sent;
    m_axi_awaddr = write_address;
    m_axi_awid = '0;
    m_axi_awlen = '0;
    m_axi_awsize = 3'd3;
    m_axi_awburst = 2'b01;
    m_axi_awlock = 1'b0;
    m_axi_awcache = '0;
    m_axi_awqos = '0;
    m_axi_awuser = '0;
    m_axi_awprot = held_awprot;
    m_axi_wvalid = write_state == W_SEND && !w_sent;
    m_axi_wdata = held_wdata;
    m_axi_wstrb = held_wstrb;
    m_axi_wlast = 1'b1;
    m_axi_bready = write_state == W_RESPONSE && s_axi_bready;

    m_axi_arvalid = read_state == R_SEND;
    m_axi_araddr = read_address;
    m_axi_arid = '0;
    m_axi_arlen = '0;
    m_axi_arsize = 3'd3;
    m_axi_arburst = 2'b01;
    m_axi_arlock = 1'b0;
    m_axi_arcache = '0;
    m_axi_arqos = '0;
    m_axi_aruser = '0;
    m_axi_arprot = held_arprot;
    m_axi_rready = read_state == R_RESPONSE && s_axi_rready;
end

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        write_state <= W_COLLECT;
        read_state <= R_COLLECT;
        aw_held <= 1'b0;
        w_held <= 1'b0;
        aw_sent <= 1'b0;
        w_sent <= 1'b0;
        held_awaddr <= '0;
        held_awprot <= '0;
        held_wdata <= '0;
        held_wstrb <= '0;
        write_address <= '0;
        read_address <= '0;
        held_arprot <= '0;
    end else begin
        if (write_state == W_COLLECT) begin
            if (s_axi_awvalid && s_axi_awready) begin
                aw_held <= 1'b1;
                held_awaddr <= s_axi_awaddr;
                held_awprot <= s_axi_awprot;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_held <= 1'b1;
                held_wdata <= s_axi_wdata;
                held_wstrb <= s_axi_wstrb;
            end
            if ((aw_held || (s_axi_awvalid && s_axi_awready)) &&
                (w_held || (s_axi_wvalid && s_axi_wready))) begin
                write_address <= translate(aw_held ? held_awaddr : s_axi_awaddr);
                aw_held <= 1'b0;
                w_held <= 1'b0;
                aw_sent <= 1'b0;
                w_sent <= 1'b0;
                write_state <= write_valid(aw_held ? held_awaddr : s_axi_awaddr)
                               ? W_SEND : W_ERROR;
            end
        end else if (write_state == W_SEND) begin
            if (m_axi_awvalid && m_axi_awready) aw_sent <= 1'b1;
            if (m_axi_wvalid && m_axi_wready) w_sent <= 1'b1;
            if ((aw_sent || (m_axi_awvalid && m_axi_awready)) &&
                (w_sent || (m_axi_wvalid && m_axi_wready)))
                write_state <= W_RESPONSE;
        end else if ((write_state == W_RESPONSE || write_state == W_ERROR) &&
                     s_axi_bvalid && s_axi_bready) begin
            write_state <= W_COLLECT;
        end

        if (read_state == R_COLLECT && s_axi_arvalid && s_axi_arready) begin
            read_address <= translate(s_axi_araddr);
            held_arprot <= s_axi_arprot;
            read_state <= address_valid(s_axi_araddr) ? R_SEND : R_ERROR;
        end else if (read_state == R_SEND && m_axi_arvalid && m_axi_arready) begin
            read_state <= R_RESPONSE;
        end else if ((read_state == R_RESPONSE || read_state == R_ERROR) &&
                     s_axi_rvalid && s_axi_rready) begin
            read_state <= R_COLLECT;
        end
    end
end

`ifndef SYNTHESIS
assert property (@(posedge aclk) disable iff (!aresetn)
    m_axi_awvalid && !m_axi_awready |=> m_axi_awvalid && $stable(m_axi_awaddr));
assert property (@(posedge aclk) disable iff (!aresetn)
    m_axi_wvalid && !m_axi_wready |=> m_axi_wvalid && $stable({m_axi_wdata, m_axi_wstrb}));
assert property (@(posedge aclk) disable iff (!aresetn)
    m_axi_arvalid && !m_axi_arready |=> m_axi_arvalid && $stable(m_axi_araddr));
`endif

endmodule
