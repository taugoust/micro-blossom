if {$argc != 6} {
    puts stderr "usage: check-application-elaboration.tcl BASE_TCL REPORT_DIR EXPECTED_BOARD EXPECTED_PART EXPECTED_BUILD_APP EXPECTED_BUILD_SHELL"
    exit 2
}

set base_tcl [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
set expected_board [lindex $argv 2]
set expected_part [lindex $argv 3]
set expected_build_app [lindex $argv 4]
set expected_build_shell [lindex $argv 5]
set units_tmp [file join $output_dir units.tsv.tmp]
set units_path [file join $output_dir units.tsv]
set completion_tmp [file join $output_dir complete.tmp]
set completion_path [file join $output_dir complete]
set units_handle ""

if {[catch {
    if {![file isfile $base_tcl]} {
        error "Coyote application elaboration base Tcl does not exist: $base_tcl"
    }
    source $base_tcl

    foreach required {project part build_dir cfg} {
        if {![info exists $required]} {
            error "Coyote application elaboration base Tcl lacks required variable: $required"
        }
    }
    foreach key {build_app build_shell fdev n_config n_reg} {
        if {![info exists cfg($key)]} {
            error "Coyote application elaboration base Tcl lacks required cfg($key)"
        }
    }
    if {$cfg(build_app) ne $expected_build_app || $cfg(build_shell) ne $expected_build_shell} {
        error "Coyote application elaboration build mode '$cfg(build_app)/$cfg(build_shell)' does not match '$expected_build_app/$expected_build_shell'"
    }
    if {$cfg(fdev) ne $expected_board} {
        error "Coyote application elaboration board '$cfg(fdev)' does not match '$expected_board'"
    }
    if {$part ne $expected_part} {
        error "Coyote application elaboration part '$part' does not match '$expected_part'"
    }
    if {![string is integer -strict $cfg(n_config)] || $cfg(n_config) < 1 ||
        ![string is integer -strict $cfg(n_reg)] || $cfg(n_reg) < 1} {
        error "Coyote application elaboration requires positive configuration and region counts"
    }

    file mkdir $output_dir
    file delete -force $units_tmp $units_path $completion_tmp $completion_path
    set units_handle [open $units_tmp w]
    puts $units_handle "configuration\tregion\ttop\tpart\tsource_management"

    for {set i 0} {$i < $cfg(n_config)} {incr i} {
        for {set j 0} {$j < $cfg(n_reg)} {incr j} {
            set project_path [file join $build_dir "${project}_config_$i" "user_c${i}_$j" "${project}.xpr"]
            if {![file isfile $project_path]} {
                error "Coyote application project does not exist: $project_path"
            }

            open_project $project_path
            set source_mode [get_property SOURCE_MGMT_MODE [current_project]]
            if {$source_mode ne "All"} {
                error "Coyote application project must use SOURCE_MGMT_MODE=All, got '$source_mode': $project_path"
            }
            set source_fileset [current_fileset]
            set top [get_property TOP $source_fileset]
            if {$top eq ""} {
                error "Coyote application project has no synthesis top: $project_path"
            }

            set parent_block_designs [get_files -quiet -of_objects $source_fileset \
                -filter {FILE_TYPE == "Block Designs"}]
            if {[llength $parent_block_designs] > 0} {
                generate_target synthesis $parent_block_designs
                foreach parent_block_design $parent_block_designs {
                    set parent_run [create_ip_run $parent_block_design]
                    launch_runs -jobs 1 $parent_run
                    wait_on_run $parent_run
                    set parent_run_object [get_runs -quiet $parent_run]
                    set parent_run_status [get_property STATUS $parent_run_object]
                    if {![string match "*Complete!*" $parent_run_status]} {
                        error "Coyote application parent block-design synthesis failed: $parent_block_design ($parent_run_status)"
                    }
                }
            }

            set standalone_ips [get_ips -quiet -exclude_bd_ips]
            if {[llength $standalone_ips] > 0} {
                foreach standalone_ip $standalone_ips {
                    set standalone_ip_file [get_files -quiet [get_property IP_FILE $standalone_ip]]
                    if {[llength $standalone_ip_file] != 1} {
                        error "Coyote application standalone IP does not have exactly one source file: $standalone_ip"
                    }
                    set_property GENERATE_SYNTH_CHECKPOINT false $standalone_ip_file
                }
                generate_target synthesis $standalone_ips
            }
            update_compile_order -fileset $source_fileset
            synth_design -rtl -name "rtl_elaboration_c${i}_$j" -top $top -part $part
            puts $units_handle "$i\t$j\t$top\t$part\t$source_mode"
            flush $units_handle

            close_design
            close_project
        }
    }

    close $units_handle
    set units_handle ""
    file rename -force $units_tmp $units_path
    set completion_handle [open $completion_tmp w]
    puts $completion_handle "coyote-nix.app-elaboration/v1"
    close $completion_handle
    file rename -force $completion_tmp $completion_path
} error_message error_options]} {
    if {$units_handle ne ""} {
        catch {close $units_handle}
    }
    catch {close_design}
    catch {close_project}
    file delete -force $units_tmp $units_path $completion_tmp $completion_path
    puts stderr "Coyote application RTL elaboration failed: $error_message"
    if {[dict exists $error_options -errorinfo]} {
        puts stderr [dict get $error_options -errorinfo]
    }
    exit 1
}

puts "COYOTE_APP_ELABORATION_PASS board=$expected_board part=$expected_part units=[expr {$cfg(n_config) * $cfg(n_reg)}]"
exit 0
