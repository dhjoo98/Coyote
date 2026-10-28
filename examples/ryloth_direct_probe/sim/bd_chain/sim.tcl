# argv = mode, work dir, this directory (run_bd_chain.sh)
set MODE [lindex $argv 0]
set W [lindex $argv 1]
set HERE [lindex $argv 2]
open_project $W/prj_$MODE/chain.xpr
add_files -fileset sim_1 -norecurse $HERE/tb_chain.sv
set_property top tb_chain [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
puts "=== SIM DONE"
