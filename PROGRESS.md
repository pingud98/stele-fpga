# PROGRESS — STELE FPGA autonomous run

Timestamped per-stage log. Operator-facing.

## 2026-07-03 11:55 — Stage 0: Bootstrap — STARTED

- Environment probe: aarch64, Armbian 26.5.1 (Debian 13 trixie), Linux 6.18.2,
  8 cores, 11 GiB RAM (9.7 GiB available), 165 GB free on /. Comfortably above
  the runbook's minimums; sims may use up to `-j4`.
- No FPGA board attached (as expected — pre-hardware run).

## 2026-07-03 12:05 — Stage 0: Bootstrap — DONE

- `scripts/setup_toolchain.sh` written (idempotent, pinned to OSS CAD Suite
  2026-07-03 linux-arm64, 605 MB download). Verification gate **PASSED**:
  - Yosys 0.66+183, nextpnr-ice40 0.10-82, Verilator 5.051, Icarus 14.0-devel,
    icepack/icetime/vvp present, cocotb 2.1.0.dev0, numpy 2.4.6.
- `env.sh` generated. Repo scaffolded per spec §10 (+ golden/, scripts/, build/).
- git initialised on `main`.
- Next: Stage 1 (golden reference pipeline).

## 2026-07-03 12:35 — Stage 1: Golden reference — DONE

- `golden/pwl.py`: shared PWL spec (softplus/silu/exp, 8 segments each) with a
  single integer evaluator; emits `rtl/pwl_tables.vh` (flat 10-bit lanes).
- `golden/reference_model.py`: numpy-only quantised ternary/int8 SSM forward,
  seeded from 0xC0FFEE. Generated: hyperram_image.bin/.hex (328,704 B),
  trace.npz (8 tokens, per-phase intermediates), csr_config.hex, params.json.
- Initial shift constants killed the signal (all-zero x_proj output, degenerate
  token stream). Re-derived from signal statistics; all stages now live,
  <1% saturation, tokens [1,1,1,1,85,11,70,112,31] — state recurrence visibly
  changes output for identical input tokens. Recorded in ASSUMPTIONS.md.
- Sanity suite `golden/test_reference.py`: **11 passed** (PWL accuracy bounds,
  packing round-trip, determinism, liveness, state-matters, layout checks).
- Next: Stage 2 (behavioural HyperRAM model + DQ I/O loopback, milestone 1).

## 2026-07-03 12:55 — Stage 2: HyperRAM model + DQ I/O (milestone 1) — DONE

- `rtl/hyperbus_dq_io.v`: SB_IO registered bidir (ICE40 build) with a
  behaviourally identical generic path (sim/TT); 1-clk latency each direction.
- `sim/hyperram_model.v`: behavioural HyperBus RAM — CA decode, CSR-style
  configurable latency (param + cfg_extra_latency 2x hook), RWDS latency
  indication + read strobe, DQ tri-state, tCSM(4us) assertion, $readmemh image
  load, register space (ID0=0x0c81, CR0 r/w). Protocol contract documented in
  the header (edge-numbered, big-endian words, linear burst).
- cocotb `test_dq_loopback`: **4/4 PASS** (drive, tri-state, receive,
  OE-turnaround streaming). Verilator lint clean (one benign PROCASSINIT note
  on the sim-only generic path).
- Next: Stage 3 — HyperBus PHY, milestones 2–4.

## 2026-07-03 13:20 — Stage 3: HyperBus PHY (milestones 2–4) — DONE

- `rtl/hyperbus_phy.v`: SDR-degraded master. CK = clk/4 (setup/edge halves,
  data centred on every CK edge), CA gen, RWDS sampled once during CA for
  1x/2x latency, fixed configurable capture offset (cfg_capture, default 2
  clk), tCSM-aware splitting via cfg_max_burst with re-issued CA, zero-latency
  register writes. Verilator -Wall clean.
- Fixed in review before sim: register-write edge budget, wr_ready gating,
  removed broken zero-latency corner (cfg_latency >= 1 documented).
- One TB race found (wr_data advanced at falling edge of the consuming cycle);
  test fixed to advance after the consuming posedge — RTL was correct.
- cocotb `test_phy`: **9/9 PASS** — ID0 read (1x and 2x latency), CR0
  write/readback, single-word memory write->readback (both latencies), 16-word
  burst, 64-word transfer auto-split into 4 transactions (CS# rise counted),
  negative control proving the tCSM checker fires without splitting, golden
  image spot-check through the PHY.
- Next: Stage 4 — datapath primitives (milestone 5).
