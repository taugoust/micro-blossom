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

// Release must pass through both fabric synchronizer stages before the divider
// sees deasserted CLR. Versal then takes three falling edges to pass that value
// through the primitive's hard CLR synchronizer.
task automatic release_divider_clear;
    @(negedge aclk);
    aresetn = 1'b1;
    #1ps;
    assert(slow_clk == 1'b0)
        else $fatal(1, "divider resumed without an aclk edge");

    @(posedge aclk);
    #1ps;
    assert(slow_clk == 1'b0)
        else $fatal(1, "divider resumed on the first fabric synchronization edge");

    @(posedge aclk);
    #1ps;
    assert(slow_clk == 1'b0)
        else $fatal(1, "divider resumed before the second fabric synchronization edge completed");

`ifdef MICROBLOSSOM_VERSAL_HBM
    repeat (2) begin
        @(negedge aclk);
        #1ps;
        assert(slow_clk == 1'b0)
            else $fatal(1, "divider resumed while hard CLR release was synchronizing");
        @(posedge aclk);
        #1ps;
        assert(slow_clk == 1'b0)
            else $fatal(1, "divider resumed before three hard CLR release samples");
    end
    @(negedge aclk);
    #1ps;
    assert(slow_clk == 1'b0)
        else $fatal(1, "divider changed on the final hard CLR release sample");
`endif
endtask

// Application resets assert immediately. On V80, the clock continues only for
// the primitive's documented three falling-edge hard CLR synchronization
// interval before stopping at the deterministic low phase.
task automatic assert_application_reset;
    @(posedge slow_clk);
    @(negedge aclk);
    #1 aresetn = 1'b0;
    #1ps;
    assert(fast_aresetn == 1'b0 && slow_aresetn == 1'b0)
        else $fatal(1, "local resets did not assert asynchronously");

`ifdef MICROBLOSSOM_VERSAL_HBM
    expected_slow = 1'b1;
    assert(slow_clk == expected_slow)
        else $fatal(1, "V80 divider CLR bypassed its hard synchronizer");

    repeat (2) begin
        @(posedge aclk);
        expected_slow = ~expected_slow;
        #1ps;
        assert(slow_clk == expected_slow)
            else $fatal(1, "V80 divider changed phase while hard CLR was synchronizing");
        @(negedge aclk);
        #1ps;
        assert(slow_clk == expected_slow)
            else $fatal(1, "V80 divider changed between input-clock rising edges");
    end

    @(posedge aclk);
    expected_slow = ~expected_slow;
    #1ps;
    assert(slow_clk == expected_slow)
        else $fatal(1, "V80 divider stopped before the third hard CLR sample");
    @(negedge aclk);
    #1ps;
    expected_slow = 1'b0;
    assert(slow_clk == expected_slow)
        else $fatal(1, "V80 divider did not stop after the third hard CLR sample");
    @(posedge aclk);
    #1ps;
    assert(slow_clk == 1'b0)
        else $fatal(1, "V80 divider did not remain stopped under hard CLR");
`else
    expected_slow = 1'b0;
    assert(slow_clk == expected_slow)
        else $fatal(1, "U280-compatible divider did not clear asynchronously");
`endif
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

    assert_application_reset();
    release_divider_clear();
    check_divided_clock(8);
    assert(fast_aresetn && slow_aresetn)
        else $fatal(1, "local resets did not recover after asynchronous assertion");

`ifdef MICROBLOSSOM_VERSAL_HBM
    $display("MICROBLOSSOM_QSHELL_CLOCK_DIV2_V80_PASS");
`else
    $display("MICROBLOSSOM_QSHELL_CLOCK_DIV2_U280_PASS");
`endif
    $display("MICROBLOSSOM_QSHELL_CLOCK_DIV2_PASS");
    $finish;
end

endmodule
