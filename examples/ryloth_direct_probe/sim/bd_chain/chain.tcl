# Ryloth B16 (10/26): block-design test of Coyote's memory path into a shared HBM port, the integration the drd16w board
# run broke on. path_0 = Coyote's own path cell (slice, converter ACLK -> 225, RAMA), then the drd16w chain: clock converter
# 225 -> 300 (cc_sh), drd_share, register slice, M_AXI to the testbench's HBM-like memory. MODE prop = cc_sh ID width left
# to propagation, MODE bug = ID width 1 (as drd16w attempt 3 generated it), MODE fix = ID width 6 (attempt 4).
# Run through run_bd_chain.sh: argv = mode, work dir, Coyote repo root. procs.tcl in the work dir is create_hier_cell_path
# taken from hw/bd/cr_hbm_split.tcl at run time, so the test always uses the shell's current path cell.
set MODE [lindex $argv 0]
set W [lindex $argv 1]
set C [lindex $argv 2]
set D $W/prj_$MODE
create_project chain $D -part xcu55c-fsvh2892-2L-e -force
add_files $C/hw/hdl/shell/drd_share.v
update_compile_order -fileset sources_1
create_bd_design chain
set ::cfg(hbm_direct) 1
source $W/procs.tcl
create_bd_port -dir I -type clk -freq_hz 150000000 aclk
create_bd_port -dir I -type clk -freq_hz 225000000 cclk
create_bd_port -dir I -type clk -freq_hz 300000000 hclk
create_bd_port -dir I -type rst aresetn
create_bd_port -dir I -type rst cresetn
create_bd_port -dir I -type rst hresetn
set S [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI]
set_property -dict [list CONFIG.PROTOCOL AXI4 CONFIG.DATA_WIDTH 256 CONFIG.ADDR_WIDTH 64 CONFIG.ID_WIDTH 1 CONFIG.HAS_BURST 1 CONFIG.HAS_LOCK 0 CONFIG.HAS_CACHE 0 CONFIG.HAS_PROT 0 CONFIG.HAS_QOS 0 CONFIG.HAS_REGION 0 CONFIG.HAS_WSTRB 1 CONFIG.HAS_BRESP 1 CONFIG.HAS_RRESP 1 CONFIG.READ_WRITE_MODE READ_WRITE CONFIG.MAX_BURST_LENGTH 256 CONFIG.SUPPORTS_NARROW_BURST 0 CONFIG.FREQ_HZ 150000000] $S
set Dp [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 D_AXI]
set_property -dict [list CONFIG.PROTOCOL AXI3 CONFIG.DATA_WIDTH 256 CONFIG.ADDR_WIDTH 34 CONFIG.ID_WIDTH 6 CONFIG.HAS_BURST 1 CONFIG.HAS_LOCK 0 CONFIG.HAS_CACHE 0 CONFIG.HAS_PROT 0 CONFIG.HAS_QOS 0 CONFIG.HAS_REGION 0 CONFIG.HAS_WSTRB 1 CONFIG.HAS_BRESP 1 CONFIG.HAS_RRESP 1 CONFIG.READ_WRITE_MODE READ_WRITE CONFIG.MAX_BURST_LENGTH 16 CONFIG.SUPPORTS_NARROW_BURST 0 CONFIG.FREQ_HZ 300000000] $Dp
set M [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI]
set_property -dict [list CONFIG.PROTOCOL AXI3 CONFIG.DATA_WIDTH 256 CONFIG.ADDR_WIDTH 34 CONFIG.ID_WIDTH 6 CONFIG.HAS_BURST 1 CONFIG.HAS_LOCK 0 CONFIG.HAS_CACHE 0 CONFIG.HAS_PROT 0 CONFIG.HAS_QOS 0 CONFIG.HAS_REGION 0 CONFIG.HAS_WSTRB 1 CONFIG.HAS_BRESP 1 CONFIG.HAS_RRESP 1 CONFIG.READ_WRITE_MODE READ_WRITE CONFIG.MAX_BURST_LENGTH 16 CONFIG.SUPPORTS_NARROW_BURST 0 CONFIG.FREQ_HZ 300000000] $M
set_property CONFIG.ASSOCIATED_BUSIF {S_AXI} [get_bd_ports aclk]
set_property CONFIG.ASSOCIATED_RESET {aresetn} [get_bd_ports aclk]
set_property CONFIG.ASSOCIATED_BUSIF {D_AXI:M_AXI} [get_bd_ports hclk]
set_property CONFIG.ASSOCIATED_RESET {hresetn} [get_bd_ports hclk]
create_hier_cell_path [current_bd_instance .] path_0
connect_bd_intf_net [get_bd_intf_ports S_AXI] [get_bd_intf_pins path_0/S_AXI]
connect_bd_net [get_bd_ports aclk] [get_bd_pins path_0/aclk]
connect_bd_net [get_bd_ports aresetn] [get_bd_pins path_0/aresetn]
connect_bd_net [get_bd_ports cclk] [get_bd_pins path_0/hclk]
connect_bd_net [get_bd_ports cresetn] [get_bd_pins path_0/hresetn]
set cc [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 cc_sh ]
if {$MODE eq "fix"} { set_property -dict [ list CONFIG.ID_WIDTH {6} ] $cc }
if {$MODE eq "bug"} { set_property -dict [ list CONFIG.ID_WIDTH {1} ] $cc }   ;# as generated in drd16w attempt 3 (C_AXI_ID_WIDTH 1)
connect_bd_intf_net -boundary_type upper [get_bd_intf_pins path_0/M_AXI] [get_bd_intf_pins cc_sh/S_AXI]
connect_bd_net [get_bd_ports cclk] [get_bd_pins cc_sh/s_axi_aclk]
connect_bd_net [get_bd_ports cresetn] [get_bd_pins cc_sh/s_axi_aresetn]
connect_bd_net [get_bd_ports hclk] [get_bd_pins cc_sh/m_axi_aclk]
connect_bd_net [get_bd_ports hresetn] [get_bd_pins cc_sh/m_axi_aresetn]
create_bd_cell -type module -reference drd_share share
connect_bd_net [get_bd_ports hclk] [get_bd_pins share/aclk]
connect_bd_net [get_bd_ports hresetn] [get_bd_pins share/aresetn]
connect_bd_intf_net [get_bd_intf_pins cc_sh/M_AXI] [get_bd_intf_pins share/s_axi_c]
connect_bd_intf_net [get_bd_intf_ports D_AXI] [get_bd_intf_pins share/s_axi_d]
set rs [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 rs_sh ]
set_property -dict [ list CONFIG.REG_AR {1} CONFIG.REG_AW {1} CONFIG.REG_W {1} CONFIG.REG_R {1} CONFIG.REG_B {1} ] $rs
connect_bd_net [get_bd_ports hclk] [get_bd_pins rs_sh/aclk]
connect_bd_net [get_bd_ports hresetn] [get_bd_pins rs_sh/aresetn]
connect_bd_intf_net [get_bd_intf_pins share/m_axi] [get_bd_intf_pins rs_sh/S_AXI]
connect_bd_intf_net [get_bd_intf_pins rs_sh/M_AXI] [get_bd_intf_ports M_AXI]
validate_bd_design
puts "CC_ID_WIDTH [get_property CONFIG.ID_WIDTH [get_bd_cells cc_sh]]"
save_bd_design
make_wrapper -files [get_files chain.bd] -top
add_files -norecurse [glob $D/chain.gen/sources_1/bd/chain/hdl/chain_wrapper.v]
generate_target simulation [get_files chain.bd]
puts "=== CHAIN BD DONE"
