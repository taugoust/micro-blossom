`timescale 1ns / 1ps

// Application-local divide-by-two clock for the generated MicroBlossom slow
// domain. Hardware uses a dedicated Xilinx global clock buffer rather than a
// fabric-routed toggle. The simulation branch models the same 2:1 ratio without
// requiring vendor primitive libraries.
module microblossom_qshell_clock_div2 (
    input  logic aclk,
    input  logic aresetn,
    output logic fast_aresetn,
    output logic slow_clk,
    output logic slow_aresetn
);

// BUFGCE_DIV CLR asserts asynchronously, but its release must be synchronized
// to the input clock. Keep this reset separate from the accelerator's local
// fast-domain reset because it controls clock generation.
(* ASYNC_REG = "TRUE" *) logic [1:0] divider_reset_sync;
logic divider_clear;

always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        divider_reset_sync <= 2'b00;
    end else begin
        divider_reset_sync <= {divider_reset_sync[0], 1'b1};
    end
end

assign divider_clear = !divider_reset_sync[1];

`ifdef MICROBLOSSOM_SIM_CLOCK_DIVIDER
logic slow_clk_sim;

always_ff @(posedge aclk or posedge divider_clear) begin
    if (divider_clear) begin
        slow_clk_sim <= 1'b0;
    end else begin
        slow_clk_sim <= ~slow_clk_sim;
    end
end

assign slow_clk = slow_clk_sim;
`else
BUFGCE_DIV #(
    .BUFGCE_DIVIDE(2),
`ifdef MICROBLOSSOM_VERSAL_HBM
    .SIM_DEVICE("VERSAL_HBM")
`else
    .SIM_DEVICE("ULTRASCALE")
`endif
) inst_slow_clock_buffer (
    .I(aclk),
    .CE(1'b1),
    .CLR(divider_clear),
    .O(slow_clk)
);
`endif

// Asynchronous assertion prevents either domain from running during parent
// reset; deassertion is synchronized independently in each local domain. The
// local fast reset also prevents Coyote's high-fanout reset net from crossing
// the static/application boundary to every accelerator register.
(* ASYNC_REG = "TRUE" *) logic [1:0] fast_reset_sync;
always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        fast_reset_sync <= 2'b00;
    end else begin
        fast_reset_sync <= {fast_reset_sync[0], 1'b1};
    end
end

(* ASYNC_REG = "TRUE" *) logic [1:0] slow_reset_sync;
always_ff @(posedge slow_clk or negedge aresetn) begin
    if (!aresetn) begin
        slow_reset_sync <= 2'b00;
    end else begin
        slow_reset_sync <= {slow_reset_sync[0], 1'b1};
    end
end

assign fast_aresetn = fast_reset_sync[1];
assign slow_aresetn = slow_reset_sync[1];

endmodule
