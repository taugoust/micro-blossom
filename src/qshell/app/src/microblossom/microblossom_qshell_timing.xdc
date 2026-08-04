# The slow reset synchronizer deliberately asserts asynchronously and releases
# synchronously on slow_clk. Its asynchronous clear pins are therefore CDC
# endpoints, not recovery paths from the Coyote application clock.
#
# Use endpoint constraints rather than a clock-object exception so Vivado
# serializes the exception into the out-of-context user checkpoint and reapplies
# it when that checkpoint is scoped into the routed shell.
set mb_slow_reset_clear_pins [get_pins -quiet -hierarchical -filter {
    NAME =~ */inst_microblossom_qshell_application/inst_clock_divider/slow_reset_sync_reg[*]/CLR
}]

if {[llength $mb_slow_reset_clear_pins] != 2} {
    error "MicroBlossom timing constraint expected two slow reset clear pins, found [llength $mb_slow_reset_clear_pins]"
}

set_false_path -to $mb_slow_reset_clear_pins
