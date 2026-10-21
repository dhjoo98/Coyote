#!/usr/bin/env bash
# Ryloth direct read ports: simulate drd_reader + axi_rd_decoupler + axi_rd_reg_array against a memory model (xsim).
#   run_sim_drd.sh <generated lynx_pkg.sv of any build, e.g. .../build/<proj>_shell/hdl/lynx_pkg.sv>
# Expected: T1 errors 0, T2 close to 1.000 beats/cycle, T3 0 bursts while decoupled, RESULT: PASS.
set -euo pipefail
PKG=$1; HERE=$(cd "$(dirname "$0")" && pwd); R=$(cd "$HERE/../../.." && pwd); W=$(mktemp -d)
source /tools/Xilinx/Vivado/2023.1/settings64.sh >/dev/null 2>&1
cd "$W"
xvlog -sv -i "$R/hw/hdl/pkg" "$PKG" "$R/hw/hdl/pkg/axi_intf.sv" \
  "$R/hw/hdl/common/drd/drd_reader.sv" "$R/hw/hdl/common/decouplers/axi_rd_decoupler.sv" "$R/hw/hdl/common/regs/axi_rd_reg.sv" \
  "$HERE/tb_drd.sv" > xvlog.log || { grep -E "ERROR" xvlog.log; exit 1; }
xelab tb_drd -s tb_drd_snap -timescale 1ns/1ps > xelab.log || { grep -E "ERROR" xelab.log; exit 1; }
xsim tb_drd_snap -R | grep -E "T[1-5]:|ERROR|RESULT" | head -30
echo "(work dir $W)"
