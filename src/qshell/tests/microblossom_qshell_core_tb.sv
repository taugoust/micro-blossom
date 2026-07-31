`timescale 1ns / 1ps

module tb_core;
localparam logic [255:0] GRAPH_ID = 256'hc5165387fab584bd0e1cbe32e5e49b89b3979a56146472a94eb26d6c3b8d074b;
localparam logic [31:0] MAGIC = 32'h3151_424d;

logic aclk = 1'b0;
logic slow_clk = 1'b0;
logic aresetn = 1'b0;
logic slow_aresetn = 1'b0;
logic [511:0] s_axis_tdata = '0;
logic [63:0] s_axis_tkeep = '1;
logic [5:0] s_axis_tid = '0;
logic s_axis_tlast = 1'b1;
logic s_axis_tvalid = 1'b0;
logic s_axis_tready;
logic [511:0] m_axis_tdata;
logic [63:0] m_axis_tkeep;
logic [5:0] m_axis_tid;
logic m_axis_tlast;
logic m_axis_tvalid;
logic m_axis_tready = 1'b0;

microblossom_qshell_core #(
    .GRAPH_ID(GRAPH_ID),
    .TIMEOUT_CYCLES(4096)
) dut (.*);

always #2 aclk = ~aclk;
always #4 slow_clk = ~slow_clk;

function automatic logic [511:0] record(
    input logic [7:0] opcode,
    input logic [15:0] flags,
    input logic [31:0] request_id,
    input logic [31:0] record_sequence,
    input logic [63:0] argument0,
    input logic [63:0] argument1
);
    logic [511:0] value;
    begin
        value = '0;
        value[31:0] = MAGIC;
        value[39:32] = 8'd1;
        value[47:40] = opcode;
        value[63:48] = flags;
        value[95:64] = request_id;
        value[127:96] = record_sequence;
        value[383:128] = GRAPH_ID;
        value[447:384] = argument0;
        value[511:448] = argument1;
        record = value;
    end
endfunction

task automatic send_record(input logic [511:0] value, input logic [5:0] tid);
    begin
        @(negedge aclk);
        s_axis_tdata = value;
        s_axis_tid = tid;
        s_axis_tvalid = 1'b1;
        do @(posedge aclk); while (!s_axis_tready);
        @(negedge aclk);
        s_axis_tvalid = 1'b0;
    end
endtask

task automatic check_read_result(
    input logic [31:0] request_id,
    input logic [31:0] record_sequence,
    input logic [63:0] address,
    input logic [5:0] tid,
    output logic [63:0] value
);
    begin
        while (!m_axis_tvalid) @(negedge aclk);
        assert(m_axis_tdata[31:0] == MAGIC && m_axis_tdata[39:32] == 1)
            else $fatal(1, "bad response header");
        assert(m_axis_tdata[47:40] == 8'h83 && m_axis_tdata[63:48] == 16'h0103)
            else $fatal(1, "bad read-result opcode or flags");
        assert(m_axis_tdata[95:64] == request_id && m_axis_tdata[127:96] == record_sequence)
            else $fatal(1, "bad read-result identity");
        assert(m_axis_tdata[383:128] == GRAPH_ID && m_axis_tdata[447:384] == address)
            else $fatal(1, "bad read-result graph or address");
        assert(m_axis_tid == tid && m_axis_tkeep == '1 && m_axis_tlast)
            else $fatal(1, "bad read-result sideband");
        value = m_axis_tdata[511:448];
        @(negedge aclk);
        m_axis_tready = 1'b1;
        @(posedge aclk);
        @(negedge aclk);
        m_axis_tready = 1'b0;
    end
endtask

task automatic check_completion(
    input logic [31:0] request_id,
    input logic [31:0] record_sequence,
    input logic [63:0] operations,
    input logic [5:0] tid
);
    logic [511:0] expected;
    begin
        expected = record(8'h84, 16'h0100, request_id, record_sequence, 0, operations);
        while (!m_axis_tvalid) @(negedge aclk);
        assert(m_axis_tdata == expected) else $fatal(1, "bad completion record");
        assert(m_axis_tid == tid && m_axis_tkeep == '1 && m_axis_tlast)
            else $fatal(1, "bad completion sideband");
        @(negedge aclk);
        m_axis_tready = 1'b1;
        @(posedge aclk);
        @(negedge aclk);
        m_axis_tready = 1'b0;
    end
endtask

initial begin : test
    logic [63:0] hardware_info_0;
    logic [63:0] hardware_info_1;

    repeat (6) @(posedge aclk);
    @(negedge aclk);
    aresetn = 1'b1;
    slow_aresetn = 1'b1;
    repeat (8) @(posedge aclk);

    send_record(record(8'h01, 0, 32'h4d42_4331, 0, 3, 0), 6'h11);
    send_record(record(8'h03, 3, 32'h4d42_4331, 1, 8, 0), 6'h12);
    check_read_result(32'h4d42_4331, 1, 8, 6'h12, hardware_info_0);
    assert(hardware_info_0[31:0] == 32'h2401_23c0)
        else $fatal(1, "unexpected MicroBlossom hardware version");

    // Instruction32::reset() == 0x24 and the context ID occupies bits 47:32.
    send_record(record(8'h02, 3, 32'h4d42_4331, 2, 4096, 64'h24), 6'h13);
    send_record(record(8'h03, 3, 32'h4d42_4331, 3, 16, 0), 6'h14);
    check_read_result(32'h4d42_4331, 3, 16, 6'h14, hardware_info_1);
    assert(hardware_info_1 != 0) else $fatal(1, "empty MicroBlossom hardware capability word");

    send_record(record(8'h04, 0, 32'h4d42_4331, 4, 0, 0), 6'h15);
    check_completion(32'h4d42_4331, 4, 3, 6'h15);

    $display("MICROBLOSSOM_QSHELL_CORE_PASS version=%08x capabilities=%016x", hardware_info_0[31:0], hardware_info_1);
    $finish;
end

endmodule
