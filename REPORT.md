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
| Place & route (nextpnr, UP5K sg48) | `make pnr` @ 3 MHz | **PASS** |
| Timing (icetime) | `make timing` | **PASS** (ceiling 5.64 MHz) |
| Bitstream | `build/stele.bin` (104,090 B) | **BUILT, not programmed** |

Golden reference sanity: 11/11 pytest. Verilator `-Wall` lint: clean.
Reproduce everything: `source env.sh && make all`.

## 2. Resources & timing

FPGA build (`-DCSR_LITE`, icebreaker wrapper, iCE40UP5K-SG48):

| Resource | Used / Avail |
|---|---|
| Logic cells (ICESTORM_LC) | **4096 / 5280 (77%)** |
| Block RAM (EBR) | **0 / 30** |
| DSP (SB_MAC16) | **0 / 8** |
| SB_IO | 22 / 39 |

Zero BRAM and zero DSP are by design (spec §14): the 64-byte working regfile
and CSRs are flops, all multiplies go through **one** shared synthesizable
8×8 multiplier, nonlinearities are 8-segment PWL.

Timing: nextpnr routes at 3 MHz (wrapper: 12 MHz osc ÷ 4; HyperBus CK =
750 kHz). icetime critical path 177.3 ns → **max clean clock ≈ 5.6 MHz**
(critical path runs regfile read mux → shared multiplier → requant). At
3 MHz the tiny config generates ≈ 0.5 tokens/s (4.45 M cycles / 8 tokens) —
bus-bound as intended; throughput was explicitly not a goal of this phase.

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

1. **Confirm the HyperRAM part** (spec §15.1: ISSI IS66WVH8M8 or Infineon
   S27KL0641, 3.3 V, single-ended CK). If timings differ from the generic
   model (latency 6, tCSM 4 µs), adjust `sim/hyperram_model.v` parameters
   and the CSR defaults, re-run `make all`.
2. **Wire HyperRAM to the icebreaker**: DQ on PMOD1A, CK/CS#/RWDS on PMOD1B
   per `fpga/icebreaker.pcf`; short traces, 3.3 V bank, series resistors on
   CK/DQ. Program `build/stele.bin` (`iceprog build/stele.bin`).
3. **Re-run bring-up milestones against real silicon, in order**: ID-register
   read first (uo[7:5] FSM debug pins + a logic analyzer on CK/CS#/DQ), then
   single-word write→read-back — *that* is the true PHY de-risk. The capture
   offset (CSR 19) and latency (CSR 0) remain boot-tunable in CSR_LITE for
   exactly this.

   **Key finding — tCSM vs Fmax gap (read before milestone 3):** tCSM
   (CS# low ≤ 4 µs, a DRAM-refresh constraint) puts a *floor* on the clock:
   even a minimal 1-word access is ~16 CK cycles, so the real part needs
   CK ≥ 4 MHz ⇒ core clk ≥ 16 MHz in the current CK=clk/4 scheme — but the
   datapath ceiling is 5.6 MHz. Consequences:
   - **Milestone 1–2 are unaffected at 3 MHz**: the ID/config registers are
     not DRAM; register-space transactions have no refresh dependency. First
     light and CA/latency/capture characterization can proceed as built.
   - **Milestone 3+ (array access) at 3 MHz violates tCSM** on every
     transaction: expect statistically flaky readback (missed refresh).
     Usable for initial PHY characterization only, not for a green M3.
   - The fix before a trustworthy M3/M4 is timing work to ≥ 16 MHz (pipeline
     the shared-multiplier/requant path and the regfile read muxes — the
     critical path is ~40 LUT levels through state decode + rf mux + mul +
     requant), or a CK=clk/2 PHY variant (≥ 8 MHz clk) at reduced margin.
     This is also a TT flag: the same floor applies to TT silicon, where the
     target clock must comfortably exceed 16 MHz or the PHY scheme must move
     to CK = clk/2.
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
