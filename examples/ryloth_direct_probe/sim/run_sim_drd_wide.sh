#!/usr/bin/env bash
# Ryloth scaling step B: simulate the wide direct read chain (drd_reader 1024 @ ACLK -> decoupler -> drd_gearbox ->
# register stages @ HCLK = 2 x ACLK -> memory model) with Vivado xsim and the precompiled XPM library.
#   run_sim_drd_wide.sh <generated lynx_pkg.sv of any build>
# Expected: T1 errors 0, T2/T4 close to 1.000 128-byte beats per ACLK cycle, T3 0 bursts while decoupled, T5 0
# memory-side back-pressure cycles, T6 1 null beat, RESULT: PASS.
set -euo pipefail
PKG=$1; HERE=$(cd "$(dirname "$0")" && pwd); R=$(cd "$HERE/../../.." && pwd); W=$(mktemp -d)
source /tools/Xilinx/Vivado/2023.1/settings64.sh >/dev/null 2>&1
cd "$W"
xvlog -sv -d EN_PR -L xpm -i "$R/hw/hdl/pkg" "$PKG" "$R/hw/hdl/pkg/axi_intf.sv" \
  "$R/hw/hdl/common/drd/drd_reader.sv" "$R/hw/hdl/common/drd/drd_gearbox.sv" "$R/hw/hdl/common/decouplers/axi_rd_decoupler.sv" \
  "$R/hw/hdl/common/regs/axi_rd_reg.sv" "$HERE/tb_drd_wide.sv" > xvlog.log || { grep -E "ERROR" xvlog.log; exit 1; }
xvlog "$XILINX_VIVADO/data/verilog/src/glbl.v" >> xvlog.log
xelab tb_drd_wide glbl -L xpm -s tb_snap -timescale 1ns/1ps > xelab.log || { grep -E "ERROR" xelab.log; exit 1; }
xsim tb_snap -R | grep -aE "T[1-6][ b]?:|ERROR|RESULT" | head -30
echo "(work dir $W)"
