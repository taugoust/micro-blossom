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

// Check the established divide-by-two behavior at both phases of aclk.
task automatic check_divided_clock(input integer edge_count);
    repeat (edge_count) begin
        @(posedge aclk);
        expected_slow = ~expected_slow;
        #1ps;
        assert(slow_clk == expected_slow)
            else $fatal(1, "clock did not toggle on an aclk rising edge");
        @(negedge aclk);
        #1ps;
        assert(slow_clk == expected_slow)
            else $fatal(1, "clock changed between aclk rising edges");
    end
endtask

// Release must pass through both aclk-domain synchronizer stages before the
// divider can resume.
task automatic release_divider_clear;
    @(negedge aclk);
    aresetn = 1'b1;
    #1ps;
    assert(slow_clk == 1'b0)
        else $fatal(1, "divider resumed without an aclk edge");

    @(posedge aclk);
    #1ps;
    assert(slow_clk == 1'b0)
        else $fatal(1, "divider resumed on the first synchronization edge");

    @(posedge aclk);
    #1ps;
    assert(slow_clk == 1'b0)
        else $fatal(1, "divider resumed before the second synchronization edge completed");
endtask

initial begin
    repeat (3) @(posedge aclk);
    #1ps;
    assert(fast_aresetn == 1'b0 && slow_clk == 1'b0 && slow_aresetn == 1'b0)
        else $fatal(1, "application domain left reset early");

    release_divider_clear();
    check_divided_clock(8);
    assert(fast_aresetn && slow_aresetn)
        else $fatal(1, "local resets did not deassert synchronously");

    // Assert between aclk edges while the divided clock is high. CLR and all
    // local resets must take effect without waiting for either clock.
    @(posedge slow_clk);
    @(negedge aclk);
    #1 aresetn = 1'b0;
    #1ps;
    expected_slow = 1'b0;
    assert(fast_aresetn == 1'b0 && slow_clk == 1'b0 && slow_aresetn == 1'b0)
        else $fatal(1, "local clocks/resets did not clear asynchronously");

    release_divider_clear();
    check_divided_clock(8);
    assert(fast_aresetn && slow_aresetn)
        else $fatal(1, "local resets did not recover after asynchronous assertion");

    $display("MICROBLOSSOM_QSHELL_CLOCK_DIV2_PASS");
    $finish;
end

endmodule
