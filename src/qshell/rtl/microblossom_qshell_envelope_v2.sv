`timescale 1ns / 1ps

// QShell ABI-2 envelope adapter for the internal fixed-size MBQ1 stream.
//
// A 64-byte MBQ1 command arrives as 16 payload bytes in the ABI-2 header beat
// followed by a 48-byte continuation. Responses make the inverse conversion.
// The adapter deliberately allows only one MBQ1 command to be outstanding, so
// request metadata remains associated with a delayed or error response without
// duplicating the MBQ1 frontend's job/sequence state.
module microblossom_qshell_envelope_v2 #(
    parameter int AXIS_ID_W = 6
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

    output logic [511:0]          mbq_s_axis_tdata,
    output logic [63:0]           mbq_s_axis_tkeep,
    output logic [AXIS_ID_W-1:0]  mbq_s_axis_tid,
    output logic                  mbq_s_axis_tlast,
    output logic                  mbq_s_axis_tvalid,
    input  logic                  mbq_s_axis_tready,

    input  logic [511:0]          mbq_m_axis_tdata,
    input  logic [63:0]           mbq_m_axis_tkeep,
    input  logic [AXIS_ID_W-1:0]  mbq_m_axis_tid,
    input  logic                  mbq_m_axis_tlast,
    input  logic                  mbq_m_axis_tvalid,
    output logic                  mbq_m_axis_tready
);

`include "qshell_abi_generated.svh"

localparam logic [7:0] MBQ_OP_END_JOB = 8'h04;
localparam logic [7:0] MBQ_OP_COMPLETION = 8'h84;
localparam logic [7:0] MBQ_OP_ERROR = 8'hff;
localparam logic [63:0] CONTINUATION_KEEP = 64'h0000_ffff_ffff_ffff;

typedef enum logic [2:0] {
    ST_FIRST,
    ST_CONTINUATION,
    ST_SUBMIT,
    ST_WAIT_RESULT,
    ST_EMIT_FIRST,
    ST_EMIT_CONTINUATION,
    ST_DISCARD
} state_t;

state_t state;
logic [383:0] request_header;
logic [511:0] request_payload;
logic [AXIS_ID_W-1:0] request_tid;
logic [31:0] correction_sequence;
logic [383:0] response_header;
logic [511:0] response_payload;

wire input_fire = s_axis_tvalid && s_axis_tready;
wire output_fire = m_axis_tvalid && m_axis_tready;
wire mbq_request_fire = mbq_s_axis_tvalid && mbq_s_axis_tready;
wire mbq_response_fire = mbq_m_axis_tvalid && mbq_m_axis_tready;
wire request_end_of_round =
    request_header[QSHELL_V2_FLAGS_LSB +: QSHELL_V2_FLAGS_W] ==
    QSHELL_V2_FLAG_END_OF_ROUND;
wire mbq_response_end_of_round =
    mbq_m_axis_tdata[47:40] == MBQ_OP_COMPLETION ||
    mbq_m_axis_tdata[47:40] == MBQ_OP_ERROR;

function automatic logic first_beat_valid(input logic [511:0] data);
    logic [15:0] flags;
    begin
        flags = data[QSHELL_V2_FLAGS_LSB +: QSHELL_V2_FLAGS_W];
        first_beat_valid =
            data[QSHELL_V2_MAGIC_LSB +: QSHELL_V2_MAGIC_W] == QSHELL_V2_MAGIC &&
            data[QSHELL_V2_ABI_VERSION_LSB +: QSHELL_V2_ABI_VERSION_W] ==
                QSHELL_V2_ABI_VERSION[7:0] &&
            data[QSHELL_V2_RECORD_CLASS_LSB +: QSHELL_V2_RECORD_CLASS_W] ==
                QSHELL_V2_CLASS_SYNDROME &&
            (flags & ~QSHELL_V2_FLAG_END_OF_ROUND) == 0 &&
            data[QSHELL_V2_HEADER_BYTES_LSB +: QSHELL_V2_HEADER_BYTES_W] ==
                QSHELL_V2_HEADER_BYTES[15:0] &&
            data[QSHELL_V2_RESERVED_LSB +: QSHELL_V2_RESERVED_W] == 0 &&
            data[QSHELL_V2_PAYLOAD_BYTES_LSB +: QSHELL_V2_PAYLOAD_BYTES_W] == 32'd64 &&
            data[QSHELL_V2_SCHEMA_ID_LSB +: QSHELL_V2_SCHEMA_ID_W] ==
                QSHELL_V2_SCHEMA_MICROBLOSSOM_COMMAND_V1;
    end
endfunction

function automatic logic [383:0] make_response_header(
    input logic [383:0] header,
    input logic [31:0] response_sequence,
    input logic end_of_round
);
    logic [383:0] value;
    logic [31:0] source_endpoint;
    logic [31:0] destination_endpoint;
    begin
        source_endpoint = header[
            QSHELL_V2_SOURCE_ENDPOINT_ID_LSB +: QSHELL_V2_SOURCE_ENDPOINT_ID_W
        ];
        destination_endpoint = header[
            QSHELL_V2_DESTINATION_ENDPOINT_ID_LSB +: QSHELL_V2_DESTINATION_ENDPOINT_ID_W
        ];
        value = header;
        value[QSHELL_V2_RECORD_CLASS_LSB +: QSHELL_V2_RECORD_CLASS_W] =
            QSHELL_V2_CLASS_CORRECTION;
        value[QSHELL_V2_FLAGS_LSB +: QSHELL_V2_FLAGS_W] =
            end_of_round ? QSHELL_V2_FLAG_END_OF_ROUND : 16'd0;
        value[QSHELL_V2_PAYLOAD_BYTES_LSB +: QSHELL_V2_PAYLOAD_BYTES_W] = 32'd64;
        value[QSHELL_V2_SCHEMA_ID_LSB +: QSHELL_V2_SCHEMA_ID_W] =
            QSHELL_V2_SCHEMA_MICROBLOSSOM_RESPONSE_V1;
        value[QSHELL_V2_SOURCE_ENDPOINT_ID_LSB +: QSHELL_V2_SOURCE_ENDPOINT_ID_W] =
            destination_endpoint;
        value[QSHELL_V2_DESTINATION_ENDPOINT_ID_LSB +: QSHELL_V2_DESTINATION_ENDPOINT_ID_W] =
            source_endpoint;
        value[QSHELL_V2_RECORD_SEQUENCE_LSB +: QSHELL_V2_RECORD_SEQUENCE_W] =
            response_sequence;
        make_response_header = value;
    end
endfunction

always_comb begin
    s_axis_tready = state == ST_FIRST || state == ST_CONTINUATION || state == ST_DISCARD;

    mbq_s_axis_tdata = request_payload;
    mbq_s_axis_tkeep = '1;
    mbq_s_axis_tid = request_tid;
    mbq_s_axis_tlast = 1'b1;
    mbq_s_axis_tvalid = state == ST_SUBMIT;
    mbq_m_axis_tready = state == ST_WAIT_RESULT;

    m_axis_tdata = '0;
    m_axis_tkeep = '0;
    m_axis_tid = request_tid;
    m_axis_tlast = 1'b0;
    m_axis_tvalid = state == ST_EMIT_FIRST || state == ST_EMIT_CONTINUATION;
    if (state == ST_EMIT_FIRST) begin
        m_axis_tdata[383:0] = response_header;
        m_axis_tdata[511:384] = response_payload[127:0];
        m_axis_tkeep = '1;
    end else if (state == ST_EMIT_CONTINUATION) begin
        m_axis_tdata[383:0] = response_payload[511:128];
        m_axis_tkeep = CONTINUATION_KEEP;
        m_axis_tlast = 1'b1;
    end
end

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        state <= ST_FIRST;
        correction_sequence <= '0;
    end else begin
        case (state)
            ST_FIRST: begin
                if (input_fire) begin
                    if (s_axis_tkeep == '1 && !s_axis_tlast && first_beat_valid(s_axis_tdata)) begin
                        request_header <= s_axis_tdata[383:0];
                        request_payload[127:0] <= s_axis_tdata[511:384];
                        request_tid <= s_axis_tid;
                        state <= ST_CONTINUATION;
                    end else begin
                        state <= s_axis_tlast ? ST_FIRST : ST_DISCARD;
                    end
                end
            end

            ST_CONTINUATION: begin
                if (input_fire) begin
                    if (s_axis_tkeep == CONTINUATION_KEEP && s_axis_tlast &&
                        ((request_payload[47:40] == MBQ_OP_END_JOB) == request_end_of_round)) begin
                        request_payload[511:128] <= s_axis_tdata[383:0];
                        state <= ST_SUBMIT;
                    end else begin
                        state <= s_axis_tlast ? ST_FIRST : ST_DISCARD;
                    end
                end
            end

            ST_SUBMIT: begin
                if (mbq_request_fire) begin
                    state <= ST_WAIT_RESULT;
                end
            end

            ST_WAIT_RESULT: begin
                if (mbq_response_fire) begin
                    response_header <= make_response_header(
                        request_header,
                        correction_sequence,
                        mbq_response_end_of_round
                    );
                    response_payload <= mbq_m_axis_tdata;
                    correction_sequence <=
                        mbq_response_end_of_round ? 32'd0 : correction_sequence + 1'b1;
                    state <= ST_EMIT_FIRST;
                end else if (mbq_s_axis_tready) begin
                    // The inner frontend has returned to its accept state
                    // without a response (for example, a successful write).
                    state <= ST_FIRST;
                end
            end

            ST_EMIT_FIRST: begin
                if (output_fire) begin
                    state <= ST_EMIT_CONTINUATION;
                end
            end

            ST_EMIT_CONTINUATION: begin
                if (output_fire) begin
                    state <= ST_FIRST;
                end
            end

            ST_DISCARD: begin
                if (input_fire && s_axis_tlast) begin
                    state <= ST_FIRST;
                end
            end

            default: state <= ST_FIRST;
        endcase
    end
end

`ifndef SYNTHESIS
always_ff @(posedge aclk) begin
    if (aresetn && mbq_response_fire) begin
        assert (mbq_m_axis_tkeep == '1 && mbq_m_axis_tlast)
            else $error("MBQ1 response is not one complete 64-byte record");
        assert (mbq_m_axis_tid == request_tid)
            else $error("MBQ1 response tag does not match the active request");
    end
end
`endif

endmodule
