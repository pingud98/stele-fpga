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

## 2026-07-03 13:55 — Stage 4: Datapath primitives (milestone 5) — DONE

- `mult_synth.v` (TT path), `mult_dsp.v` (SB_MAC16, USE_DSP only),
  `ternary_mac.v` (18-bit exact acc + requant view), `scan_alu.v` (h-update,
  generic mul-requant, 20-bit y-accumulator), `pwl_nonlin.v` (shared-table
  PWL eval).
- Bug found by test: bare concatenations in signed contexts made `>>>`
  logical and comparisons unsigned (ternary_mac requant, yacc requant, silu
  ymin clamp). Fixed by explicit signed extension wires; noted as a design
  rule in the RTL comments.
- cocotb `test_datapath`: **9/9 PASS** — softplus/silu/exp exhaustive
  bit-exact vs golden/pwl.py, random ternary rows vs rm.tmac, h-update /
  mul-requant / y-acc vs reference formulas incl. worst-case extremes, and a
  full golden-trace scan channel replayed through the primitives.
- Next: Stage 5 — sequencer + single-layer FSM (milestone 6).

## 2026-07-03 15:10 — Stage 5: Sequencer + single-layer FSM (milestone 6) — DONE

- `sequencer.v` (microcoded 8-phase layer program + LM head + embed, PH_READ/
  PH_WRITE subroutine states), `csr.v` (32x16 CSRs + boot stream), `regfile.v`
  (64-byte working regfile, 3R1W), `addr_gen.v`, `tt_um_stele_ssm.v` (TT top,
  spec §5 pin map).
- Design decisions recorded in ASSUMPTIONS.md: HyperBus writes are word-
  granular (no RWDS masking on TT) -> byte-pair writebacks + conv ring rows
  padded to 4 B/channel (golden layout updated + regenerated); TMAC streams
  x per row (regfile stays 64 B); scan channel loop = 2 cycles/state-elem.
- Bugs caught in review/lint before sim: registered datapath enables lagging
  their combinationally-muxed operands (made combinational); PWL latch
  inference; false comb cycle mul<->pwl (dedicated dA multiplier); chunk-count
  width bug.
- cocotb `test_top_layer`: **PASS** — CSR boot stream (N_LAYERS=1, N_TOK=1),
  start-token handshake, one full Mamba block via HyperRAM in 292,541 cycles,
  bit-exact vs golden trace at x1/z/u/dbc/delta/h/y_gate/res/x_out/ring, and
  emitted token == numpy argmax. Zero tCSM violations.
- Synth smoke (yosys, core only): 5365 LUT4, ~1520 FF, 0 BRAM — slightly over
  UP5K's 5280 LUT4; optimization planned in Stage 7 (flagged per rule §2.7).
- Next: Stage 6 — full per-token generation (milestone 7).

## 2026-07-03 16:20 — Stage 6: Full per-token generation (milestone 7) — DONE

- First full-gen run FAILED (tokens diverged from step 2). Root cause: on the
  layer boundary S_PHASE_NEXT strobed layer_next and entered S_DISPATCH in the
  same cycle, so IN_PROJ latched w_row_addr from the *previous* layer's
  wl_base while later phases used the new one — layer 1 ran with layer 0's
  in-proj weights. Invisible to the single-layer test by construction. Fixed
  with a one-cycle S_LADV settle state.
- Also this stage: address path narrowed 32->23 bits (8 MB HyperRAM space)
  after synthesis showed 1567 carry cells from ~50 32-bit adders; core LUT4
  count 5365 -> 4754 (fits UP5K). All suites re-run green after the refactor.
- cocotb `test_top_full`: **PASS** — CSR boot, 8 tokens autoregressive
  (embedding lookup + 2 layers + LM head argmax per token) in 4,348,488
  cycles; tokens, final h (both layers), final conv rings all bit-exact vs
  trace.npz; zero tCSM violations. Suite totals: dq_loopback 4/4, phy 9/9,
  datapath 9/9, top_layer 1/1, top_full 1/1. Verilator lint fully clean.
- Next: Stage 7 — PnR, timing, bitstream.

## 2026-07-03 19:20 — Stage 7: Synthesis, PnR, timing, bitstream — DONE

- First PnR attempt: 6001/5280 LC (113%). Area work (each step re-verified):
  23-bit address path, single shared multiplier (5 mults -> 1), regfile port
  reductions, CSR pruning, and a CSR_LITE FPGA-build variant hardwiring model
  shape (sim/TT keep full CSRs). Details in ASSUMPTIONS.md.
- Final: **4096/5280 LC (77%), 0 EBR/BRAM, 0 DSP** (TT-faithful: synthesizable
  multiplier only, no inferred RAM). nextpnr routes at 3 MHz; **icetime
  ceiling 5.64 MHz**; wrapper divides the 12 MHz oscillator by 4.
- **build/stele.bin produced** (104,090 B). NOT programmed to any board
  (pre-hardware run per runbook §1).
- Full suite re-run as freeze gate after the last RTL touch: see Stage 8.

## 2026-07-03 19:50 — Stage 8: Final report — DONE (RUN COMPLETE)

- Freeze gate: `make sim-all` on the final RTL — **24/24 tests green**
  (dq_loopback 4, phy 9, datapath 9, top_layer 1, top_full 1). Makefile
  pattern-rule bug fixed (.PHONY targets don't match `sim-%`).
- REPORT.md written: pass/fail matrix, resources (4096/5280 LC, 0 EBR,
  0 DSP), icetime ceiling 5.64 MHz, bitstream path, handoff steps, risk note.
- **Key finding documented**: tCSM (4 us) requires core clk >= 16 MHz for
  array accesses vs a 5.64 MHz datapath ceiling — milestones 1-2 on hardware
  are unaffected (register space), milestone 3+ needs pipelining or a
  CK=clk/2 PHY first. This is the highest-value engineering output of the
  run beside the green suite itself.
- Deliverables: green sims through full 8-token generation (bit-exact vs
  golden), routed+timed UP5K design, build/stele.bin — all reproducible via
  `source env.sh && make all`. Stopping per runbook §10; no board programmed.

## 2026-07-04 00:00 — Post-run: system demos + requirements audit — DONE

- `make demo`: three narrated sample-operation runs, logs in demo/logs/:
  phy_ops.log (6 HyperBus ops), tinylm_generation.log, random_model_generation.log.
- **Tiny trained LM**: golden/tiny_lm.py — bigram Markov model, MLE-trained on
  the corpus "fpga works", embedded in the quantised pipeline (one-hot
  embedding, ternary bigram LM head, layers execute fully with W_out=0).
  Full-system sim generated 'fpga worksfpga worksf' from prompt 'f' in
  11,122,100 cycles — bit-exact vs the trained reference, 0 tCSM violations.
- Requirements audit of both source documents: docs/requirements-check.md
  (traceability tables; 6 documented gaps, none blocking). Gaps fixed during
  audit: USE_DSP hook restored in scan_alu (lost in the single-multiplier
  rewrite), scripts/ci.sh added (spec §11 CI gate incl. §14 area flag),
  docs/brief.md added per §10 layout, make golden now regenerates the tiny LM.
- hyperram_model gained a +IMAGE plusarg for per-run image override.

## 2026-07-06 15:10 — §15 confirmations + tCSM/Fmax resolution — DONE

- James confirmed all four §15 decisions (IS66WVH8M8, 2-bit packing, 7-bit
  vocab/VOCAB=128, tiny default dims). Model/tests updated to the part's
  identity (ID0=0x0C83 ISSI, ID1=0x0001 — verify at first silicon ID read).
- James chose the recommended tCSM fix: **clk/2 PHY + pipeline to 12 MHz**.
  - PHY rewritten: one byte per clk, CK=clk/2 via the design's only negedge
    register (data centred on every CK edge); CK never pauses; first write
    byte overlaps the last CA/latency cycle. PHY suite 9/9 on first run
    after review.
  - Datapath pipelined in three steps, each measured with nextpnr:
    5.9 -> 8.5 MHz (registered multiplier product), -> 9.5 MHz (fixed-shift
    requants, q8 stage, dead PWL cone removed), -> **12.9 MHz routed /
    12.37 MHz icetime** (registered PWL input). State space widened to
    7 bits (caught an encoding overflow at 64 states before it shipped).
  - Defaults now CAPTURE=1, MAX_BURST=8 (~2.9 us/transaction at CK 6 MHz,
    tCSM-safe on IS66WVH8M8). icebreaker runs at the 12 MHz osc directly.
- Freeze gate: **24/24 tests green**; full 8-token generation bit-exact in
  3,423,016 cycles (was 4,448,840) -> ~28 tokens/s at 12 MHz.
- build/stele.bin rebuilt at 12 MHz. Demo logs regenerated.
