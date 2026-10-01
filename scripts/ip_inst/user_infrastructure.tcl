# Debug bridge removed: not used in user logic; causes [Chipscope 16-320] in
# Vivado 2023.1+ when dclk has no BUFG inside the PR partition (BUFG resources
# exhausted by HLS high-fanout signals). S_BSCAN_tdo is tied off in the wrapper.
#create_ip -name debug_bridge -vendor xilinx.com -library ip -version 3.0 -module_name debug_bridge_user
#set_property -dict [list CONFIG.C_DEBUG_MODE {1} CONFIG.C_NUM_BS_MASTER {0} CONFIG.C_DESIGN_TYPE {1}] [get_ips debug_bridge_user]
