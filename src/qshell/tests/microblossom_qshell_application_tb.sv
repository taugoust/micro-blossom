`timescale 1ns / 1ps

module tb_application;

`include "qshell_abi_generated.svh"

localparam logic [255:0] GRAPH_ID =
    256'hc5165387fab584bd0e1cbe32e5e49b89b3979a56146472a94eb26d6c3b8d074b;
localparam logic [31:0] SOURCE_ENDPOINT = 32'h12;
localparam logic [31:0] DECODER_ENDPOINT = 32'h101;

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
logic m_axis_tready = 1'b1;

microblossom_qshell_application #(
    .GRAPH_ID(GRAPH_ID),
    .TIMEOUT_CYCLES(4096)
) dut (.*);

always #2 aclk = ~aclk;

function automatic logic [383:0] qshell_header(
    input logic [15:0] flags,
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
        value[QSHELL_CONTEXT_ID_LSB +: QSHELL_CONTEXT_ID_W] = 32'd7;
        value[QSHELL_ROUND_ID_LSB +: QSHELL_ROUND_ID_W] = 32'd42;
        value[QSHELL_SCHEMA_ID_LSB +: QSHELL_SCHEMA_ID_W] =
            QSHELL_SCHEMA_MICROBLOSSOM_COMMAND;
        value[QSHELL_SOURCE_ENDPOINT_ID_LSB +: QSHELL_SOURCE_ENDPOINT_ID_W] =
            SOURCE_ENDPOINT;
        value[QSHELL_DESTINATION_ENDPOINT_ID_LSB +: QSHELL_DESTINATION_ENDPOINT_ID_W] =
            DECODER_ENDPOINT;
        value[QSHELL_ROUTE_CAPABILITY_ID_LSB +: QSHELL_ROUTE_CAPABILITY_ID_W] =
            32'h8765_4321;
        value[QSHELL_ROUTE_VERSION_LSB +: QSHELL_ROUTE_VERSION_W] = 32'd9;
        value[QSHELL_RECORD_SEQUENCE_LSB +: QSHELL_RECORD_SEQUENCE_W] =
            record_sequence;
        qshell_header = value;
    end
endfunction

function automatic logic [511:0] mbq_record(
    input logic [7:0] opcode,
    input logic [15:0] flags,
    input logic [31:0] record_sequence,
    input logic [63:0] argument0,
    input logic [63:0] argument1
);
    logic [511:0] value;
    begin
        value = '0;
        value[31:0] = 32'h3151_424d;
        value[39:32] = 8'd1;
        value[47:40] = opcode;
        value[63:48] = flags;
        value[95:64] = 32'h4d42_4331;
        value[127:96] = record_sequence;
        value[383:128] = GRAPH_ID;
        value[447:384] = argument0;
        value[511:448] = argument1;
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

task automatic receive_record(
    input logic [31:0] expected_sequence,
    input logic expected_eor,
    input logic [5:0] expected_tid,
    output logic [511:0] payload
);
    logic [127:0] payload_prefix;
    begin
        while (!m_axis_tvalid) @(negedge aclk);
        assert(m_axis_tkeep == '1 && !m_axis_tlast && m_axis_tid == expected_tid)
            else $fatal(1, "bad QShell response first beat");
        assert(m_axis_tdata[QSHELL_RECORD_CLASS_LSB +: QSHELL_RECORD_CLASS_W] ==
               QSHELL_CLASS_CORRECTION)
            else $fatal(1, "response class is not correction");
        assert(m_axis_tdata[QSHELL_SCHEMA_ID_LSB +: QSHELL_SCHEMA_ID_W] ==
               QSHELL_SCHEMA_MICROBLOSSOM_RESPONSE)
            else $fatal(1, "response schema mismatch");
        assert(m_axis_tdata[QSHELL_FLAGS_LSB +: QSHELL_FLAGS_W] ==
               (expected_eor ? QSHELL_FLAG_END_OF_ROUND : 16'd0))
            else $fatal(1, "response EOR mismatch");
        assert(m_axis_tdata[QSHELL_RECORD_SEQUENCE_LSB +: QSHELL_RECORD_SEQUENCE_W] ==
               expected_sequence)
            else $fatal(1, "correction sequence mismatch");
        assert(m_axis_tdata[QSHELL_SOURCE_ENDPOINT_ID_LSB +: QSHELL_SOURCE_ENDPOINT_ID_W] ==
               DECODER_ENDPOINT &&
               m_axis_tdata[QSHELL_DESTINATION_ENDPOINT_ID_LSB +:
                            QSHELL_DESTINATION_ENDPOINT_ID_W] == SOURCE_ENDPOINT)
            else $fatal(1, "response endpoints mismatch");
        payload_prefix = m_axis_tdata[511:384];
        @(posedge aclk);
        @(negedge aclk);

        while (!m_axis_tvalid) @(negedge aclk);
        assert(m_axis_tkeep == 64'h0000_ffff_ffff_ffff && m_axis_tlast &&
               m_axis_tid == expected_tid)
            else $fatal(1, "bad QShell response continuation");
        payload = {m_axis_tdata[383:0], payload_prefix};
        @(posedge aclk);
        @(negedge aclk);
    end
endtask

initial begin : test
    logic [511:0] response;

    repeat (6) @(posedge aclk);
    @(negedge aclk);
    aresetn = 1'b1;
    repeat (12) @(posedge aclk);

    send_record(
        qshell_header(0, 0),
        mbq_record(8'h01, 0, 0, 1, 0),
        6'h11
    );

    send_record(
        qshell_header(0, 1),
        mbq_record(8'h03, 3, 1, 8, 0),
        6'h12
    );
    receive_record(0, 1'b0, 6'h12, response);
    assert(response[47:40] == 8'h83 && response[447:384] == 8)
        else $fatal(1, "bad MBQ1 read response identity");
    assert(response[479:448] == 32'h2401_23c0)
        else $fatal(1, "unexpected MicroBlossom hardware version");

    send_record(
        qshell_header(QSHELL_FLAG_END_OF_ROUND, 2),
        mbq_record(8'h04, 0, 2, 0, 0),
        6'h13
    );
    receive_record(1, 1'b1, 6'h13, response);
    assert(response[47:40] == 8'h84 && response[447:384] == 0 &&
           response[511:448] == 1)
        else $fatal(1, "bad MBQ1 completion response");

    $display("MICROBLOSSOM_QSHELL_APPLICATION_PASS version=%08x", 32'h2401_23c0);
    $finish;
end

endmodule
