# STELE — FPGA Bring-Up Brief (Streaming Ternary-SSM Inference Core)

**Purpose of this document:** a self-contained brief for a Claude Code session to begin the RTL + verification work. Drop it in the repo root (e.g. as `CLAUDE.md` or `docs/brief.md`) and start from the "First tasks" section at the end.

---

## 1. Context & goal

We are building a **multiply-free, ternary-weight selective state-space (Mamba-style) inference core** intended for eventual fabrication on Tiny Tapeout (sky130/IHP130/GF180) and later a wafer.space GF180 20 mm² slot. The defining architectural choice:

> **The external HyperRAM is a unified scratchpad.** Model weights, the SSM recurrent state, *and* intermediate activation vectors all live off-chip. The chip holds only: a HyperBus PHY, a microsequencer/FSM, a small arithmetic datapath, and a few hundred flops of working registers. No model-sized memory on-die.

This is what collapses the design from "hundreds of tiles" to a ~10–15k-gate streaming engine. The cost is bus-bound throughput (single-digit-to-low-tens of tokens/sec), which is acceptable for the target.

**Why an FPGA first.** The single highest-risk block is the **HyperBus PHY through a slow, uncalibrated I/O path** — the same constraint Tiny Tapeout will impose via its I/O mux. The iCE40 has no calibrated DDR I/O, which makes it a *faithful* analogue of TT's limitations rather than a flattering one. If the PHY works here in degraded mode, it is strong evidence it works on TT silicon.

**De-risk ladder (for orientation, not this phase's scope):**
1. **FPGA (this phase)** — prove the PHY + full per-token FSM in real hardware. Throughput irrelevant.
2. Tiny Tapeout (~8–12 tiles) — same RTL, prove it in silicon cheaply.
3. wafer.space GF180 20 mm² — real fast pads + on-chip state SRAM → the performant engine.

---

## 2. Scope

**In scope (this phase):**
- Synthesizable RTL for the streaming core, with a **TT-compatible top-level interface** from the start.
- A behavioral HyperRAM model for simulation.
- A cocotb verification suite, test-driven, following the bring-up milestones in §13.
- Open-source iCE40 flow (Yosys + nextpnr + icestorm) targeting the **iCE40 UP5K (icebreaker)**.
- A constraints file (PCF) and a HyperBus PHY that works in **SDR / slow-clock / sampled-RWDS** mode.

**Out of scope (this phase):**
- The ASIC hardening flow (OpenLane/TT template). We keep the RTL portable but do not harden here.
- Model training. The PyTorch golden reference is an **external dependency** (see §12) supplied by James; until it exists, work proceeds on the PHY and on model-agnostic datapath primitives with synthetic unit tests.
- Any reliance on full-speed differential-clock DDR HyperBus.

---

## 3. Target platform & toolchain

- **FPGA:** iCE40 UP5K (`iCE40UP5K-SG48`), icebreaker board. ~5.3k LUT4, ~120 kbit EBR, 8× `SB_MAC16` DSP, 2× PLL.
- **HyperRAM:** a **3.3 V** part (e.g. ISSI IS66WVH8M8 or Infineon/Cypress S27KL0641 in 3.0–3.6 V mode). Wire via PMOD/GPIO with short traces, ground plane, and series resistors on CK/DQ. Power the relevant iCE40 bank at 3.3 V. **Confirm single-ended-CK support for the exact part chosen** (we need single-ended CK because that is what maps to TT).
- **Synthesis/PnR:** Yosys → nextpnr-ice40 → icepack/iceprog. Use inferred EBR where possible; instantiate `SB_IO`, `SB_PLL40_*`, and (optionally) `SB_MAC16` explicitly.
- **Simulation:** cocotb with Icarus Verilog (and/or Verilator for speed). Python golden-model comparison.
- **Lint:** Verilator `--lint-only` in CI.

---

## 4. Architecture overview

```
        iCE40 UP5K  (datapath + FSM + PHY + working regs only)
 ┌────────────────────────────────────────────────────────────┐
 │ ui_in[7:1] ─► CSR load + token-in latch                      │
 │ ui_in[0]=RWDS ─┐ (sampled, not strobe-clocked)               │
 │                ▼                                             │
 │ uio[7:0]◄─►┌────────────┐      ┌──────────────────────────┐  │
 │ uo[0]=CK◄──┤ HyperBus   │◄────►│  Microsequencer / FSM    │  │
 │ uo[1]=CS#◄─┤  PHY (SDR) │      │  per layer:              │  │
 │            │ CA gen +   │      │  IN_PROJ→CONV→SCAN_PREP→  │  │
 │            │ SB_IO DQ   │      │  SCAN→GATE→OUT_PROJ       │  │
 │            └─────┬──────┘      │  then LM_HEAD            │  │
 │            data  │             └──┬───────┬───────┬───────┘  │
 │        ┌─────────┴──┐  ┌──────────┐ ┌────────┐ ┌──────────┐  │
 │        │ Ternary MAC│  │ Scan ALU │ │  PWL   │ │ Addr gen │  │
 │        │ add/sub/   │  │ int8 ×,  │ │ nonlin │ │ weight/  │  │
 │        │ skip→acc   │  │ int16/32 │ │ exp,   │ │ state/   │  │
 │        │            │  │ acc      │ │softplus│ │ scratch  │  │
 │        └─────┬──────┘  └────┬─────┘ │ SiLU   │ │ bases    │  │
 │              └─────────┬────┴───────┴───┬────┘ └──────────┘  │
 │                        ▼                ▼                    │
 │            Working regfile (~256 flops; operands +           │
 │            accumulators + requant — NOT model state)         │
 │  uo[2]=out_valid uo[3]=in_req uo[4]=busy uo[7:5]=fsm_dbg     │
 └───────────────────────────┬────────────────────────────────┘
                            uio (DQ when CS# low)
                  ┌───────────▼────────────┐
                  │  External HyperRAM     │  weights ‖ state ‖
                  │  3.3 V, 8–32 Mbit      │  activation scratch
                  └────────────────────────┘
```

---

## 5. Interface contract (TT-compatible top level)

The top module **must** use the Tiny Tapeout port signature so the RTL promotes to TT unchanged:

```verilog
module tt_um_stele_ssm (
    input  wire [7:0] ui_in,    // dedicated inputs
    output wire [7:0] uo_out,   // dedicated outputs
    input  wire [7:0] uio_in,   // bidir: input path
    output wire [7:0] uio_out,  // bidir: output path
    output wire [7:0] uio_oe,   // bidir: output enable (1=drive)
    input  wire       ena,      // high when design selected (ignore logic-wise)
    input  wire       clk,      // main clock
    input  wire       rst_n     // active-low reset
);
```

On the FPGA, a thin wrapper maps these to physical pins via `SB_IO` and the PCF. On TT, the harness drives them directly. **Keep all design logic behind this boundary identical across both targets.**

### Pin map

| Port bit | Dir | Function | iCE40 note |
|---|---|---|---|
| `uio[7:0]` | bidir | **HyperRAM DQ[7:0]** when CS# low; **token byte** when CS# high | `SB_IO` registered bidir, `OUTPUT_ENABLE` from `uio_oe` |
| `uo_out[0]` | out | HyperRAM **CK** | route to a fast, short trace |
| `uo_out[1]` | out | HyperRAM **CS#** (also selects uio mode) | |
| `uo_out[2]` | out | **out_valid** | token on uio ready |
| `uo_out[3]` | out | **in_req** | core requests next input token |
| `uo_out[4]` | out | **busy** | |
| `uo_out[7:5]` | out | **fsm_dbg[2:0]** | expose FSM state — keep for silicon bring-up |
| `ui_in[0]` | in | HyperRAM **RWDS** | sampled at CA phase for latency, then fixed offsets |
| `ui_in[1]` | in | **host_drive** | host owns uio → core tri-states it |
| `ui_in[2]` | in | **in_valid** | host placed token on uio |
| `ui_in[3]` | in | **cfg_mode** | boot: stream CSRs over uio |
| `ui_in[7:4]` | in | spare / config-select / debug | |
| `clk`,`rst_n` | — | provided by board/harness | run clk slow first (≈6–12 MHz) |

**uio sharing rule:** when `CS#`=0 the bus is a HyperRAM transaction (DQ); when `CS#`=1 the bus is idle and uio carries token I/O gated by `host_drive`/`in_valid`/`out_valid`. HyperRAM tri-states DQ when deselected, so there is no contention — but the PHY must guarantee `uio_oe`=0 whenever `host_drive`=1.

---

## 6. HyperBus PHY (the critical block — build and test this first)

Design it for the **degraded mode that matches TT**, not for performance:

- **SDR only** (no double-data-rate capture). Single-ended CK on `uo_out[0]`.
- **Slow, parametrizable clock.** Target first light at the lowest workable rate; make the clock external/divisible.
- **Sampled RWDS, not strobe-clocked.** Read RWDS during the CA phase to determine variable vs fixed latency, then capture DQ on **fixed cycle offsets** characterized for the board — do *not* use RWDS edges to clock data into a FIFO (iCE40 has no per-pin delay calibration, and TT can't do it either).
- **`tCSM`-aware bursting.** Respect the maximum CS#-low time (typically ~1–4 µs; read the datasheet). Break long transfers into multiple transactions with re-issued CA. Build this into the FSM now — it is also a TT constraint.
- **Configurable read latency** (CSR field) so the same RTL works across parts/clocks without a respin.
- **`SB_IO` bidirectional DQ** with registered input capture and tri-state `OUTPUT_ENABLE`. This registered-bidir-with-OE instantiation is the fiddly part on iCE40 — isolate it in its own module with a focused testbench.

PHY public operations the sequencer calls: `read(addr, len) → stream`, `write(addr, data[]) → done`, `read_reg(reg) → value`, `write_reg(reg, value)`.

---

## 7. Datapath spec

**Numeric formats (defaults — parametrize):**
- Weights: **ternary {−1, 0, +1}**. First-cut packing: **2 bits/trit, 4 trits/byte** (simple unpack). Note for later ASIC density: 5 trits/byte (3⁵=243) is the optimization — leave a `PACKING` parameter hook but default to the simple scheme.
- Activations / state: **int8** stored; **int16 (or int32) internal accumulators**, requantize on writeback.
- SSM constants (A, B, C, Δ): keep at the precision the golden model uses (likely int8–int16); do **not** ternarize the scan path.

**Ternary MAC lane:** `+1 → acc += x`, `−1 → acc −= x`, `0 → skip`. A mux + adder into a wide accumulator. Single lane (serialize — we are bus-bound, not compute-bound).

**Scan ALU:** per channel `h = Ā·h + B̄·x`; accumulate `y += C·h`. These are real int8×int8 → int16 multiply-accumulates.
- Provide a **plain-Verilog synthesizable multiplier** (this is what ships to TT).
- Optionally also wire an `SB_MAC16` path for FPGA speed, behind a `USE_DSP` parameter — but the **default test target must exercise the synthesizable multiplier**, since TT has no DSP.

**Nonlinearities — piecewise-linear (PWL), not full LUT ROMs:**
- `softplus(Δ)`, `Ā = exp(Δ·A)` (domain is ≤0 since A<0,Δ>0 → Ā∈(0,1], bounded — good for PWL), `SiLU(gate)`.
- A few segments + small multiply-add each. PWL is the single biggest area saver on TT; design it in from the start. Keep segment tables in parameters so accuracy/area is tunable.

---

## 8. Microsequencer & per-token FSM

**Keep the sequencer microcoded** (small control ROM), not hardwired. It costs ~1k extra gates but lets us reorder layer phases or add blocks without a respin on first silicon — worth it.

Per output token, loop layers `0..L−1` through these phases (exact math follows the golden reference; this is the structural shape):

1. **IN_PROJ** — stream ternary `W_in` from HyperRAM; ternary-MAC vs `x_t` scratch → `x'`, `gate`; write scratch.
2. **CONV** — read conv ring buffer + `x'`; depthwise causal conv (`d_conv=4`); write ring buffer back to state region.
3. **SCAN_PREP** — small projections → Δ, B, C; `Δ=softplus(...)`, `Ā=exp(Δ·A)` via PWL.
4. **SCAN** — read state `h`; per channel `h = Ā·h + B̄·x'`, `y += C·h`; write `h` back.
5. **GATE** — `y = y · SiLU(gate)` via PWL.
6. **OUT_PROJ** — stream ternary `W_out`; MAC → layer output; write scratch.

After last layer: **LM_HEAD** ternary matmul → logits → argmax → next token byte; emit on uio with `out_valid`; embedding lookup (table in HyperRAM) → next `x_t`.

Everything large is a HyperRAM read/write; the on-die regfile only holds operands in flight.

---

## 9. HyperRAM memory map & CSRs

Define a clean, parametrized address layout (base + stride per region), loaded via CSRs at boot (`cfg_mode`):

- `WEIGHTS_BASE` — per-layer W_in, conv kernels, x_proj/dt_proj, A, W_out, plus LM head + embedding table. Lay out in **streaming order** to match the FSM phase sequence (sequential bursts beat random access on HyperBus).
- `STATE_BASE` — SSM `h` and conv ring buffers (read+written every timestep — the high-traffic region).
- `SCRATCH_BASE` — intermediate activation vectors.

**CSRs (minimum):** read-latency, model dims (`D_MODEL`, `N_LAYERS`, `D_STATE=N`, `D_CONV`, `E`, `VOCAB`), region bases, packing mode, clock-divider. A boot loader streams these over uio when `cfg_mode`=1.

---

## 10. Module hierarchy & file layout

```
rtl/
  tt_um_stele_ssm.v        top (TT-compatible ports)
  hyperbus_phy.v           SDR PHY, CA gen, sampled-RWDS, tCSM bursting
  hyperbus_dq_io.v         SB_IO registered bidir DQ (FPGA) — isolate
  sequencer.v              microcoded FSM, control ROM
  ternary_mac.v            add/sub/skip lane
  scan_alu.v               int8 MAC, int16/32 acc, requant
  mult_synth.v             synthesizable int8 multiplier (TT path)
  mult_dsp.v               optional SB_MAC16 wrapper (USE_DSP)
  pwl_nonlin.v             softplus / exp / SiLU PWL units
  addr_gen.v               region base + stride address generation
  regfile.v                small working register file
  csr.v                    config registers + boot loader
fpga/
  top_icebreaker.v         thin wrapper: ports → SB_IO/PLL/PCF
  icebreaker.pcf           pin constraints (3.3 V HyperRAM bank)
  Makefile                 yosys → nextpnr-ice40 → icepack → iceprog
sim/
  hyperram_model.v         behavioral HyperRAM (latency, tCSM, RWDS)
  tb/                      cocotb tests (see §11)
  golden/                  PyTorch/numpy reference exports (external dep)
docs/
  brief.md                 this document
```

---

## 11. Verification strategy

- **Behavioral HyperRAM model** (`sim/hyperram_model.v`): models CA decode, configurable fixed/variable read latency, RWDS behaviour, DQ tri-state, and **tCSM enforcement** (assert/error if CS# held too long). This model is the contract the PHY is tested against — build it alongside the PHY.
- **cocotb, test-driven**, mirroring the milestones in §13. Each milestone is a test that must pass before the next is written.
- **Golden reference:** once James provides the quantized PyTorch model, export per-layer weights (packed), the discretization constants, and a token-by-token activation/logit trace to `sim/golden/`. The full-FSM test must match **bit-exact** (given the fixed-point spec) against this trace.
- **CI:** Verilator lint + Icarus/cocotb on every commit; a synthesis smoke-run (yosys) to catch non-synthesizable constructs early.

---

## 12. Dependencies & assumptions

- **External:** quantized PyTorch reference model (weights + discretization + golden trace) — James, in progress on the M40. Until ready, PHY and primitive datapath modules proceed with synthetic unit tests.
- **Hardware part choice** (HyperRAM) must be fixed early enough to set CA format, latency, and single-ended-CK assumptions. **Open decision — see §15.**
- Assume **single clock domain** where possible. If sampled-RWDS forces any asynchronous capture, document the CDC explicitly and add a synchronizer + constraint.

---

## 13. Bring-up milestones (ordered, test-first)

Each is both a sim test and a hardware checkpoint:

1. **`SB_IO` DQ loopback** — registered bidirectional with OE toggling, in sim and on the icebreaker (loop DQ to itself). Proves the fiddliest FPGA primitive.
2. **Config-register read (ID reg 0)** — proves CA-phase shifting + transaction skeleton. *First light against real HyperRAM.*
3. **Single-word write → read-back** — proves DQ turnaround + fixed read-latency offset. **This is where RWALS/latency capture fails if it's going to** — the core PHY de-risk.
4. **Burst read/write within tCSM** — proves address gen, bursting, multi-transaction splitting.
5. **Datapath unit tests** — ternary MAC, scan ALU, PWL nonlin vs numpy, standalone.
6. **Single-layer FSM** — one Mamba block end-to-end vs golden, state streamed to HyperRAM.
7. **Full per-token generation** — all layers + LM head, multi-token, bit-exact vs golden trace.

Freeze nothing for the TT GDS until milestone 3 passes on real hardware.

---

## 14. TT-faithfulness design rules (respect these throughout)

These keep the FPGA result predictive of TT and the RTL portable:

- **No DDR, no calibrated I/O delays.** SDR + sampled RWDS only.
- **Default build uses the synthesizable multiplier** (`mult_synth.v`), not `SB_MAC16`. DSP path is FPGA-convenience only.
- **EBR is an FPGA luxury.** On TT, anything in block RAM becomes flops/gates. Keep on-die storage to the working regfile; never grow it to model scale. Treat any inferred RAM as a red flag to review.
- **Nonlinearities stay PWL**, not 256-entry ROMs.
- **Single compute lane / one scan channel at a time** — serialize; we are bus-bound.
- **Microcoded sequencer retained** for respin-free flexibility.
- Target the synthesized design at **~8–12 TT tiles**; flag in CI if a synthesis area estimate trends above that.

---

## 15. Open decisions for James (resolve early)

1. **HyperRAM part** — confirm a 3.3 V part with usable single-ended CK; this sets CA format and latency defaults. (Candidates: ISSI IS66WVH8M8, Infineon S27KL0641.)
2. **Ternary packing** — default 2-bit/trit (4/byte) for bring-up vs 5-trit/byte for ASIC density. Brief assumes the simple scheme with a parameter hook; confirm.
3. **Vocabulary width** — 7-bit (≤128 symbols, single-beat token I/O) vs full byte (2-beat). Brief assumes a parameter `VOCAB`; pick the default.
4. **Default model dims for sim** — suggest a tiny config (e.g. `D_MODEL=64, N_LAYERS=2, N=16, D_CONV=4, E=2, VOCAB=128`) for fast tests, with the real target (`D_MODEL≈192–256, N_LAYERS≈8–12`) validated once weights exist.

---

## 16. First tasks for Claude Code

1. Scaffold the repo per §10; set up the Yosys/nextpnr Makefile and a Verilator-lint + cocotb CI.
2. Write `hyperbus_dq_io.v` (`SB_IO` registered bidir + OE) and its loopback test — **milestone 1**.
3. Write `sim/hyperram_model.v` (CA decode, latency, RWDS, tri-state, tCSM enforcement).
4. Write `hyperbus_phy.v` (SDR, CA gen, sampled-RWDS latency, configurable latency, tCSM bursting) and bring it through **milestones 2–4** against the model.
5. Stub the TT-compatible top (`tt_um_stele_ssm.v`) and the icebreaker wrapper/PCF so milestones 1–2 can run on real hardware.
6. Pause for review before the datapath/FSM phases — by then James will confirm §15 and supply the golden reference.

Build the PHY and its testbench first. The compute is the easy part; the PHY through a slow uncalibrated I/O path is the whole risk.
