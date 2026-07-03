# STELE FPGA — Autonomous Execution Runbook (Radxa Q6A / aarch64)

**Read `stele-fpga-bringup-brief.md` (the spec) in full before doing anything.** That document defines the architecture, the TT-compatible top-level interface, the pin map, the HyperBus PHY behaviour, the datapath, the FSM phases, and the module hierarchy. **This runbook governs how to execute that spec autonomously on the target machine, and it OVERRIDES the spec in two places, both marked below:**
- **§4 here overrides the spec's golden-model dependency** (spec §2/§11/§12): do **not** wait for a human-supplied PyTorch model. Bootstrap the reference yourself.
- **§1/§3 here pin the environment and toolchain** the spec left open.

The operator (James) is leaving this running with **minimal intervention**. Optimise for an unattended, resumable, self-correcting run that ends at a synthesised bitstream plus a green simulation suite — *not* at programmed hardware.

---

## 1. Execution environment (OVERRIDE: pins the target)

- **Machine:** Radxa Dragon Q6A, Qualcomm QCS6490, **aarch64 (ARM64) Linux** (Debian/Ubuntu-family assumed). Verify with `uname -m` (expect `aarch64`) and `cat /etc/os-release`.
- **Resources:** modest SBC. **Probe first** (`nproc`, `free -h`, `df -h`) and size all parallelism to fit:
  - Set `make -j$(( $(nproc) > 4 ? 4 : $(nproc) ))` and cap Verilator/iverilog parallel jobs to avoid OOM.
  - If `free -h` shows < ~4 GB available, build sims single-threaded and keep simulation configs at the tiny defaults in §5.
  - UP5K place-and-route is lightweight — it will fit comfortably; the memory risk is Verilator compilation and large traces, not PnR.
- **No FPGA board attached.** This is a **pre-hardware** run. Never invoke `iceprog`/`openFPGALoader` against hardware. The endpoint is bitstream + sims (see §10).
- **Network:** available for tool/model download. Prefer pinned versions; record every URL and version used.

---

## 2. Autonomy contract (operating rules)

1. **Test-driven, milestone-gated.** Follow the bring-up milestones in spec §13 and the run sequence in §6 here. Write the test first; do not advance to the next stage until the current stage's tests pass. A red test is a stop-and-fix, never a skip.
2. **Default rather than block.** Every open decision has a pinned default in §5. If you hit an unspecified choice, pick the most conservative reasonable option, **log it in `ASSUMPTIONS.md` with rationale**, and continue. Only hard-stop for a true blocker (see rule 8).
3. **Commit at every green milestone.** `git init` early; commit after each passing stage with a message naming the milestone. The run must be resumable from any commit.
4. **Log everything.** Append a timestamped entry to `PROGRESS.md` at the start and end of each stage: what was attempted, command(s), result, test pass/fail counts, and any assumption made. This is the operator's window into the unattended run.
5. **Determinism.** Seed all RNG (Python, weight generation) from a fixed constant recorded in `ASSUMPTIONS.md`. Pin tool versions. Re-running the flow must reproduce identical golden traces and identical sim results.
6. **Idempotent setup.** `scripts/setup_toolchain.sh` must be safe to re-run; detect already-installed tools and skip.
7. **Keep it TT-faithful.** Honour spec §14 throughout (SDR only, synthesizable multiplier as the default path, PWL nonlinearities, no model-scale on-die memory, microcoded sequencer, ~8–12 tile target). Flag in `PROGRESS.md` if a synthesis area estimate trends high.
8. **Hard-stop conditions** (write the reason to `PROGRESS.md` and `BLOCKED.md`, commit, then stop): toolchain cannot be installed by any documented method; a milestone test cannot be made to pass after reasonable iteration and the cause is genuinely ambiguous; or the design cannot be made to fit/route on UP5K. Everything else: default and continue.

---

## 3. Toolchain install (OVERRIDE: pins the method)

Produce `scripts/setup_toolchain.sh`, idempotent, that installs and **verifies** the full flow on aarch64. Primary path is the prebuilt suite; fall back only if it fails.

**Primary — OSS CAD Suite (linux-arm64).** It bundles yosys, nextpnr-ice40, project-icestorm, iverilog, verilator, and cocotb as native arm64 binaries.
- Resolve the latest release tag from `https://github.com/YosysHQ/oss-cad-suite-build/releases`, download the `oss-cad-suite-linux-arm64-*.tgz` asset, extract to `~/eda/oss-cad-suite`, and source its environment script (`source ~/eda/oss-cad-suite/environment`). Persist that `source` line into the project's `env.sh` so every later stage has the tools on `PATH`.

**Fallback — distro + pip** (if the prebuilt asset is missing/broken for this arch):
- `sudo apt-get install -y yosys nextpnr-ice40 fpga-icestorm iverilog verilator gtkwave build-essential git python3-pip` (names may vary; adapt).
- `pip install --user cocotb cocotb-test pytest numpy`.
- If a distro package is absent, build that one tool from source (yosys/nextpnr/icestorm all build on aarch64), but try hard to avoid this — prefer the suite.

**Verification gate (must pass before any RTL work):** run and log `--version` for `yosys`, `nextpnr-ice40`, `icepack`, `icetime`, `iverilog`, `verilator`, and `python3 -c "import cocotb, numpy"`. Write results to `PROGRESS.md`. If any tool is missing, attempt the fallback for that tool, then re-verify. If still missing → hard-stop (rule 8).

**Python numerics:** prefer **numpy only** for the reference model (see §4). Do **not** assume `torch` is needed; if you do use torch, install the CPU aarch64 wheel and never the CUDA build, and never depend on the `mamba_ssm` package (its selective-scan kernel is CUDA-only and will not run on this device).

---

## 4. Golden reference pipeline (OVERRIDE: removes the human dependency)

The spec defers the golden model to the operator. **Do not wait.** Generate the reference yourself, using this key decoupling:

> **RTL correctness needs a bit-exact fixed-point reference, not a *trained* model.** Whether the weights are good at language is irrelevant to verifying that the hardware reproduces the arithmetic. So a seeded-random quantised model is a fully valid golden reference for this entire phase.

Build `golden/reference_model.py` (numpy, CPU, no CUDA, no mamba_ssm):
- A self-contained **sequential-scan** implementation of the quantised ternary/int8 selective-SSM forward pass, matching the RTL's fixed-point spec **exactly** (ternary weights {−1,0,+1}; int8 activations/state; int16/int32 accumulators; PWL `softplus`/`exp`/`SiLU` using the *same* segment tables the RTL uses — share them via a generated header/`.mem` so both sides are identical by construction).
- **Default weights: seeded random**, quantised to the target formats. Deterministic from the fixed seed in `ASSUMPTIONS.md`.
- **Optional, best-effort: an existing open checkpoint.** If a small open SSM checkpoint can be loaded with numpy/torch-CPU *without* the CUDA kernel, offer a `--from-checkpoint` path that imports and quantises it. If loading fails for any reason, **fall back to random weights and log it** — never block on this.
- Outputs:
  1. `golden/hyperram_image.bin` — weights/conv-kernels/A/embedding/LM-head packed in **streaming order** per spec §9, plus initialised state/scratch regions, laid out at the CSR-defined bases. This is what the behavioral HyperRAM model loads.
  2. `golden/trace.npz` — per-phase intermediate vectors and final per-token logits/argmax for N tokens, the bit-exact expected values the cocotb tests assert against.
  3. `golden/csr_config.hex` — the CSR boot stream (dims, bases, latency, packing).

The cocotb full-FSM test (spec milestone 7) must reproduce `trace.npz` **bit-exactly**.

---

## 5. Resolved defaults (so nothing blocks)

These pin every open item in spec §15 for the autonomous run. Record them in `ASSUMPTIONS.md`; the operator can change them later.

| Item | Default |
|---|---|
| HyperRAM behavioural model | Generic 3.3 V x8 HyperBus, ISSI IS66WVH-class timings; fixed read latency configurable via CSR; enforce `tCSM` = 4 µs in the model (assert if exceeded) |
| Ternary packing | 2 bits/trit, 4 trits/byte (simple unpack); leave `PACKING` param hook for 5-trit/byte later |
| Vocabulary | `VOCAB=128` (7-bit, single-beat token I/O) |
| Sim model dims | `D_MODEL=64, N_LAYERS=2, D_STATE(N)=16, D_CONV=4, E=2` — tiny, for fast ARM sim |
| Clock | Single domain; PHY runs at a low divided rate; expose `CLK_DIV` |
| Multiplier | **Synthesizable `mult_synth.v` is the default/tested path**; `SB_MAC16` behind `USE_DSP=0` by default |
| Token count for full-gen test | 8 tokens (enough to exercise state recurrence; keeps sim short) |
| RNG seed | Fixed constant (record value) |

---

## 6. End-to-end run sequence

Each stage ends with a commit and a `PROGRESS.md` entry. Stages map onto spec §13 milestones.

**Stage 0 — Bootstrap.** Probe environment (§1). Run `scripts/setup_toolchain.sh`; pass the verification gate (§3). `git init`; scaffold repo per spec §10 plus `golden/`, `scripts/`, `PROGRESS.md`, `ASSUMPTIONS.md`. Create `env.sh`.

**Stage 1 — Golden reference (§4).** Implement `reference_model.py`; generate `hyperram_image.bin`, `trace.npz`, `csr_config.hex`, and the shared PWL segment tables. Unit-test the reference against a plain float SSM to confirm the quantisation is sane (not bit-exact to float — just sanity bounds). Commit.

**Stage 2 — Behavioral HyperRAM model + DQ I/O (spec milestone 1).** Write `sim/hyperram_model.v` (CA decode, configurable latency, RWDS, DQ tri-state, `tCSM` assertion, loads `hyperram_image.bin`). Write `hyperbus_dq_io.v` (`SB_IO` registered bidir + OE) and a loopback cocotb test. Green → commit.

**Stage 3 — HyperBus PHY (spec milestones 2–4).** Implement `hyperbus_phy.v` (SDR, CA gen, sampled-RWDS latency, configurable latency, `tCSM` bursting). cocotb tests against the model: (2) config-register read, (3) single-word write→read-back, (4) burst within `tCSM`. This is the critical block — most iteration expected here. Green → commit.

**Stage 4 — Datapath primitives (spec milestone 5).** `ternary_mac.v`, `scan_alu.v` (+`mult_synth.v`), `pwl_nonlin.v`. Unit-test each against the numpy reference's corresponding op using the shared segment tables. Green → commit.

**Stage 5 — Sequencer + single-layer FSM (spec milestone 6).** `sequencer.v` (microcoded), `addr_gen.v`, `regfile.v`, `csr.v`, top `tt_um_stele_ssm.v`. Run one Mamba block end-to-end vs the golden trace, state streamed to the HyperRAM model. Green → commit.

**Stage 6 — Full per-token generation (spec milestone 7).** All layers + LM head + embedding lookup; generate the default token count; assert **bit-exact** vs `trace.npz`. Green → commit.

**Stage 7 — Synthesis & pre-hardware checks.** `fpga/top_icebreaker.v` wrapper + `icebreaker.pcf` (3.3 V bank for HyperRAM pins; map the spec §5 pin table). Then:
- `yosys` synth → report cell usage / estimated LUT4 + EBR + DSP count.
- `nextpnr-ice40` (UP5K, package `sg48`) place & route → report utilisation and achieved Fmax.
- `icetime` timing → confirm the design closes at the chosen `CLK_DIV` clock; if not, lower the default clock and record the max that closes.
- `icepack` → produce `build/stele.bin` (bitstream artifact, not programmed).
Green/closed → commit.

**Stage 8 — Final report (§9).** Write `REPORT.md`. Stop (§10).

---

## 7. Build system & reproducibility

- `Makefile` (or `tox`/`pytest` + make) targets: `setup`, `golden`, `lint`, `sim` (per-stage and `sim-all`), `synth`, `pnr`, `timing`, `bitstream`, `report`, `all`.
- `make lint` = Verilator `--lint-only` on all RTL; run it before every sim stage.
- Pin tool versions in `ASSUMPTIONS.md`; pin Python deps in `requirements.txt`.
- `make all` from a clean checkout on this machine must reproduce identical golden traces and identical pass/fail results.

---

## 8. Logging, checkpointing, git discipline

- `PROGRESS.md`: timestamped per-stage log (see §2.4). This is the primary operator-facing artifact during the run.
- `ASSUMPTIONS.md`: every default taken, every version pinned, the RNG seed, any deviation from the spec.
- `BLOCKED.md`: created only on a hard-stop, with the precise failure, what was tried, and the minimal human action needed to unblock.
- Git: commit per green stage with milestone-named messages. Tag the final synthesised state `pre-hardware-v1`.

---

## 9. Final report (`REPORT.md`)

Produce a concise operator report containing:
- **Pass/fail matrix** across spec milestones 1–7 (sim) and stage 7 (synth/PnR/timing).
- **Resource result:** estimated TT-equivalent gate count and the FPGA utilisation (LUT4 / EBR / DSP) and achieved **Fmax** on UP5K. Compare against the ~8–12 tile target and flag if over.
- **Bitstream:** path to `build/stele.bin` and the clock it closes at.
- **Assumptions & deviations:** summary of `ASSUMPTIONS.md`, especially whether random or checkpoint weights were used.
- **Hardware-readiness / handoff (§10):** exactly what the operator must do to take this to silicon.
- **Honest risk note:** restate that a clean FPGA result validates protocol/timing-logic but **not** the pad-electrical path (TT IO mux + sky130/GF180 IO cells), and that the real PHY-on-hardware test still requires a wired HyperRAM and a board.

---

## 10. Stop condition & handoff

**Stop after Stage 8.** Do **not** attempt to program any board. The autonomous deliverable is: green sims through full token generation, a routed+timed design, and a built bitstream, all reproducible via `make all`.

In `REPORT.md`, list the human-only next steps:
1. Confirm/realise the HyperRAM part choice (spec §15.1) and adjust the behavioural model timings / single-ended-CK assumption if the real part differs.
2. Wire HyperRAM to an icebreaker (short traces, 3.3 V bank, series Rs on CK/DQ), program `build/stele.bin`, and re-run the bring-up milestones **against real silicon** — config-register read first, then single-word read-back (the true PHY de-risk).
3. Supply a trained/quantised checkpoint to replace the random golden weights if functional language behaviour is wanted (correctness of the RTL is already proven regardless).

---

## 11. First action

Probe the environment (§1), then write and run `scripts/setup_toolchain.sh` and pass the §3 verification gate. Then scaffold the repo and begin Stage 1. Log as you go. Build the PHY and its testbench before any compute — per the spec, the PHY through a slow uncalibrated I/O path is the entire risk; the arithmetic is the easy part.
