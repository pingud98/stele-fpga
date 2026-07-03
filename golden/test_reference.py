"""Sanity tests for the golden reference (runbook Stage 1).

Not bit-exactness against float (impossible with int8) — bounds and structure:
the quantised model must be alive (no dead/saturated stages), deterministic,
and its PWL tables must approximate the real functions within coarse bounds.
"""

import math
import os
import subprocess
import sys

import numpy as np
import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pwl
import reference_model as rm


@pytest.fixture(scope="module")
def model():
    rng = np.random.default_rng(rm.SEED)
    return rm.gen_weights(rng)


@pytest.fixture(scope="module")
def run(model):
    return rm.generate(*model)


def test_pwl_softplus_accuracy():
    ref = lambda x: min(255, max(0, round(math.log1p(math.exp(min(x / 8, 30))) * 16)))
    worst = max(abs(pwl.SOFTPLUS.eval(x) - ref(x)) for x in range(-128, 128))
    assert worst <= 8, f"softplus PWL worst error {worst}/16 units"


def test_pwl_silu_accuracy():
    worst = max(abs(pwl.SILU.eval(x) -
                    min(127, max(-128, round(x / 8 / (1 + math.exp(-x / 8)) * 8))))
                for x in range(-128, 128))
    assert worst <= 8, f"silu PWL worst error {worst}/8 units"


def test_pwl_exp_accuracy():
    worst = max(abs(pwl.EXP.eval(x) - round(math.exp(x / 256) * 128))
                for x in range(-2048, 0))
    # 8 uniform segments over [-8,0]: chord error peaks in the last segment
    # where exp curves hardest; 10/128 measured, 12 is the accepted bound.
    assert worst <= 12, f"exp PWL worst error {worst}/128 units"


def test_pwl_exp_bounded():
    for x in (-30000, -2048, -1024, -1, 0, 5):
        y = pwl.EXP.eval(x)
        assert 0 <= y <= 127


def test_pack_trits_roundtrip():
    rng = np.random.default_rng(1)
    w = rng.choice([-1, 0, 1], size=(8, 16)).astype(np.int64)
    packed = rm.pack_trits(w)
    dec = {0: 0, 1: 1, 2: -1, 3: 0}
    unpacked = []
    for b in packed:
        for i in range(4):
            unpacked.append(dec[(int(b) >> (2 * i)) & 3])
    assert np.array_equal(np.array(unpacked).reshape(8, 16), w)


def test_deterministic(model):
    rng2 = np.random.default_rng(rm.SEED)
    m2 = rm.gen_weights(rng2)
    t1, _, _, _ = rm.generate(*model)
    t2, _, _, _ = rm.generate(*m2)
    assert t1 == t2


def test_model_alive(run):
    tokens, steps, h, ring = run
    assert len(set(tokens)) > 2, "token stream degenerate"
    for key in ("x1", "u", "dbc", "delta", "y_gate", "res"):
        for s in steps:
            pass
    last = steps[-1]["layers"][0]
    assert np.abs(last["dbc"]).mean() > 1, "x_proj output dead"
    assert np.abs(last["y_gate"]).sum() > 0, "gate output dead"
    assert any(np.abs(hl).sum() > 0 for hl in h), "SSM state never populated"


def test_state_recurrence_matters(model):
    """Same input token repeated gives different logits once state evolves."""
    _, steps, _, _ = rm.generate(*model)
    same_in = [s for s in steps if s["x_in"].tobytes() == steps[0]["x_in"].tobytes()]
    assert len(same_in) >= 2
    assert not np.array_equal(same_in[0]["logits"], same_in[1]["logits"]), \
        "state has no effect on output"


def test_saturation_bounded(run):
    _, steps, _, _ = run
    for s in steps:
        for l in s["layers"]:
            for key in ("x1", "u", "dbc", "y_gate", "res"):
                a = l[key]
                sat = np.mean((a == 127) | (a == -128))
                assert sat < 0.10, f"{key} saturating {sat:.0%}"


def test_float_correlation(model):
    """First linear stage of the quantised model must correlate strongly with
    float (it is exact linear algebra + requant); deep stages only loosely."""
    layers, lm_head, embed = model
    x = embed[rm.BOS].astype(np.float64)
    accf = layers[0]["w_in"].astype(np.float64) @ x
    xq = rm.tmac(layers[0]["w_in"], embed[rm.BOS], rm.S_IN).astype(np.float64)
    mask = np.abs(accf) < (127 << rm.S_IN)  # exclude saturated entries
    c = np.corrcoef(accf[mask], xq[mask])[0, 1]
    assert c > 0.99, f"IN_PROJ quantisation corr {c:.3f}"


def test_image_layout(model):
    img = rm.build_image(*model)
    assert len(img) == rm.SCRATCH_BASE + rm.SCRATCH_SIZE
    layers, lm_head, embed = model
    a0 = img[rm.OFF_A:rm.OFF_A + rm.SZ_A].astype(np.int8).astype(np.int64)
    assert np.array_equal(a0, layers[0]["A"].flatten())
    e = img[rm.OFF_EMBED:rm.OFF_EMBED + rm.SZ_EMBED].astype(np.int8).astype(np.int64)
    assert np.array_equal(e.reshape(rm.VOCAB, rm.D_MODEL), embed)
    assert not img[rm.STATE_BASE:].any(), "state/scratch not zero-initialised"
