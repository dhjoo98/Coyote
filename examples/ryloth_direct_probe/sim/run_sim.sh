#!/usr/bin/env bash
# Ryloth direct-HBM stage 2: simulate tlb_fsm (physical fast path) and req_parser (flag carried) with Vivado xsim.
#   run_sim.sh <generated lynx_pkg.sv of a build with N_CARD_AXI=15, e.g. .../build/<proj>_shell/hdl/lynx_pkg.sv>
# Expected: T1 3.00 cycles per physical 4 KiB request, T5 8.00 cycles per translated request on TLB hits, RESULT: PASS x2.
set -euo pipefail
PKG=$1; HERE=$(cd "$(dirname "$0")" && pwd); R=$(cd "$HERE/../../.." && pwd); W=$(mktemp -d)
source /tools/Xilinx/Vivado/2023.1/settings64.sh >/dev/null 2>&1
cd "$W"
# xelab rejects the 15 identical drivers of ccurr_dest inside a generate loop (Vivado synthesis accepts them):
# simulate a copy with that one assign hoisted out of the loop
python3 - "$R/hw/hdl/mmu/tlb_fsm.sv" <<'PY'
import sys
s=open(sys.argv[1]).read()
old="    // Current card destination\n    assign ccurr_dest = dest_C[N_CARD_AXI_BITS-1:0];\nend\n"
assert s.count(old)==1
open('tlb_fsm_simcopy.sv','w').write(s.replace(old,"end\nassign ccurr_dest = dest_C[N_CARD_AXI_BITS-1:0];\n"))
PY
xvlog -sv -d EN_STRM -d EN_MEM -d MULT_CARD_AXI -i "$R/hw/hdl/pkg" "$PKG" "$R/hw/hdl/pkg/lynx_intf.sv" "$R/hw/hdl/pkg/axi_intf.sv" \
  "$R/hw/hdl/common/queues/fifo.sv" "$R/hw/hdl/common/ram/sp_ram_c.sv" "$R/hw/hdl/common/queues/queue_stream.sv" \
  "$R/hw/hdl/common/queues/queue_meta.sv" "$R/hw/hdl/common/arbiters/meta_arbiter.sv" tlb_fsm_simcopy.sv \
  "$R/hw/hdl/user/req/req_parser.sv" "$HERE/fifo_stub.sv" "$HERE/tb_tlb_fsm.sv" "$HERE/tb_req_parser.sv" > xvlog.log
for t in tb tb_parser; do xelab $t -s ${t}_snap -timescale 1ns/1ps > xelab_$t.log; xsim ${t}_snap -R | grep -E "T[1-5]:|req_parser:|FAIL|RESULT"; done
echo "(work dir $W)"
