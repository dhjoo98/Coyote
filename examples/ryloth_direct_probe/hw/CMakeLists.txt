######################################################################################
# Ryloth direct-HBM probe (2026-10-20): shell + one tiny PR app that reads every card stream at once and
# counts beats, to measure the delivered card-memory bandwidth of a shell variant with no Ryloth kernel involved.
#
# Shell knobs are cache variables so one source tree builds the baseline (unified, RAMA) and the direct variant:
#   cmake .. -DN_CARD_AXI=16 -DHBM_SPLIT=1 [-DHBM_DIRECT=1]        (HBM_DIRECT is the new knob, see RYLOTH.md)
######################################################################################
cmake_minimum_required(VERSION 3.5)
set(CYT_DIR ${CMAKE_SOURCE_DIR}/../../../)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)
find_package(CoyoteHW REQUIRED)
project(ryloth_direct_probe_hw)
message("*** Ryloth direct-HBM probe [Hardware]: N_CARD_AXI=${N_CARD_AXI} HBM_SPLIT=${HBM_SPLIT} ***")

set(FDEV_NAME "u55c")
set(N_REGIONS 1)

# host stream kept (the stock vFPGA boundary), card streams = the knob under test
set(EN_STRM 1)
set(N_STRM_AXI 1)
set(EN_MEM 1)
set(N_CARD_AXI 16 CACHE STRING "card streams under test")
set(HBM_SPLIT 1 CACHE STRING "two pseudo-channels per card port (hbm_wide)")

# clocks as the proven 0518 shell
set(ACLK_F 150)
set(HCLK_F 225)
set(EN_UCLK 0)
set(UCLK_F 150)

# keep the app-level PR boundary: shell + partial bitstream for the probe app
set(EN_PR 1)
set(N_CONFIG 1)
set(FPLAN_PATH "${CMAKE_SOURCE_DIR}/probe_fplan_u55c.xdc")
set(BUILD_OPT_SHELL 1)
set(BUILD_OPT_USER 0)

validation_checks_hw()
load_apps(
    VFPGA_C0_0 "src"
)
create_hw()
