
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
