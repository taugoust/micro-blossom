`timescale 1ns / 1ps

module tb_envelope;

`include "qshell_abi_generated.svh"

localparam logic [31:0] CONTEXT_ID = 32'h0000_0007;
localparam logic [31:0] ROUND_ID = 32'h0000_002a;
localparam logic [31:0] SOURCE_ENDPOINT = 32'h0000_0012;
localparam logic [31:0] DECODER_ENDPOINT = 32'h0000_0101;
localparam logic [31:0] CAPABILITY_ID = 32'h8765_4321;
localparam logic [31:0] ROUTE_VERSION = 32'h0000_0009;

logic aclk = 1'b0;
logic aresetn = 1'b0;
logic [511:0] s_axis_tdata = '0;
logic [63:0] s_axis_tkeep = '0;
logic [5:0] s_axis_tid = '0;
logic s_axis_tlast = 1'b0;
logic s_axis_tvalid = 1'b0;
logic s_axis_tready;
logic [511:0] m_axis_tdata;
logic [63:0] m_axis_tkeep;
logic [5:0] m_axis_tid;
logic m_axis_tlast;
logic m_axis_tvalid;
logic m_axis_tready = 1'b0;
logic [511:0] mbq_s_axis_tdata;
logic [63:0] mbq_s_axis_tkeep;
logic [5:0] mbq_s_axis_tid;
logic mbq_s_axis_tlast;
logic mbq_s_axis_tvalid;
logic mbq_s_axis_tready = 1'b0;
logic [511:0] mbq_m_axis_tdata = '0;
logic [63:0] mbq_m_axis_tkeep = '1;
logic [5:0] mbq_m_axis_tid = '0;
logic mbq_m_axis_tlast = 1'b1;
logic mbq_m_axis_tvalid = 1'b0;
logic mbq_m_axis_tready;

microblossom_qshell_envelope dut (.*);

always #2 aclk = ~aclk;

function automatic logic [383:0] header(
    input logic [15:0] flags,
    input logic [31:0] schema,
    input logic [31:0] record_sequence
);
    logic [383:0] value;
    begin
        value = '0;
        value[QSHELL_MAGIC_LSB +: QSHELL_MAGIC_W] = QSHELL_MAGIC;
        value[QSHELL_ABI_VERSION_LSB +: QSHELL_ABI_VERSION_W] =
            QSHELL_ABI_VERSION[7:0];
        value[QSHELL_RECORD_CLASS_LSB +: QSHELL_RECORD_CLASS_W] =
            QSHELL_CLASS_SYNDROME;
        value[QSHELL_FLAGS_LSB +: QSHELL_FLAGS_W] = flags;
        value[QSHELL_HEADER_BYTES_LSB +: QSHELL_HEADER_BYTES_W] =
            QSHELL_HEADER_BYTES[15:0];
        value[QSHELL_PAYLOAD_BYTES_LSB +: QSHELL_PAYLOAD_BYTES_W] = 32'd64;
        value[QSHELL_CONTEXT_ID_LSB +: QSHELL_CONTEXT_ID_W] = CONTEXT_ID;
        value[QSHELL_ROUND_ID_LSB +: QSHELL_ROUND_ID_W] = ROUND_ID;
        value[QSHELL_SCHEMA_ID_LSB +: QSHELL_SCHEMA_ID_W] = schema;
        value[QSHELL_SOURCE_ENDPOINT_ID_LSB +: QSHELL_SOURCE_ENDPOINT_ID_W] =
            SOURCE_ENDPOINT;
        value[QSHELL_DESTINATION_ENDPOINT_ID_LSB +: QSHELL_DESTINATION_ENDPOINT_ID_W] =
            DECODER_ENDPOINT;
        value[QSHELL_ROUTE_CAPABILITY_ID_LSB +: QSHELL_ROUTE_CAPABILITY_ID_W] =
            CAPABILITY_ID;
        value[QSHELL_ROUTE_VERSION_LSB +: QSHELL_ROUTE_VERSION_W] = ROUTE_VERSION;
        value[QSHELL_RECORD_SEQUENCE_LSB +: QSHELL_RECORD_SEQUENCE_W] =
            record_sequence;
        header = value;
    end
endfunction

function automatic logic [511:0] mbq_record(
    input logic [7:0] opcode,
    input logic [31:0] record_sequence,
    input logic [63:0] argument
);
    logic [511:0] value;
    begin
        value = '0;
        value[31:0] = 32'h3151_424d;
        value[39:32] = 8'd1;
        value[47:40] = opcode;
        value[95:64] = 32'h4d42_4331;
        value[127:96] = record_sequence;
        value[383:128] = 256'hc5165387fab584bd0e1cbe32e5e49b89b3979a56146472a94eb26d6c3b8d074b;
        value[511:448] = argument;
        mbq_record = value;
    end
endfunction

task automatic send_beat(
    input logic [511:0] data,
    input logic [63:0] keep,
    input logic last,
    input logic [5:0] tid
);
    begin
        @(negedge aclk);
        s_axis_tdata = data;
        s_axis_tkeep = keep;
        s_axis_tlast = last;
        s_axis_tid = tid;
        s_axis_tvalid = 1'b1;
        do @(posedge aclk); while (!s_axis_tready);
        @(negedge aclk);
        s_axis_tvalid = 1'b0;
    end
endtask

task automatic send_record(
    input logic [383:0] request_header,
    input logic [511:0] payload,
    input logic [5:0] tid
);
    logic [511:0] first;
    logic [511:0] continuation;
    begin
        first = '0;
        continuation = '0;
        first[383:0] = request_header;
        first[511:384] = payload[127:0];
        continuation[383:0] = payload[511:128];
        send_beat(first, '1, 1'b0, tid);
        send_beat(continuation, 64'h0000_ffff_ffff_ffff, 1'b1, tid);
    end
endtask

task automatic accept_mbq(
    input logic [511:0] expected,
    input logic [5:0] tid
);
    begin
        while (!mbq_s_axis_tvalid) @(negedge aclk);
        assert(mbq_s_axis_tdata == expected) else $fatal(1, "MBQ1 payload mismatch");
        assert(mbq_s_axis_tkeep == '1 && mbq_s_axis_tlast && mbq_s_axis_tid == tid)
            else $fatal(1, "MBQ1 sideband mismatch");
        @(negedge aclk);
        mbq_s_axis_tready = 1'b1;
        @(posedge aclk);
        @(negedge aclk);
        mbq_s_axis_tready = 1'b0;
    end
endtask

task automatic finish_without_response;
    begin
        @(negedge aclk);
        mbq_s_axis_tready = 1'b1;
        @(posedge aclk);
        @(negedge aclk);
        mbq_s_axis_tready = 1'b0;
        @(posedge aclk);
        assert(s_axis_tready) else $fatal(1, "adapter did not reopen after response-free command");
    end
endtask

task automatic return_mbq(
    input logic [511:0] payload,
    input logic [5:0] tid
);
    begin
        @(negedge aclk);
        mbq_m_axis_tdata = payload;
        mbq_m_axis_tid = tid;
        mbq_m_axis_tvalid = 1'b1;
        do @(posedge aclk); while (!mbq_m_axis_tready);
        @(negedge aclk);
        mbq_m_axis_tvalid = 1'b0;
    end
endtask

task automatic check_response(
    input logic [511:0] expected_payload,
    input logic [31:0] expected_sequence,
    input logic expected_eor,
    input logic [5:0] tid
);
    logic [511:0] held_data;
    begin
        while (!m_axis_tvalid) @(negedge aclk);
        assert(m_axis_tkeep == '1 && !m_axis_tlast && m_axis_tid == tid)
            else $fatal(1, "bad first response sideband");
        assert(m_axis_tdata[QSHELL_RECORD_CLASS_LSB +: QSHELL_RECORD_CLASS_W] ==
               QSHELL_CLASS_CORRECTION)
            else $fatal(1, "response is not a correction");
        assert(m_axis_tdata[QSHELL_FLAGS_LSB +: QSHELL_FLAGS_W] ==
               (expected_eor ? QSHELL_FLAG_END_OF_ROUND : 16'd0))
            else $fatal(1, "bad response flags");
        assert(m_axis_tdata[QSHELL_PAYLOAD_BYTES_LSB +: QSHELL_PAYLOAD_BYTES_W] == 64)
            else $fatal(1, "bad response payload size");
        assert(m_axis_tdata[QSHELL_SCHEMA_ID_LSB +: QSHELL_SCHEMA_ID_W] ==
               QSHELL_SCHEMA_MICROBLOSSOM_RESPONSE)
            else $fatal(1, "bad response schema");
        assert(m_axis_tdata[QSHELL_SOURCE_ENDPOINT_ID_LSB +: QSHELL_SOURCE_ENDPOINT_ID_W] ==
               DECODER_ENDPOINT &&
               m_axis_tdata[QSHELL_DESTINATION_ENDPOINT_ID_LSB +:
                            QSHELL_DESTINATION_ENDPOINT_ID_W] == SOURCE_ENDPOINT)
            else $fatal(1, "response endpoints were not reversed");
        assert(m_axis_tdata[QSHELL_RECORD_SEQUENCE_LSB +: QSHELL_RECORD_SEQUENCE_W] ==
               expected_sequence)
            else $fatal(1, "bad correction sequence");
        assert(m_axis_tdata[511:384] == expected_payload[127:0])
            else $fatal(1, "bad first response payload fragment");

        held_data = m_axis_tdata;
        repeat (2) begin
            @(posedge aclk);
            assert(m_axis_tvalid && m_axis_tdata == held_data)
                else $fatal(1, "response changed under backpressure");
        end
        @(negedge aclk);
        m_axis_tready = 1'b1;
        @(posedge aclk);
        @(negedge aclk);
        m_axis_tready = 1'b0;

        while (!m_axis_tvalid) @(negedge aclk);
        assert(m_axis_tkeep == 64'h0000_ffff_ffff_ffff && m_axis_tlast && m_axis_tid == tid)
            else $fatal(1, "bad continuation response sideband");
        assert(m_axis_tdata[383:0] == expected_payload[511:128])
            else $fatal(1, "bad continuation response payload");
        @(negedge aclk);
        m_axis_tready = 1'b1;
        @(posedge aclk);
        @(negedge aclk);
        m_axis_tready = 1'b0;
    end
endtask

initial begin : test
    logic [511:0] command;
    logic [511:0] response;
    logic [511:0] malformed_continuation;

    repeat (5) @(posedge aclk);
    @(negedge aclk);
    aresetn = 1'b1;
    repeat (3) @(posedge aclk);

    // Successful writes produce no MBQ1 response; readiness is the completion signal.
    command = mbq_record(8'h02, 0, 64'h1122_3344_5566_7788);
    send_record(header(0, QSHELL_SCHEMA_MICROBLOSSOM_COMMAND, 0), command, 6'h11);
    accept_mbq(command, 6'h11);
    finish_without_response();
    assert(!m_axis_tvalid) else $fatal(1, "write unexpectedly produced an envelope");

    // A read result is wrapped in two beats and begins correction sequence zero.
    command = mbq_record(8'h03, 1, 64'h8);
    send_record(header(0, QSHELL_SCHEMA_MICROBLOSSOM_COMMAND, 1), command, 6'h12);
    accept_mbq(command, 6'h12);
    assert(!s_axis_tready) else $fatal(1, "adapter accepted another command while one was active");
    response = mbq_record(8'h83, 1, 64'h2401_23c0);
    return_mbq(response, 6'h12);
    check_response(response, 0, 1'b0, 6'h12);

    // Completion closes the round and uses the next correction sequence number.
    command = mbq_record(8'h04, 2, 64'd0);
    send_record(
        header(QSHELL_FLAG_END_OF_ROUND,
               QSHELL_SCHEMA_MICROBLOSSOM_COMMAND, 2),
        command,
        6'h13
    );
    accept_mbq(command, 6'h13);
    response = mbq_record(8'h84, 2, 64'd2);
    return_mbq(response, 6'h13);
    check_response(response, 1, 1'b1, 6'h13);

    // A sparse continuation is discarded and never reaches the MBQ1 core.
    command = mbq_record(8'h03, 0, 64'h10);
    malformed_continuation = '0;
    malformed_continuation[383:0] = command[511:128];
    begin
        logic [511:0] first;
        first = '0;
        first[383:0] = header(0, QSHELL_SCHEMA_MICROBLOSSOM_COMMAND, 0);
        first[511:384] = command[127:0];
        send_beat(first, '1, 1'b0, 6'h14);
    end
    send_beat(malformed_continuation, 64'h0000_7fff_ffff_ffff, 1'b1, 6'h14);
    repeat (3) @(posedge aclk);
    assert(!mbq_s_axis_tvalid) else $fatal(1, "malformed record reached MBQ1 core");

    // Recovery after discard starts a new correction sequence after completion.
    send_record(header(0, QSHELL_SCHEMA_MICROBLOSSOM_COMMAND, 0), command, 6'h15);
    accept_mbq(command, 6'h15);
    response = mbq_record(8'h83, 0, 64'hfeed_face);
    return_mbq(response, 6'h15);
    check_response(response, 0, 1'b0, 6'h15);

    // A wrong schema is discarded through tlast and does not poison the next record.
    send_record(header(0, QSHELL_SCHEMA_HELIOS_PHENOM_SYNDROME, 1), command, 6'h16);
    repeat (3) @(posedge aclk);
    assert(!mbq_s_axis_tvalid && s_axis_tready)
        else $fatal(1, "schema rejection did not recover at record boundary");

    $display("MICROBLOSSOM_QSHELL_ENVELOPE_PASS");
    $finish;
end

endmodule
