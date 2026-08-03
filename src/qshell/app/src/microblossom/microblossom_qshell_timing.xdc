# The generated accelerator uses SpinalHDL StreamFifoCC instances for every
# transfer between the Coyote application clock and the divided accelerator
# clock. Their Gray-pointer synchronizers are marked ASYNC_REG in generated RTL,
# and their dual-clock memories must not be timed as synchronous transfers.
#
# Although slow_clk is physically derived from aclk, the FIFO is deliberately
# an asynchronous CDC boundary. Treating the clocks as related incorrectly
# times dual-port RAM and synchronizer paths against adjacent divide-by-two
# edges and produces non-functional recovery/setup violations.
set mb_clock_dividers [get_cells -quiet -hierarchical -filter {
    NAME =~ */inst_microblossom_qshell_application/inst_clock_divider/inst_slow_clock_buffer
}]

if {[llength $mb_clock_dividers] != 1} {
    error "MicroBlossom timing constraint expected exactly one BUFGCE_DIV, found [llength $mb_clock_dividers]"
}

set mb_clock_divider [lindex $mb_clock_dividers 0]
set mb_fast_clock [get_clocks -quiet -of_objects [get_pins "$mb_clock_divider/I"]]
set mb_slow_clock [get_clocks -quiet -of_objects [get_pins "$mb_clock_divider/O"]]

if {[llength $mb_fast_clock] != 1 || [llength $mb_slow_clock] != 1} {
    error "MicroBlossom timing constraint could not resolve the fast and slow clocks"
}

set_clock_groups -name microblossom_accelerator_cdc -asynchronous \
    -group $mb_fast_clock \
    -group $mb_slow_clock
