#!/usr/bin/env bash
# CI entry point (spec §11: lint + cocotb + synthesis smoke on every commit).
# Runs standalone on any machine with the toolchain (source env.sh first) —
# usable as a git pre-push hook or a CI job. Fast subset by default; pass
# --full to include the long full-generation sim.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

LUT_BUDGET=5280   # UP5K; also the proxy for the TT area trend flag (§14)

echo "=== golden reference (deterministic regen + sanity) ==="
make golden

echo "=== Verilator lint (-Wall) ==="
make lint

echo "=== cocotb suites ==="
make sim-dq_loopback sim-phy sim-datapath sim-top_layer
if [ "${1:-}" = "--full" ]; then
    make sim-top_full
fi

echo "=== synthesis smoke + area trend flag ==="
make synth
luts=$(grep -oE '^\s+[0-9]+\s+SB_LUT4' build/synth.log | tail -1 | grep -oE '[0-9]+' | head -1)
echo "SB_LUT4 = ${luts} (budget ${LUT_BUDGET})"
if [ "${luts}" -gt "${LUT_BUDGET}" ]; then
    echo "CI FLAG: LUT count ${luts} exceeds UP5K budget — TT area trending high (spec §14)"
    exit 1
fi

echo "CI OK"
