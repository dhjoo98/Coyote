# Coyote, as Ryloth uses it

This fork carries the Coyote-side changes the Ryloth RAG accelerator depends on. The Ryloth design
itself (vFPGA kernels, floorplan, host program) lives in `dhjoo98/ryloth`; only changes to the
framework belong here.

## The proven pairing is split across two branches

The configuration that produced the working May 2026 bitstreams and the measurements in the HPCA
submission was **not a single Coyote version**. This was discovered on 2026-10-01 by diffing the
final driver against every candidate upstream commit, and had never been recorded:

| Part | Branch | Upstream base | Why |
|---|---|---|---|
| HW build flow, floorplan, templates, SW library | `ryloth/base` | `5136a4a6` (2026-02-11) | What every Ryloth bitstream was built against |
| Kernel driver | `ryloth/driver` | `4e2f64da` | The final driver was developed on a much newer v80-branch snapshot |

`4e2f64da` already carried QDMA and 64-bit BAR2, which is why the working driver contains a
`src/platform/pci_qdma.c` that `5136a4a6` has no trace of. The pairing works because the driver and
shell ioctl ABI stayed compatible across that span — not by design.

**Do not merge these two branches** expecting a single coherent tree. They are two bases.

## Using it

```bash
# HW and host SW build against ryloth/base
git checkout ryloth/base
cmake <ryloth>/HW/hw -DCYT_DIR=$(pwd)
cmake <ryloth>/HW/sw -DCYT_DIR=$(pwd)

# the driver is built separately, on the FPGA host
git checkout ryloth/driver
cd driver && make && sudo insmod build/coyote_driver.ko
```

`ryloth/base` also ships `hw/checkpoints/static_routed_locked_u55c_dh.dcp`, the static routed+locked
checkpoint matching the floorplan changes in `3f6434d8`. Every Ryloth PR build uses it.

## What is in each branch

`ryloth/base` — per-stage `BUILD_OPT_SHELL`/`BUILD_OPT_USER`; optional per-config SLR placement hints
read from `<fplan>_slr_hints.xdc`; u55c static floorplan (HBM BLI widened to the full stack, Laguna
range moved, shell pblock softened); user debug bridge removed (it exhausts the BUFG budget that
high-fanout HLS signals already consume); Coyote SW built static for `x86-64-v3`.

`ryloth/driver` — one commit per bug, each carrying its diagnosis. Highlights:

- **`dab84c69` — DMA mask constrained to 40 bits.** The static-layer PR DMA controller only wires 40
  address bits into its PCIe read TLPs, so IOVAs above 40 bits fault during reconfiguration
  (`iova=0x0FFE75A00000` faulted at `0x00FE75A00000`). Upstream `ef500404` later moved to 44 bits,
  which does **not** fix the PR path. This commit is isolated and worth sending upstream.
- **`965c8e6b` — PR bitstream pages mapped at mmap time**, plus removal of a BPSS drain loop that
  cost ~310 ms per reconfiguration. Upstream `3d285d4b` fixes the same root cause differently; it is
  not an ancestor of this base, so the two are independent.
- `c6b9b423`, `6eb56e84`, `82d01a25`, `bd81b365`, `b8ed4275` — HBM chunk pool sizing, TLB entry
  initialization and a spinlock leak, a hashmap use-after-free, a posted-write flush before TLB
  restart, and kernel version guards.

**Open:** `migrate_to_card()` still ignores the return of `wait_event_interruptible()`, so a signal
during HBM offload can leave the card partially loaded. See `82d01a25`.

## Tracking upstream

`upstream` points at `fpgasystems/Coyote` with its push URL set to `no_push`. As of 2026-10-01 our
bases are ~113 commits behind master. Moving onto current upstream means resolving real conflicts:
`hw/templates/user_{clk,wrapper}_tmplt.txt` have moved to `hw/templates/common/`, the AXI striping
engine was rewritten, UltraScale+ moved to a 64-bit BAR, and the u55c static checkpoints changed —
so a new shell build and fresh timing closure are required, not just a merge.
