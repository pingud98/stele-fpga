# STELE FPGA — Pre-Hardware Run Report

Autonomous bring-up on Radxa Dragon Q6A (aarch64), 2026-07-03. Deliverable:
green simulation suite through full token generation + a routed, timed UP5K
bitstream. **No hardware was programmed** (no board attached; per runbook).

## 1. Pass/fail matrix

| Milestone (spec §13) | Test | Result |
|---|---|---|
| 1. SB_IO DQ loopback (sim) | `sim-dq_loopback` (4 tests) | **PASS** |
| 2. Config-register read | `sim-phy::test_m2_*` (3 tests, 1x + 2x latency, CR0 w/r) | **PASS** |
| 3. Single-word write → read-back | `sim-phy::test_m3_*` (2 tests, both latencies) | **PASS** |
| 4. Burst within tCSM + splitting | `sim-phy::test_m4_*` (4 tests incl. negative tCSM control) | **PASS** |
| 5. Datapath primitives | `sim-datapath` (9 tests; PWL exhaustive bit-exact) | **PASS** |
| 6. Single-layer FSM vs golden | `sim-top_layer` (bit-exact, all phase checkpoints) | **PASS** |
| 7. Full per-token generation | `sim-top_full` (8 tokens + final state, bit-exact) | **PASS** |
| Synthesis (yosys) | `make synth` | **PASS** |
| Place & route (nextpnr, UP5K sg48) | `make pnr` @ 12 MHz | **PASS** |
| Timing (icetime) | `make timing` | **PASS** (12.37 MHz > 12 MHz) |
| Bitstream | `build/stele.bin` (104,090 B) | **BUILT, not programmed** |

Golden reference sanity: 11/11 pytest. Verilator `-Wall` lint: clean.
Reproduce everything: `source env.sh && make all`.

## 2. Resources & timing

FPGA build (`-DCSR_LITE`, icebreaker wrapper, iCE40UP5K-SG48):

| Resource | Used / Avail |
|---|---|
| Logic cells (ICESTORM_LC) | **~4000 / 5280 (~75%)** |
| Block RAM (EBR) | **0 / 30** |
| DSP (SB_MAC16) | **0 / 8** |
| SB_IO | 22 / 39 |

Zero BRAM and zero DSP are by design (spec §14): the 64-byte working regfile
and CSRs are flops, all multiplies go through **one** shared synthesizable
8×8 multiplier, nonlinearities are 8-segment PWL.

Timing: nextpnr routes at **12 MHz** (icebreaker oscillator direct, no PLL;
HyperBus CK = 6 MHz via the clk/2 PHY). icetime critical path 80.8 ns →
12.37 MHz. Every transaction is tCSM-safe on the IS66WVH8M8 (max_burst=8 →
~2.9 µs < 4 µs). Full 8-token generation = 3.42 M cycles → **~28 tokens/s**
for the tiny config at 12 MHz — bus-bound as intended.

TT-equivalent estimate: ~4.1k LUT4 + ~1.5k FF with full CSRs ≈ 25–30k gate
equivalents. That is **above the 10–15k-gate sketch and likely toward/above
the top of the 8–12 TT-tile budget** — flagged per spec §14. Main levers
before TT hardening: CSR surface reduction (the CSR_LITE variant is ~15%
smaller), regfile port/mux narrowing, and address-adder sharing.

## 3. Verification summary

- Golden reference: numpy-only quantised ternary/int8 selective-SSM
  (seeded-random weights, seed 0xC0FFEE — **not a trained checkpoint**; the
  `--from-checkpoint` path was skipped as permitted). RTL correctness is
  proven bit-exact regardless of weight quality.
- Full-FSM test: CSR boot stream over uio, start token via host handshake,
  8 tokens autoregressive (embedding → 2×(IN_PROJ, CONV, SCAN_PREP, DT,
  SCAN, GATE, OUT_PROJ, RES_ADD) → LM head argmax) — tokens, final SSM state
  and conv rings all equal `golden/trace.npz` exactly; zero tCSM violations.
- Bugs caught by the flow (all fixed, see PROGRESS.md): Verilog signedness
  traps in requant/clamp logic; registered-vs-combinational enable timing;
  a layer-advance race that fed layer 1 with layer 0's IN_PROJ weights;
  PWL latch inference; a false combinational mul↔PWL cycle.

## 4. Assumptions & deviations (full list: ASSUMPTIONS.md)

- Weights are **seeded-random**, quantised; bit-exact golden trace generated
  locally (runbook §4 override). Fixed-point spec: int8 activations/state,
  round-to-nearest shifts, PWL softplus/exp/SiLU shared table-for-table
  between numpy and RTL.
- HyperBus writes are word-granular (TT cannot drive RWDS masking) →
  byte-pair writebacks; conv ring rows padded to 4 B/channel.
- FPGA bitstream hardwires model shape (`CSR_LITE`); sim/TT builds keep the
  full 32-CSR bank. Toolchain pinned: OSS CAD Suite 2026-07-03 arm64.

## 5. Hardware-readiness / handoff (human steps)

1. ~~Confirm the HyperRAM part~~ **CONFIRMED 2026-07-06: ISSI IS66WVH8M8**
   (3.3 V, x8, single-ended CK; latency 6; tCSM 4 µs). The behavioural model
   and milestone-2 tests now carry its identity (ID0=0x0C83 — derived from
   ISSI documentation; verify at the first real silicon ID read).
2. **Wire HyperRAM to the icebreaker**: DQ on PMOD1A, CK/CS#/RWDS on PMOD1B
   per `fpga/icebreaker.pcf`; short traces, 3.3 V bank, series resistors on
   CK/DQ. Program `build/stele.bin` (`iceprog build/stele.bin`).
3. **Re-run bring-up milestones against real silicon, in order**: ID-register
   read first (uo[7:5] FSM debug pins + a logic analyzer on CK/CS#/DQ), then
   single-word write→read-back — *that* is the true PHY de-risk. The capture
   offset (CSR 19) and latency (CSR 0) remain boot-tunable in CSR_LITE for
   exactly this.

   **tCSM vs Fmax gap — RESOLVED** (decision 2026-07-06: clk/2 PHY +
   pipeline to 12 MHz). The PHY moves one byte per clk (CK = clk/2, 6 MHz),
   the datapath is pipelined to close at 12 MHz (icetime 12.37 MHz), and the
   default max_burst=8 keeps every transaction ≈ 2.9 µs — inside the
   IS66WVH8M8's 4 µs tCSM with margin. All array-access milestones are now
   clock-legal on real silicon as built. Residual electrical caveat: DQ
   transitions half a clk before each CK edge (write eye = ±41 ns at
   12 MHz); the boot-tunable capture offset (CSR 19) absorbs board skew on
   reads.
4. Supply a trained/quantised checkpoint later if functional language output
   is wanted; export it through `golden/reference_model.py`'s layout and
   re-run the suite — the RTL needs no change while dims match.

## 6. Honest risk note

A clean result here validates the **protocol and timing logic** of the PHY
(CA sequencing, sampled-RWDS latency handling, fixed-offset capture, tCSM
bursting) against a behavioural model, and the complete fixed-point compute
path bit-exactly. It does **not** validate the pad-electrical path — real
DQ turnaround, board-level signal integrity, actual device latency behaviour,
or the TT I/O mux and sky130/GF180 pad cells. The genuine PHY-on-hardware
test still requires a wired HyperRAM and a board (handoff step 3), and
milestone 3 passing on real silicon remains the gate before any TT GDS
freeze.
