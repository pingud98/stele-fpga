# STELE — Ternary-Weight LLM Inference on a Tiny ASIC

> *Can we build an entire LLM inference engine — weights, state, and activations — on a chip that costs under $10 in bulk, runs on milliwatts, and fits on a process old enough to be essentially radiation-hard?*

**STELE** (Streaming Ternary-SSM Engine for Low-Energy inference) is an FPGA-first, ASIC-bound project to answer that question. The goal: a complete, self-contained language model running on a chip so small and simple that a single human can audit the entire codebase.

---

## The Idea

Modern LLMs are absurdly over-provisioned for most useful tasks. A terminal emulator doesn't need to write poetry — it needs to map "show me the largest files in this directory" to `du -sh * | sort -h | tail`. A satellite fault-detection system doesn't need to discuss philosophy — it needs to recognise anomalous log patterns against a constrained grammar of possible faults.

The insight: **constrained output spaces dramatically reduce the model size needed for useful work.** When the model only needs to speak a command language, a configuration grammar, or a diagnostic taxonomy, hallucination becomes a solvable engineering problem rather than a research one.

STELE explores the extreme end of this: **ternary-weight (-1, 0, +1) state-space models** running on a multiply-free datapath, with all model state living in cheap off-chip HyperRAM. No matrix multiplications. No GPU. No heatsink.

---

## Prior Art

This isn't a new idea. Several groups have demonstrated that ternary and 1.58-bit models work:

- **[tiny-asic-1_58bit-matrix-mul](https://github.com/rejunity/tiny-asic-1_58bit-matrix-mul)** — A Tiny Tapeout ASIC implementing 1.58-bit matrix multiplication in silicon. Demonstrated that ternary-weight matmuls can run on a process large enough to be hand-auditable. STELE builds on this concept but aims for a **complete end-to-end inference pipeline** rather than just the matmul primitive.

- **BitNet b1.58** (Ma et al., Microsoft Research, 2024) — Showed that LLMs with weights quantised to {-1, 0, +1} match full-precision performance at scale. The maths works.

- **Mamba / Selective State Spaces** (Gu & Dao, 2023) — Replaced attention with a recurrent state-space formulation, removing the quadratic memory cost and making streaming inference practical on constrained hardware.

- **TernaryBERT** (Zhang et al., 2020) and the broader ternary neural network literature — Established that ternary weights are viable for transformer architectures.

STELE differs from these in ambition: **we're not proving the maths again — we're proving that the whole stack (PHY → datapath → FSM → token I/O → software driver) fits in a budget that makes sense for real deployment.** The FPGA phase targets the iCE40 UP5K (~5k LUTs, a $20 dev board); the ASIC phase targets Tiny Tapeout and eventually a GF180 20 mm² slot.

---

## Architecture (One Sentence)

**The chip holds only a HyperBus PHY, a microsequencer, a small arithmetic datapath, and a few hundred flops — everything else (model weights, SSM recurrent state, activation vectors) lives in a single external HyperRAM.** The chip is a busmaster with an ALU attached, not a processor with memory.

This collapses the design from "hundreds of SRAM tiles" to roughly 10–15k gates — small enough to fab on Tiny Tapeout, cheap enough to manufacture in bulk, and simple enough for one person to understand end-to-end.

[Full architecture and bring-up brief: `CLAUDE.md`]

---

## Why HyperRAM?

HyperRAM speaks **SPI-like signalling** over a small number of pins — typically 8 data lines plus a clock and chip select. This is the critical enabler:

| Constraint | HyperRAM solves it |
|---|---|
| Tiny Tapeout pin budget (~8 I/O) | HyperBus uses 11 pins total, muxes with token I/O |
| No on-die SRAM (area) | 8–64 Mbit off-chip for pennies |
| No calibrated DDR I/O | SDR mode works through slow, uncalibrated pads |
| Cost target | ISSI/Cypress HyperRAM is ~$0.50–1.50 in volume |

The FPGA phase proves the PHY works through the same kind of degraded I/O that Tiny Tapeout will impose. If it runs on an iCE40 with no DDR hardware, it runs on TT silicon.

---

## What Can It Be Used For?

### 1. Natural-Language Terminal Interfaces

Replace command-line syntax with constrained natural language:

```
> show me python files modified this week, sorted by size
  → find . -name "*.py" -mtime -7 -exec ls -lh {} \; | sort -k5 -h

> what's eating memory right now?
  → ps aux --sort=-%mem | head -5
```

The output grammar is a known, bounded set of shell commands. The model learns to map intent → syntax. Hallucination is limited because invalid commands simply fail with an error, providing a tight feedback loop. This is qualitatively different from open-ended chatbot generation.

### 2. A New Kind of PC

We've spent decades layering abstraction on abstraction: OS X, Windows, Linux, systemd, Electron. A Fable-sized model (~100M–300M params) running on a STELE-class chip could power an operating system where the interface *is* the model — not as a chatbot floating on top of a traditional OS, but as the shell itself.

The key constraint that makes this tractable: **the model only needs to support the actual hardware present.** It doesn't need to understand every possible GPU driver, filesystem, or network topology — just the specific board it's running on. The entire software stack becomes auditable by a single person or small team, because the model replaces millions of lines of general-purpose OS code with a focused, hardware-specific inference task.

### 3. Satellite & Space Applications

Large-node processes (130 nm, 180 nm) are intrinsically more radiation-tolerant than advanced nodes — fewer single-event upsets, better total ionising dose tolerance. A STELE-class chip on GF180 is, by the nature of its process, suitable for LEO and beyond:

- **Fault detection in telemetry logs** — match patterns in satellite housekeeping data against a constrained diagnostic grammar
- **On-board data triage** — decide which observations are worth downlinking before the pass window closes
- **Space data centres** — a network of tiny, rad-hard inference nodes consuming single-digit watts, processing data in orbit rather than sending raw streams to the ground

The power envelope matters here: **milliwatts, not watts.** A satellite's power budget doesn't accommodate a GPU.

### 4. Cost Comparison

| Hardware | ~10 tok/s capability | Cost | Power |
|---|---|---|---|
| Raspberry Pi 5 + CPU inference | Barely (7B q4 ≈ 2–4 tok/s) | ~$60 | ~10 W |
| Jetson Orin Nano | Yes (7B q4 ≈ 15–20 tok/s) | ~$500 | ~7–15 W |
| RTX 4090 | Absurd overkill | ~$1,800 | ~450 W |
| **STELE-class ASIC + HyperRAM** | **~10–20 tok/s (target)** | **<$10 (bulk)** | **<500 mW** |

When you compare the hardware needed to get >10 tok/s even on a small model, the cost-per-token of a dedicated ASIC is not negligible — it's potentially transformative for embedded deployment.

---

## Current Status

**Phase:** FPGA bring-up (iCE40 UP5K on icebreaker board)

- [x] Architecture defined (see `CLAUDE.md`)
- [x] Ternary MAC datapath RTL
- [x] Scan ALU (SSM selective scan primitive)
- [x] Piecewise-linear activation (SiLU approximation)
- [x] Address generator for weight/state/scratch bases
- [ ] HyperBus PHY (in progress — the critical path)
- [ ] Full per-token FSM integration
- [ ] Cocotb verification against PyTorch golden reference
- [ ] iCE40 synthesis → physical HyperRAM test

Next: Tiny Tapeout submission (~8–12 tiles), then wafer.space GF180 20 mm².

---

## Repository Structure

```
stele-fpga/
├── rtl/           # Synthesizable Verilog (PHY, datapath, FSM)
├── sim/           # Cocotb testbenches + HyperRAM behavioral model
├── golden/        # PyTorch reference model
├── fpga/          # iCE40 constraints, PCF, top-level wrapper
├── demo/          # Host-side driver and demo scripts
├── docs/          # Diagrams, pinouts, timing
├── scripts/       # Build, lint, simulation runners
├── CLAUDE.md      # Detailed bring-up brief
├── PROGRESS.md    # Development log
├── REPORT.md      # Design rationale and trade-offs
├── ASSUMPTIONS.md # Design assumptions register
├── Makefile       # sim, lint, synth targets
└── README.md      # This file
```

---

## Getting Started

```bash
# Install dependencies
pip install -r requirements.txt
# (cocotb, Icarus Verilog or Verilator)

# Run unit tests
make sim

# Lint
make lint

# Synthesise for iCE40 (requires Yosys + nextpnr + icestorm)
make synth
```

---

## Why "STELE"?

A *stele* (στήλη) is an ancient inscribed stone slab — a marker, a record, a piece of information carved into something durable. The name reflects the ambition: inference engines that are physical, permanent, auditable objects rather than ephemeral cloud services.

---

## License

MIT — see `LICENSE` file.

---

*"The larger objective is being able to audit the codebase with a human — a single human, or a very small team."*
