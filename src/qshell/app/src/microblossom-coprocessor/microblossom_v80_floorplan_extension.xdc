# The Versal parent link must reserve global-clock and VNOC resources before
# the routed shell is packaged. Verify that the imported shell carries the
# MicroBlossom-compatible contract without changing its pblock here.
set application_pblock [get_pblocks pblock_inst_user_wrapper_0]
set application_ranges [get_property GRID_RANGES $application_pblock]
if {[lsearch -exact $application_ranges {BUFGCE_DIV_X6Y0:BUFGCE_DIV_X6Y3}] < 0} {
    error "V80 shell does not reserve the MicroBlossom divider clock tile"
}
if {[get_property NOC_HIGH_ID_MIN $application_pblock] ne "6" ||
    [get_property NOC_HIGH_ID_MAX $application_pblock] ne "63"} {
    error "V80 shell does not reserve the MicroBlossom VNOC high-ID range"
}
