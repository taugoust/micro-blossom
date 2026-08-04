`timescale 1ns / 1ps

// Protocol-v1 MicroBlossom record frontend.
//
// One complete 64-byte record is carried in each AXI-stream beat. The frontend
// serializes those records into single-beat AXI4 MMIO transactions for the
// graph-specific MicroBlossom accelerator. It intentionally permits only one
// MMIO operation at a time so request ordering is unambiguous.
module microblossom_qshell_frontend #(
    parameter int AXIS_ID_W = 6,
    parameter int AXI_ADDR_W = 23,
    parameter int TIMEOUT_CYCLES = 1024,
    // Byte 0 of the SHA-256 occupies bits 7:0, matching the little-endian
    // protocol record representation.
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
    input  logic                  m_axis_tready,

    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [AXI_ADDR_W-1:0] m_axi_awaddr,
    output logic [15:0]           m_axi_awid,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_awlock,
    output logic [3:0]            m_axi_awcache,
    output logic [3:0]            m_axi_awqos,
    output logic [15:0]           m_axi_awuser,
    output logic [2:0]            m_axi_awprot,

    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    output logic [63:0]           m_axi_wdata,
    output logic [7:0]            m_axi_wstrb,
    output logic                  m_axi_wlast,

    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready,
    input  logic [15:0]           m_axi_bid,
    input  logic [1:0]            m_axi_bresp,

    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    output logic [AXI_ADDR_W-1:0] m_axi_araddr,
    output logic [15:0]           m_axi_arid,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    output logic                  m_axi_arlock,
    output logic [3:0]            m_axi_arcache,
    output logic [3:0]            m_axi_arqos,
    output logic [15:0]           m_axi_aruser,
    output logic [2:0]            m_axi_arprot,

    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,
    input  logic [63:0]           m_axi_rdata,
    input  logic [15:0]           m_axi_rid,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast
);

localparam logic [31:0] MAGIC = 32'h3151_424d; // bytes "MBQ1"
localparam logic [7:0] VERSION = 8'h01;

localparam logic [7:0] OP_BEGIN_JOB   = 8'h01;
localparam logic [7:0] OP_MMIO_WRITE  = 8'h02;
localparam logic [7:0] OP_MMIO_READ   = 8'h03;
localparam logic [7:0] OP_END_JOB     = 8'h04;
localparam logic [7:0] OP_READ_RESULT = 8'h83;
localparam logic [7:0] OP_COMPLETION  = 8'h84;
localparam logic [7:0] OP_ERROR       = 8'hff;

localparam logic [15:0] RESPONSE_FLAG = 16'h0100;
localparam logic [15:0] KNOWN_FLAGS   = 16'h0103;
localparam logic [63:0] UNBOUNDED_OPERATIONS = 64'hffff_ffff_ffff_ffff;

localparam logic [63:0] COMPLETION_SUCCESS = 64'd0;
localparam logic [63:0] COMPLETION_TIMEOUT = 64'd2;

localparam logic [63:0] ERROR_MALFORMED_RECORD   = 64'd1;
localparam logic [63:0] ERROR_UNSUPPORTED_VERSION = 64'd2;
localparam logic [63:0] ERROR_GRAPH_MISMATCH     = 64'd3;
localparam logic [63:0] ERROR_INVALID_SEQUENCE   = 64'd4;
localparam logic [63:0] ERROR_INVALID_ADDRESS    = 64'd5;
localparam logic [63:0] ERROR_JOB_STATE          = 64'd6;
localparam logic [63:0] ERROR_ACCELERATOR_FAULT  = 64'd7;

typedef enum logic [3:0] {
    ST_ACCEPT,
    ST_WRITE_SEND,
    ST_WRITE_RESPONSE,
    ST_READ_ADDRESS,
    ST_READ_DATA,
    ST_QUARANTINE
} state_t;

state_t state;
logic job_active;
logic [31:0] active_request_id;
logic [31:0] expected_sequence;
logic [63:0] expected_operations;
logic [63:0] completed_operations;

logic [31:0] operation_sequence;
logic [1:0] operation_width;
logic [2:0] operation_lane;
logic [AXI_ADDR_W-1:0] operation_address;
logic [63:0] operation_write_data;
logic [AXIS_ID_W-1:0] operation_tid;
logic aw_done;
logic w_done;
logic [31:0] timeout_count;

logic response_valid;
logic [511:0] response_data;
logic [AXIS_ID_W-1:0] response_tid;

wire request_fire = s_axis_tvalid && s_axis_tready;
wire response_fire = m_axis_tvalid && m_axis_tready;
wire aw_fire = m_axi_awvalid && m_axi_awready;
wire w_fire = m_axi_wvalid && m_axi_wready;
wire b_fire = m_axi_bvalid && m_axi_bready;
wire ar_fire = m_axi_arvalid && m_axi_arready;
wire r_fire = m_axi_rvalid && m_axi_rready;
wire operation_active =
    state == ST_WRITE_SEND || state == ST_WRITE_RESPONSE ||
    state == ST_READ_ADDRESS || state == ST_READ_DATA;
wire timeout_expired =
    operation_active && TIMEOUT_CYCLES != 0 &&
    timeout_count >= TIMEOUT_CYCLES - 1;

wire [31:0] request_magic = s_axis_tdata[31:0];
wire [7:0] request_version = s_axis_tdata[39:32];
wire [7:0] request_opcode = s_axis_tdata[47:40];
wire [15:0] request_flags = s_axis_tdata[63:48];
wire [31:0] request_id = s_axis_tdata[95:64];
wire [31:0] request_sequence = s_axis_tdata[127:96];
wire [255:0] request_graph_id = s_axis_tdata[383:128];
wire [63:0] request_argument0 = s_axis_tdata[447:384];
wire [63:0] request_argument1 = s_axis_tdata[511:448];
wire [1:0] request_width = request_flags[1:0];
wire [3:0] request_width_bytes = 4'b0001 << request_width;
wire request_address_fits = !(|request_argument0[63:AXI_ADDR_W]);
wire request_address_aligned =
    (request_argument0[2:0] & (request_width_bytes[2:0] - 3'd1)) == 3'd0;
wire operation_limit_reached =
    expected_operations != UNBOUNDED_OPERATIONS &&
    completed_operations >= expected_operations;

function automatic logic [7:0] width_strobe(input logic [1:0] width);
    case (width)
        2'd0: width_strobe = 8'h01;
        2'd1: width_strobe = 8'h03;
        2'd2: width_strobe = 8'h0f;
        default: width_strobe = 8'hff;
    endcase
endfunction

function automatic logic [511:0] make_response(
    input logic [7:0] opcode,
    input logic [15:0] flags,
    input logic [31:0] response_request_id,
    input logic [31:0] response_sequence,
    input logic [63:0] argument0,
    input logic [63:0] argument1
);
    logic [511:0] value;
    begin
        value = '0;
        value[31:0] = MAGIC;
        value[39:32] = VERSION;
        value[47:40] = opcode;
        value[63:48] = flags;
        value[95:64] = response_request_id;
        value[127:96] = response_sequence;
        value[383:128] = GRAPH_ID;
        value[447:384] = argument0;
        value[511:448] = argument1;
        make_response = value;
    end
endfunction

task automatic emit_error(
    input logic [31:0] error_request_id,
    input logic [31:0] error_sequence,
    input logic [63:0] error_code,
    input logic [63:0] detail,
    input logic [AXIS_ID_W-1:0] tid
);
    begin
        response_data <= make_response(
            OP_ERROR,
            RESPONSE_FLAG,
            error_request_id,
            error_sequence,
            error_code,
            detail
        );
        response_tid <= tid;
        response_valid <= 1'b1;
        job_active <= 1'b0;
    end
endtask

always_comb begin
    s_axis_tready = state == ST_ACCEPT && !response_valid;

    m_axis_tdata = response_data;
    m_axis_tkeep = '1;
    m_axis_tid = response_tid;
    m_axis_tlast = 1'b1;
    m_axis_tvalid = response_valid;

    m_axi_awvalid = state == ST_WRITE_SEND && !aw_done;
    m_axi_awaddr = operation_address;
    m_axi_awid = '0;
    m_axi_awlen = 8'd0;
    m_axi_awsize = {1'b0, operation_width};
    m_axi_awburst = 2'b01;
    m_axi_awlock = 1'b0;
    m_axi_awcache = '0;
    m_axi_awqos = '0;
    m_axi_awuser = '0;
    m_axi_awprot = '0;

    m_axi_wvalid = state == ST_WRITE_SEND && !w_done;
    m_axi_wdata = operation_write_data << (operation_lane * 8);
    m_axi_wstrb = width_strobe(operation_width) << operation_lane;
    m_axi_wlast = 1'b1;

    m_axi_bready = state == ST_WRITE_RESPONSE || state == ST_QUARANTINE;

    m_axi_arvalid = state == ST_READ_ADDRESS;
    m_axi_araddr = operation_address;
    m_axi_arid = '0;
    m_axi_arlen = 8'd0;
    m_axi_arsize = {1'b0, operation_width};
    m_axi_arburst = 2'b01;
    m_axi_arlock = 1'b0;
    m_axi_arcache = '0;
    m_axi_arqos = '0;
    m_axi_aruser = '0;
    m_axi_arprot = '0;

    m_axi_rready = state == ST_READ_DATA || state == ST_QUARANTINE;
end

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        state <= ST_ACCEPT;
        job_active <= 1'b0;
        response_valid <= 1'b0;
    end else begin
        if (response_fire) begin
            response_valid <= 1'b0;
        end

        if (timeout_expired) begin
            response_data <= make_response(
                OP_COMPLETION,
                RESPONSE_FLAG,
                active_request_id,
                operation_sequence,
                COMPLETION_TIMEOUT,
                completed_operations
            );
            response_tid <= operation_tid;
            response_valid <= 1'b1;
            job_active <= 1'b0;
            // An AXI transaction may be partly accepted. Quarantine until
            // reset rather than risking reordering a later job around it.
            state <= ST_QUARANTINE;
        end else begin
            if (operation_active) begin
                timeout_count <= timeout_count + 1'b1;
            end else begin
                timeout_count <= '0;
            end

            case (state)
            ST_ACCEPT: begin
                if (request_fire) begin
                    if (s_axis_tkeep != 64'hffff_ffff_ffff_ffff || !s_axis_tlast) begin
                        emit_error(request_id, request_sequence, ERROR_MALFORMED_RECORD, 64'd1, s_axis_tid);
                    end else if (request_magic != MAGIC) begin
                        emit_error(request_id, request_sequence, ERROR_MALFORMED_RECORD, 64'd2, s_axis_tid);
                    end else if (request_version != VERSION) begin
                        emit_error(
                            request_id,
                            request_sequence,
                            ERROR_UNSUPPORTED_VERSION,
                            {56'd0, request_version},
                            s_axis_tid
                        );
                    end else if ((request_flags & ~KNOWN_FLAGS) != 0 || request_flags[8]) begin
                        emit_error(
                            request_id,
                            request_sequence,
                            ERROR_MALFORMED_RECORD,
                            {48'd0, request_flags},
                            s_axis_tid
                        );
                    end else if (request_graph_id != GRAPH_ID) begin
                        emit_error(request_id, request_sequence, ERROR_GRAPH_MISMATCH, 64'd0, s_axis_tid);
                    end else if (request_opcode == OP_BEGIN_JOB) begin
                        if (request_flags != 0 || request_sequence != 0 || job_active) begin
                            emit_error(
                                request_id,
                                request_sequence,
                                job_active ? ERROR_JOB_STATE : ERROR_INVALID_SEQUENCE,
                                job_active ? {56'd0, request_opcode} : 64'd0,
                                s_axis_tid
                            );
                        end else begin
                            job_active <= 1'b1;
                            active_request_id <= request_id;
                            expected_sequence <= 32'd1;
                            expected_operations <= request_argument0;
                            completed_operations <= '0;
                        end
                    end else if (request_opcode == OP_MMIO_WRITE || request_opcode == OP_MMIO_READ) begin
                        if (!job_active || request_id != active_request_id) begin
                            emit_error(
                                request_id,
                                request_sequence,
                                ERROR_JOB_STATE,
                                {56'd0, request_opcode},
                                s_axis_tid
                            );
                        end else if (request_sequence != expected_sequence) begin
                            emit_error(
                                request_id,
                                request_sequence,
                                ERROR_INVALID_SEQUENCE,
                                {32'd0, expected_sequence},
                                s_axis_tid
                            );
                        end else if (operation_limit_reached) begin
                            emit_error(
                                request_id,
                                request_sequence,
                                ERROR_JOB_STATE,
                                completed_operations,
                                s_axis_tid
                            );
                        end else if (!request_address_fits || !request_address_aligned) begin
                            emit_error(
                                request_id,
                                request_sequence,
                                ERROR_INVALID_ADDRESS,
                                request_argument0,
                                s_axis_tid
                            );
                        end else begin
                            operation_sequence <= request_sequence;
                            operation_width <= request_width;
                            operation_lane <= request_argument0[2:0];
                            operation_address <= request_argument0[AXI_ADDR_W-1:0];
                            operation_write_data <= request_argument1;
                            operation_tid <= s_axis_tid;
                            aw_done <= 1'b0;
                            w_done <= 1'b0;
                            timeout_count <= '0;
                            state <= request_opcode == OP_MMIO_WRITE ? ST_WRITE_SEND : ST_READ_ADDRESS;
                        end
                    end else if (request_opcode == OP_END_JOB) begin
                        if (request_flags != 0 || !job_active || request_id != active_request_id) begin
                            emit_error(
                                request_id,
                                request_sequence,
                                ERROR_JOB_STATE,
                                {56'd0, request_opcode},
                                s_axis_tid
                            );
                        end else if (request_sequence != expected_sequence) begin
                            emit_error(
                                request_id,
                                request_sequence,
                                ERROR_INVALID_SEQUENCE,
                                {32'd0, expected_sequence},
                                s_axis_tid
                            );
                        end else if (expected_operations != UNBOUNDED_OPERATIONS &&
                                     completed_operations != expected_operations) begin
                            emit_error(
                                request_id,
                                request_sequence,
                                ERROR_JOB_STATE,
                                completed_operations,
                                s_axis_tid
                            );
                        end else begin
                            response_data <= make_response(
                                OP_COMPLETION,
                                RESPONSE_FLAG,
                                request_id,
                                request_sequence,
                                COMPLETION_SUCCESS,
                                completed_operations
                            );
                            response_tid <= s_axis_tid;
                            response_valid <= 1'b1;
                            job_active <= 1'b0;
                        end
                    end else begin
                        emit_error(
                            request_id,
                            request_sequence,
                            ERROR_MALFORMED_RECORD,
                            {56'd0, request_opcode},
                            s_axis_tid
                        );
                    end
                end
            end

            ST_WRITE_SEND: begin
                if (aw_fire) begin
                    aw_done <= 1'b1;
                end
                if (w_fire) begin
                    w_done <= 1'b1;
                end
                if ((aw_done || aw_fire) && (w_done || w_fire)) begin
                    state <= ST_WRITE_RESPONSE;
                end
            end

            ST_WRITE_RESPONSE: begin
                if (b_fire) begin
                    if (m_axi_bresp != 2'b00 || m_axi_bid != 16'd0) begin
                        emit_error(
                            active_request_id,
                            operation_sequence,
                            ERROR_ACCELERATOR_FAULT,
                            {46'd0, m_axi_bid, m_axi_bresp},
                            operation_tid
                        );
                    end else begin
                        completed_operations <= completed_operations + 1'b1;
                        expected_sequence <= expected_sequence + 1'b1;
                    end
                    state <= ST_ACCEPT;
                end
            end

            ST_READ_ADDRESS: begin
                if (ar_fire) begin
                    state <= ST_READ_DATA;
                end
            end

            ST_READ_DATA: begin
                if (r_fire) begin
                    if (m_axi_rresp != 2'b00 || m_axi_rid != 16'd0 || !m_axi_rlast) begin
                        emit_error(
                            active_request_id,
                            operation_sequence,
                            ERROR_ACCELERATOR_FAULT,
                            {45'd0, !m_axi_rlast, m_axi_rid, m_axi_rresp},
                            operation_tid
                        );
                    end else begin
                        response_data <= make_response(
                            OP_READ_RESULT,
                            RESPONSE_FLAG | {14'd0, operation_width},
                            active_request_id,
                            operation_sequence,
                            {{(64-AXI_ADDR_W){1'b0}}, operation_address},
                            m_axi_rdata >> (operation_lane * 8)
                        );
                        response_tid <= operation_tid;
                        response_valid <= 1'b1;
                        completed_operations <= completed_operations + 1'b1;
                        expected_sequence <= expected_sequence + 1'b1;
                    end
                    state <= ST_ACCEPT;
                end
            end

            ST_QUARANTINE: begin
                // Drain any eventual response, but require reset before a new
                // job because a timed-out AXI transaction cannot be cancelled.
                state <= ST_QUARANTINE;
            end

                default: state <= ST_QUARANTINE;
            endcase
        end
    end
end

`ifndef SYNTHESIS
always_ff @(posedge aclk) begin
    if (aresetn) begin
        assert (!(m_axi_awvalid && state != ST_WRITE_SEND));
        assert (!(m_axi_wvalid && state != ST_WRITE_SEND));
        assert (!(m_axi_arvalid && state != ST_READ_ADDRESS));
    end
end
`endif

endmodule
