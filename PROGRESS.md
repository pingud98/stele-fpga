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
