# The MicroBlossom d3 QShell application uses pure RTL and Xilinx primitives.
# BUFGCE_DIV simulation behavior must match the target architecture; otherwise
# Vivado rejects bitstream generation even though it can rewrite the netlist.
set microblossom_target_part [get_property PART [current_project]]
if {[string match -nocase "xcvh*" $microblossom_target_part]} {
    set microblossom_verilog_defines [get_property verilog_define [current_fileset]]
    lappend microblossom_verilog_defines MICROBLOSSOM_VERSAL_HBM
    set_property verilog_define $microblossom_verilog_defines [current_fileset]
}

set microblossom_timing_xdc \
    [file normalize "[file dirname [info script]]/microblossom_qshell_timing.xdc"]
add_files -norecurse -fileset [get_filesets constrs_1] $microblossom_timing_xdc
set_property USED_IN_SYNTHESIS true [get_files $microblossom_timing_xdc]
set_property USED_IN_IMPLEMENTATION true [get_files $microblossom_timing_xdc]
set_property PROCESSING_ORDER LATE [get_files $microblossom_timing_xdc]
