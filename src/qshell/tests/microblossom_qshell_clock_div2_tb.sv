`timescale 1ns / 1ps

module tb_clock_div2;
logic aclk = 1'b0;
logic aresetn = 1'b0;
logic fast_aresetn;
logic slow_clk;
logic slow_aresetn;
logic expected_slow = 1'b0;

microblossom_qshell_clock_div2 dut (.*);

always #2 aclk = ~aclk;

initial begin
    repeat (3) @(posedge aclk);
    assert(fast_aresetn == 1'b0 && slow_clk == 1'b0 && slow_aresetn == 1'b0)
        else $fatal(1, "application domain left reset early");

    @(negedge aclk);
    aresetn = 1'b1;
    repeat (8) begin
        @(posedge aclk);
        expected_slow = ~expected_slow;
        @(negedge aclk);
        assert(slow_clk == expected_slow)
            else $fatal(1, "clock is not divided by two");
    end
    assert(fast_aresetn && slow_aresetn)
        else $fatal(1, "local resets did not deassert synchronously");

    // Reset assertion is asynchronous to both clocks and clears the divider.
    #1 aresetn = 1'b0;
    #1;
    assert(fast_aresetn == 1'b0 && slow_clk == 1'b0 && slow_aresetn == 1'b0)
        else $fatal(1, "local clocks/resets did not clear asynchronously");

    $display("MICROBLOSSOM_QSHELL_CLOCK_DIV2_PASS");
    $finish;
end

endmodule
