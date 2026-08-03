# The MicroBlossom d3 QShell application uses pure RTL and Xilinx primitives.

set microblossom_timing_xdc \
    [file normalize "[file dirname [info script]]/microblossom_qshell_timing.xdc"]
add_files -norecurse -fileset [get_filesets constrs_1] $microblossom_timing_xdc
set_property USED_IN_SYNTHESIS true [get_files $microblossom_timing_xdc]
set_property USED_IN_IMPLEMENTATION true [get_files $microblossom_timing_xdc]
set_property PROCESSING_ORDER LATE [get_files $microblossom_timing_xdc]
