`timescale 1ns / 1ps

// Application-local divide-by-two clock for the generated MicroBlossom slow
// domain. Hardware uses a dedicated Xilinx global clock buffer rather than a
// fabric-routed toggle. The simulation branch models the same 2:1 ratio without
// requiring vendor primitive libraries.
module microblossom_qshell_clock_div2 (
    input  logic aclk,
    input  logic aresetn,
    output logic slow_clk,
    output logic slow_aresetn
);

`ifdef MICROBLOSSOM_SIM_CLOCK_DIVIDER
logic slow_clk_sim;

always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        slow_clk_sim <= 1'b0;
    end else begin
        slow_clk_sim <= ~slow_clk_sim;
    end
end

assign slow_clk = slow_clk_sim;
`else
BUFGCE_DIV #(
    .BUFGCE_DIVIDE(2)
) inst_slow_clock_buffer (
    .I(aclk),
    .CE(1'b1),
    .CLR(!aresetn),
    .O(slow_clk)
);
`endif

// Asynchronous assertion prevents either domain from running during parent
// reset; deassertion is synchronized to the generated slow clock.
logic [1:0] slow_reset_sync;
always_ff @(posedge slow_clk or negedge aresetn) begin
    if (!aresetn) begin
        slow_reset_sync <= 2'b00;
    end else begin
        slow_reset_sync <= {slow_reset_sync[0], 1'b1};
    end
end

assign slow_aresetn = slow_reset_sync[1];

endmodule
