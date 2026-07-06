# Requirements traceability — spec (CLAUDE.md) & runbook (stele-fpga-bringup-brief.md)

Audited 2026-07-03 after run completion. Status legend:
**DONE** = implemented and verified · **PARTIAL** = implemented with a
documented limitation · **DEFERRED** = explicitly out of this phase's scope
(with where it's tracked) · **N/A** = condition never arose.

## Spec (CLAUDE.md)

### §2 Scope
| Requirement | Status | Evidence |
|---|---|---|
| Synthesizable RTL, TT-compatible top from the start | DONE | `rtl/tt_um_stele_ssm.v`; yosys/nextpnr flow green |
| Behavioural HyperRAM model | DONE | `sim/hyperram_model.v`; contract doc in header |
| cocotb suite, test-driven, per §13 milestones | DONE | 24/24 across 5 suites; each stage gated |
| Yosys+nextpnr+icestorm targeting UP5K/icebreaker | DONE | `make synth/pnr/timing/bitstream`; 4096/5280 LC |
| PCF + PHY in SDR/slow-clock/sampled-RWDS mode | DONE | `fpga/icebreaker.pcf`; PHY header documents mode |
| Out of scope: ASIC hardening, model training, DDR | DONE | none attempted (training superseded by runbook §4) |

### §3 Target platform & toolchain
| Requirement | Status | Evidence |
|---|---|---|
| UP5K-SG48 icebreaker target | DONE | PnR at `--up5k --package sg48` |
| 3.3 V HyperRAM part confirmed (single-ended CK) | DONE | ISSI IS66WVH8M8 confirmed 2026-07-06; model IDs updated (ID0=0x0C83); single-ended CK confirmed |
| Inferred EBR where possible / explicit SB_IO, PLL | PARTIAL | zero EBR by design (§14 wins over "where possible"); SB_IO explicit in `hyperbus_dq_io.v`; PLL not needed (÷4 divider), icepll path documented |
| cocotb + Icarus; Python golden comparison | DONE | all suites |
| Verilator --lint-only in CI | DONE | `make lint` (-Wall, clean); `scripts/ci.sh` |

### §5 Interface contract
| Requirement | Status | Evidence |
|---|---|---|
| Exact TT port signature | DONE | `tt_um_stele_ssm.v` matches verbatim |
| Pin map (uio DQ/token; uo CK/CS#/out_valid/in_req/busy/fsm_dbg; ui RWDS/host_drive/in_valid/cfg_mode; ui[7:4] spare) | DONE | top + PCF; fsm_dbg on PMOD2 |
| uio sharing rule; uio_oe=0 whenever host_drive=1 | DONE | `drive = !host_drive && ...`; exercised by boot/start handshakes in every top-level test |
| Identical core logic behind boundary on both targets | DONE | wrapper only maps pads (one documented exception: CSR_LITE define for FPGA fit, ASSUMPTIONS.md) |

### §6 HyperBus PHY
| Requirement | Status | Evidence |
|---|---|---|
| SDR only, single-ended CK | DONE | CK=clk/2, byte per CK edge, data centred (negedge CK reg) |
| Slow, parametrizable clock | PARTIAL | board wrapper divides (÷4); CSR 2 CLK_DIV reserved but PHY ratio is fixed clk/4 — runtime divider not implemented |
| Sampled RWDS (CA phase), fixed capture offsets, never strobe-clocked | DONE | `lat2x` sampled at CA edge 4; `cfg_capture` offset; tests m2 both latencies |
| tCSM-aware bursting, re-issued CA | DONE | `cfg_max_burst` splitting; test_m4 split + negative control |
| Configurable read latency (CSR) | DONE | CSR 0, boot-writable incl. CSR_LITE build |
| SB_IO registered bidir DQ isolated + focused testbench | DONE | `hyperbus_dq_io.v` + milestone-1 loopback (4 tests) |
| PHY ops: read/write/read_reg/write_reg | DONE | cmd_reg flag; all four exercised |

### §7 Datapath
| Requirement | Status | Evidence |
|---|---|---|
| Ternary weights, 2 bits/trit, 4/byte | DONE | `pack_trits` ↔ RTL trit decode; round-trip test |
| PACKING parameter hook for 5-trit/byte | PARTIAL | CSR 18 reserved as the hook; only scheme 0 implemented (per §15.2 default) |
| int8 activations/state, wide accumulators, requant on writeback | DONE | 18/20-bit exact accumulators (overflow-free ≡ int32); round-to-nearest shifts |
| Scan path not ternarized (A,B,C,Δ int8+) | DONE | A int8, B/C/Δ int8/uint8 |
| Ternary MAC lane (add/sub/skip), single lane | DONE | `ternary_mac.v`; one lane, serialized |
| Plain-Verilog synthesizable multiplier ships to TT | DONE | `mult_synth.v` — the only multiplier in the netlist (exactly one instance) |
| Optional SB_MAC16 behind USE_DSP, default tests use synthesizable path | DONE | `scan_alu #(.USE_DSP(0))` generate; `mult_dsp.v`; default 0 everywhere |
| PWL nonlinearities (softplus, exp on ≤0 domain, SiLU), tables in parameters | DONE | `pwl_nonlin.v` + generated `pwl_tables.vh` (8 segments; count fixed in eval structure, tables regenerable) |

### §8 Microsequencer & per-token FSM
| Requirement | Status | Evidence |
|---|---|---|
| Microcoded sequencer (control ROM), not hardwired | DONE | ucode dispatch table (phase ROM); reorder = ROM edit |
| Phase sequence IN_PROJ→CONV→SCAN_PREP→SCAN→GATE→OUT_PROJ per layer | DONE | uidx 0..7 (+ DT_PROJ and RES_ADD split out) |
| LM_HEAD → argmax → next token; emit with out_valid; embedding lookup | DONE | milestone 7 + demos |
| On-die regfile holds only operands in flight | DONE | 64-byte regfile + scalar staging; zero model-scale memory |

### §9 Memory map & CSRs
| Requirement | Status | Evidence |
|---|---|---|
| Parametrized layout (base+stride per region) via CSRs at boot | DONE | CSRs 10–15, 20–29; boot stream = `csr_config.hex` |
| Weights in streaming order; state region; scratch region | DONE | golden `build_image` ↔ `addr_gen`/sequencer, bit-exact runs prove match |
| CSR minimum set: latency, dims, bases, packing, clock-divider | PARTIAL | all present; CLK_DIV (CSR 2) reserved/unused (PHY ratio fixed) |
| Boot loader streams CSRs over uio when cfg_mode=1 | DONE | `csr.v`; exercised in every top-level test |

### §10 Module hierarchy & file layout
All listed files exist with the specified roles. Deviations: brief lives at
repo root as `CLAUDE.md` with a copy at `docs/brief.md`; the build Makefile
is at repo root (not `fpga/Makefile`) covering the whole flow.

### §11 Verification strategy
| Requirement | Status | Evidence |
|---|---|---|
| Behavioural model: CA decode, config latency, RWDS, tri-state, tCSM enforcement | DONE | model + negative tCSM test |
| cocotb test-driven, milestone-gated | DONE | PROGRESS.md per-stage gates |
| Golden: packed weights, discretization constants, token-by-token trace; bit-exact full-FSM | DONE | runbook §4 override: self-generated (seeded-random); trace.npz; milestone 7 bit-exact |
| CI: lint + Icarus/cocotb every commit + synthesis smoke | PARTIAL | `scripts/ci.sh` (lint, goldens, fast suites, synth smoke, area flag); no hosted CI runner — repo has no remote |

### §12 Dependencies & assumptions
| Requirement | Status | Evidence |
|---|---|---|
| External PyTorch model | SUPERSEDED | runbook §4; plus `tiny_lm.py` trained (bigram-MLE) demo model |
| HyperRAM part fixed early | DONE | IS66WVH8M8 confirmed 2026-07-06 |
| Single clock domain; document any CDC | DONE | one domain; RWDS sampled through a synchronous register (`rwds_q`), no async capture, no CDC |

### §13 Bring-up milestones
Milestones 1–7: **DONE in simulation** (see REPORT matrix). Hardware
checkpoints: **DEFERRED** — no board attached (runbook §1); handoff in
REPORT §5. "Freeze nothing for TT GDS until M3 on real hardware": respected.

### §14 TT-faithfulness rules
| Rule | Status |
|---|---|
| No DDR, no calibrated I/O delays | DONE |
| Default build uses mult_synth (no DSP) | DONE (0 SB_MAC16 in netlist) |
| No model-scale on-die memory; inferred RAM = red flag | DONE (0 EBR; regfile/CSRs are flops) |
| PWL, not 256-entry ROMs | DONE |
| Single compute lane, serialize | DONE (one MAC lane, one multiplier) |
| Microcoded sequencer retained | DONE |
| ~8–12 TT tiles; flag in CI if trending above | PARTIAL — flagged: ~4.1k LUT + 1.5k FF trends high (REPORT §2); ci.sh carries the area flag |

### §15/§16 Open decisions & first tasks
All four §15 decisions **confirmed by James 2026-07-06** (IS66WVH8M8;
2-bit/trit packing; 7-bit vocab, VOCAB=128; tiny default dims) — matching
the pinned runbook defaults, now recorded as confirmed in ASSUMPTIONS.md.
All §16 first tasks completed in order.

## Runbook (stele-fpga-bringup-brief.md)

| § | Requirement | Status |
|---|---|---|
| 1 | Probe env; size parallelism; no iceprog; pinned versions logged | DONE (PROGRESS/ASSUMPTIONS; iceprog never invoked) |
| 2.1 | Test-first, milestone-gated, red = stop-and-fix | DONE (two red gates fixed: PHY TB race; layer-advance race) |
| 2.2 | Default rather than block; ASSUMPTIONS.md | DONE (no hard-stops needed) |
| 2.3 | Commit per green milestone, resumable | DONE (stage-named commits) |
| 2.4 | PROGRESS.md timestamped per stage | DONE |
| 2.5 | Determinism: seed recorded, tools pinned, reproducible | DONE (0xC0FFEE; regen verified identical) |
| 2.6 | Idempotent setup script | DONE (re-run safe, verified) |
| 2.7 | TT-faithful; flag area trend | DONE (flagged) |
| 2.8 | Hard-stop conditions | N/A (never met; BLOCKED.md never needed) |
| 3 | OSS CAD Suite arm64 primary; verification gate before RTL | DONE (gate log in PROGRESS) |
| 3 | numpy-only reference; no torch/mamba_ssm | DONE |
| 4 | Self-generated golden: image, trace.npz, csr_config.hex, shared PWL tables | DONE |
| 4 | `--from-checkpoint` best-effort | SKIPPED as permitted (logged); `tiny_lm.py` adds a *trained* (bigram-MLE) model instead |
| 5 | All pinned defaults | DONE (ASSUMPTIONS table) |
| 6 | Stages 0–8 with commits | DONE |
| 7 | Make targets: setup/golden/lint/sim/synth/pnr/timing/bitstream/report/all; lint before sims; requirements.txt | DONE (+ `demo` target) |
| 8 | Logging/checkpointing/tag `pre-hardware-v1` | DONE |
| 9 | REPORT.md contents (matrix, resources/Fmax, bitstream, assumptions, handoff, honest risk) | DONE |
| 10 | Stop after stage 8; no programming; human next steps | DONE |

## Known gaps summary (all documented above)
1. CLK_DIV CSR reserved; PHY CK ratio fixed at clk/4 (board wrapper divides).
2. PACKING CSR reserved; only 2-bit/trit implemented (per pinned default).
3. No hosted CI (no git remote); `scripts/ci.sh` is the commit gate.
4. Hardware checkpoints of milestones 1–4 pending a board (by design).
5. ~~tCSM-vs-Fmax gap~~ — resolved 2026-07-06 (clk/2 PHY + 12 MHz pipeline).
6. TT area trending above the 8–12-tile sketch (REPORT §2, flagged).
