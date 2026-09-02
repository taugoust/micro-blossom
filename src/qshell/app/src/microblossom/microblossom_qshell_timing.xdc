# The application-local reset synchronizers assert asynchronously and release
# synchronously in their destination clock domains. Their asynchronous control
# pins are CDC endpoints, not recovery paths from the Coyote application reset.
# The wildcard covers both the host-driven and co-processor application wrappers.
# Keep this file to XDC commands only: Vivado managed constraint files reject Tcl
# control-flow commands such as if and foreach.
set mb_local_reset_clear_pins [get_pins -quiet -hierarchical -filter {
    NAME =~ */inst_microblossom*_application/inst_clock_divider/*_reset_sync_reg[*]/CLR
}]
set mb_fifo_reset_control_pins [get_pins -quiet -hierarchical -filter {
    NAME =~ */inst_accelerator/streamFifoCC_*/bufferCC_6/buffers_*_reg/PRE
}]

set_false_path -to $mb_local_reset_clear_pins
set_false_path -to $mb_fifo_reset_control_pins

# StreamFifoCC transfers Gray-coded pointers through two-stage ASYNC_REG
# synchronizers. Constrain source and first-stage destination register cells,
# rather than Q/D pins, so Vivado does not segment the timing paths. The bus-skew
# constraints precede max-delay constraints to retain valid timing endpoints.
set mb_fast_to_slow_gray_sources [get_cells -quiet -hierarchical -filter {
    NAME =~ */inst_accelerator/streamFifoCC_2/pushCC_pushPtrGray_reg[*] ||
    NAME =~ */inst_accelerator/streamFifoCC_3/popCC_ptrToPush_reg[*]
}]
set mb_fast_to_slow_gray_destinations [get_cells -quiet -hierarchical -filter {
    NAME =~ */inst_accelerator/streamFifoCC_2/pushToPopGray_buffercc/buffers_0_reg[*] ||
    NAME =~ */inst_accelerator/streamFifoCC_3/popToPushGray_buffercc/buffers_0_reg[*]
}]
set mb_slow_to_fast_gray_sources [get_cells -quiet -hierarchical -filter {
    NAME =~ */inst_accelerator/streamFifoCC_2/popCC_ptrToPush_reg[*] ||
    NAME =~ */inst_accelerator/streamFifoCC_3/pushCC_pushPtrGray_reg[*]
}]
set mb_slow_to_fast_gray_destinations [get_cells -quiet -hierarchical -filter {
    NAME =~ */inst_accelerator/streamFifoCC_2/popToPushGray_buffercc/buffers_0_reg[*] ||
    NAME =~ */inst_accelerator/streamFifoCC_3/pushToPopGray_buffercc/buffers_0_reg[*]
}]

set_bus_skew 4.000 \
    -from $mb_fast_to_slow_gray_sources \
    -to $mb_fast_to_slow_gray_destinations
set_max_delay -datapath_only 4.000 \
    -from $mb_fast_to_slow_gray_sources \
    -to $mb_fast_to_slow_gray_destinations
set_bus_skew 8.000 \
    -from $mb_slow_to_fast_gray_sources \
    -to $mb_slow_to_fast_gray_destinations
set_max_delay -datapath_only 8.000 \
    -from $mb_slow_to_fast_gray_sources \
    -to $mb_slow_to_fast_gray_destinations
