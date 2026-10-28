#!/usr/bin/env bash
# Ryloth B16 (10/26): stress test of drd_gearbox's read path (4 lockstep XPM sub-FIFOs per half): the memory side offers
# R beats as fast as rready allows, the user side stalls for long random stretches.
#   run_sim_drd_gbx.sh <generated lynx_pkg.sv of a DRD_WIDE build, e.g. <build>/<project>_hw_shell/hdl/lynx_pkg.sv>
# Expected: S1-S3 with errors 0, S2 at 1.000 beats per ACLK cycle, RESULT: PASS.
set -euo pipefail
PKG=$1; HERE=$(cd "$(dirname "$0")" && pwd); R=$(cd "$HERE/../../.." && pwd); W=$(mktemp -d)
source /tools/Xilinx/Vivado/2023.1/settings64.sh >/dev/null 2>&1
cd "$W"
xvlog -sv -d EN_PR -L xpm -i "$R/hw/hdl/pkg" "$PKG" "$R/hw/hdl/pkg/axi_intf.sv" "$R/hw/hdl/common/drd/drd_gearbox.sv" \
  "$HERE/tb_drd_gbx.sv" > xvlog.log || { grep -E "ERROR" xvlog.log; exit 1; }
xvlog "$XILINX_VIVADO/data/verilog/src/glbl.v" >> xvlog.log
xelab tb_gbx glbl -L xpm -s tb_snap -timescale 1ns/1ps > xelab.log || { grep -E "ERROR" xelab.log; exit 1; }
xsim tb_snap -R | grep -aE "^S[1-3]:|ERROR|RESULT" | head -30
echo "(work dir $W)"
