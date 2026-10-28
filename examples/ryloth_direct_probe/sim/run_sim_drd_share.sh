#!/usr/bin/env bash
# Ryloth B16 (10/26): simulate drd_share (the shell's time-multiplexed switch that lets direct port 14/15 share HBM
# windows 0/1 with Coyote's memory paths) with Vivado xsim. No arguments.
# Expected: phases P1-P4 (Coyote only / direct only / both / direct streaming with sparse Coyote), T: summary with 0 errors
# and 0 violations, RESULT: PASS (10/26: 567 switches, 0 violations).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); R=$(cd "$HERE/../../.." && pwd); W=$(mktemp -d)
source /tools/Xilinx/Vivado/2023.1/settings64.sh >/dev/null 2>&1
cd "$W"
xvlog "$R/hw/hdl/shell/drd_share.v" > xvlog.log || { grep -E "ERROR" xvlog.log; exit 1; }
xvlog -sv "$HERE/tb_drd_share.sv" >> xvlog.log || { grep -E "ERROR" xvlog.log; exit 1; }
xelab tb_drd_share -s tb_snap -timescale 1ns/1ps > xelab.log || { grep -E "ERROR" xelab.log; exit 1; }
xsim tb_snap -R | grep -aE "^P[1-4]|^T:|ERROR|VIOLATION|RESULT" | head -40
echo "(work dir $W)"
