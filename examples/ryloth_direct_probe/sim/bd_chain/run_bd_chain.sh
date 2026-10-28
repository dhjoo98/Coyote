#!/usr/bin/env bash
# Ryloth B16 (10/26): block-design simulation of Coyote's memory path into a shared HBM port, the integration the drd16w
# attempt-3 board run hung on (cc_sh generated with a 1-bit AXI ID). Builds chain.bd = Coyote's path cell (slice,
# converter ACLK -> 225 MHz, RAMA; create_hier_cell_path from hw/bd/cr_hbm_split.tcl), cc_sh 225 -> 300, drd_share, register
# slice, and simulates it against tb_chain.sv (Coyote-like writes and reads, a direct-port-like reader, HBM-like memory).
#   run_bd_chain.sh [fix|bug|prop]   (default fix: cc_sh ID_WIDTH 6, as cr_hbm_split.tcl sets it)
# fix: expected P1-P3 and T: lines, errors 0, RESULT: PASS (10/26: 425 writes, 522 Coyote reads, 1,949 direct reads, 94
# switches). bug / prop only build the design and print CC_ID_WIDTH (1, and what propagation gives); the 10/26 hang
# reproduction needed a hand-edited simulation netlist and is not part of this script. Run this after any change to the
# shared chain (cr_hbm_split.tcl under cfg(drd_share), drd_share.v).
set -euo pipefail
MODE=${1:-fix}; HERE=$(cd "$(dirname "$0")" && pwd); R=$(cd "$HERE/../../../.." && pwd); W=$(mktemp -d)
source /tools/Xilinx/Vivado/2023.1/settings64.sh >/dev/null 2>&1
awk '/^proc create_hier_cell_path \{/{f=1} f{print} f && /^}/{exit}' "$R/hw/bd/cr_hbm_split.tcl" > "$W/procs.tcl"
[ -s "$W/procs.tcl" ] || { echo "create_hier_cell_path not found in $R/hw/bd/cr_hbm_split.tcl"; exit 1; }
cd "$W"
vivado -mode batch -nojournal -log bd.log -source "$HERE/chain.tcl" -tclargs "$MODE" "$W" "$R" > bd.out 2>&1 || { grep -E "^ERROR" bd.out; exit 1; }
grep -E "^CC_ID_WIDTH|^ERROR|CRITICAL WARNING" bd.out | head -10
[ "$MODE" = "fix" ] || { echo "(work dir $W)"; exit 0; }
vivado -mode batch -nojournal -log sim.log -source "$HERE/sim.tcl" -tclargs "$MODE" "$W" "$HERE" > sim.out 2>&1 || { grep -E "^ERROR" sim.out; exit 1; }
grep -aE "^P[1-3] |^T:|ERROR:|RESULT" sim.out | head -20
echo "(work dir $W)"
