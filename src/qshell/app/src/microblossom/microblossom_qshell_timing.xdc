# The application-local reset synchronizers assert asynchronously and release
# synchronously in their destination clock domains. Their asynchronous clear
# pins are CDC endpoints, not recovery paths from the Coyote application reset.
# StreamFifoCC also contains one reset synchronizer per transfer direction; its
# two stages intentionally receive asynchronous reset before synchronously
# shifting the inactive value into the destination domain.
#
# Endpoint constraints serialize into Coyote's out-of-context user checkpoint
# and are reapplied when that checkpoint is scoped into the routed shell.
set mb_local_reset_clear_pins [get_pins -quiet -hierarchical -filter {
    NAME =~ */inst_microblossom_qshell_application/inst_clock_divider/*_reset_sync_reg[*]/CLR
}]
set mb_fifo_reset_control_pins [get_pins -quiet -hierarchical -filter {
    NAME =~ */inst_microblossom_qshell_application/inst_core/inst_accelerator/streamFifoCC_*/bufferCC_6/buffers_*_reg/PRE
}]

if {[llength $mb_local_reset_clear_pins] != 4} {
    error "MicroBlossom timing constraint expected four local reset clear pins, found [llength $mb_local_reset_clear_pins]"
}
if {[llength $mb_fifo_reset_control_pins] != 4} {
    error "MicroBlossom timing constraint expected four FIFO reset control pins, found [llength $mb_fifo_reset_control_pins]"
}

set_false_path -to $mb_local_reset_clear_pins
set_false_path -to $mb_fifo_reset_control_pins

# StreamFifoCC transfers Gray-coded pointers through two-stage ASYNC_REG
# synchronizers. Constrain each source-to-first-stage bus by its source period;
# this removes invalid phase-related setup/hold analysis while retaining a
# physical datapath and bus-skew bound for CDC coherence.
set mb_fast_to_slow_gray_sources [get_pins -quiet -hierarchical -filter {
    NAME =~ */inst_accelerator/streamFifoCC_2/pushCC_pushPtrGray_reg[*]/Q ||
    NAME =~ */inst_accelerator/streamFifoCC_3/popCC_ptrToPush_reg[*]/Q
}]
set mb_fast_to_slow_gray_destinations [get_pins -quiet -hierarchical -filter {
    NAME =~ */inst_accelerator/streamFifoCC_2/pushToPopGray_buffercc/buffers_0_reg[*]/D ||
    NAME =~ */inst_accelerator/streamFifoCC_3/popToPushGray_buffercc/buffers_0_reg[*]/D
}]
set mb_slow_to_fast_gray_sources [get_pins -quiet -hierarchical -filter {
    NAME =~ */inst_accelerator/streamFifoCC_2/popCC_ptrToPush_reg[*]/Q ||
    NAME =~ */inst_accelerator/streamFifoCC_3/pushCC_pushPtrGray_reg[*]/Q
}]
set mb_slow_to_fast_gray_destinations [get_pins -quiet -hierarchical -filter {
    NAME =~ */inst_accelerator/streamFifoCC_2/popToPushGray_buffercc/buffers_0_reg[*]/D ||
    NAME =~ */inst_accelerator/streamFifoCC_3/pushToPopGray_buffercc/buffers_0_reg[*]/D
}]

foreach collection [list \
    $mb_fast_to_slow_gray_sources \
    $mb_fast_to_slow_gray_destinations \
    $mb_slow_to_fast_gray_sources \
    $mb_slow_to_fast_gray_destinations] {
    if {[llength $collection] != 6} {
        error "MicroBlossom timing constraint expected six Gray-pointer pins, found [llength $collection]"
    }
}

set_max_delay -datapath_only 4.000 \
    -from $mb_fast_to_slow_gray_sources \
    -to $mb_fast_to_slow_gray_destinations
set_bus_skew 4.000 \
    -from $mb_fast_to_slow_gray_sources \
    -to $mb_fast_to_slow_gray_destinations
set_max_delay -datapath_only 8.000 \
    -from $mb_slow_to_fast_gray_sources \
    -to $mb_slow_to_fast_gray_destinations
set_bus_skew 8.000 \
    -from $mb_slow_to_fast_gray_sources \
    -to $mb_slow_to_fast_gray_destinations
