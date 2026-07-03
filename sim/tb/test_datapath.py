"""Milestone 5: datapath primitives vs the numpy golden reference.
PWL units are checked exhaustively and must be bit-exact by construction."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

import pwl
import reference_model as rm


def s8(v):
    v &= 0xFF
    return v - 256 if v >= 128 else v


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 20, "ns").start())
    dut.rst_n.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


# ---------------------------------------------------------------- PWL units
@cocotb.test()
async def test_pwl_softplus_exhaustive(dut):
    dut.pwl_sel.value = 0
    for x in range(-128, 128):
        dut.pwl_x.value = x & 0xFFFF
        await Timer(1, "ns")
        want = pwl.SOFTPLUS.eval(x)
        got = int(dut.pwl_y.value)
        assert got == want, f"softplus({x}): rtl={got} ref={want}"


@cocotb.test()
async def test_pwl_silu_exhaustive(dut):
    dut.pwl_sel.value = 1
    for x in range(-128, 128):
        dut.pwl_x.value = x & 0xFFFF
        await Timer(1, "ns")
        want = pwl.SILU.eval(x) & 0xFF
        got = int(dut.pwl_y.value)
        assert got == want, f"silu({x}): rtl={got} ref={want}"


@cocotb.test()
async def test_pwl_exp_exhaustive(dut):
    dut.pwl_sel.value = 2
    for x in list(range(-2048, 0)) + [-30000, -2049, 0, 100]:
        dut.pwl_x.value = x & 0xFFFF
        await Timer(1, "ns")
        want = pwl.EXP.eval(x)
        got = int(dut.pwl_y.value)
        assert got == want, f"exp({x}): rtl={got} ref={want}"


# ---------------------------------------------------------------- ternary MAC
@cocotb.test()
async def test_ternary_mac_random_rows(dut):
    """Random ternary rows vs rm.tmac partial results, incl. requant."""
    await setup(dut)
    random.seed(0xC0FFEE)
    enc = {0: 0, 1: 1, -1: 2}
    for _ in range(20):
        cols = random.choice([4, 36, 64, 128])
        shift = random.choice([1, 2, 3, 6])
        trits = [random.choice([-1, 0, 1]) for _ in range(cols)]
        xs = [random.randrange(-128, 128) for _ in range(cols)]
        dut.tm_clr.value = 1
        await RisingEdge(dut.clk)
        dut.tm_clr.value = 0
        dut.tm_en.value = 1
        dut.tm_shift.value = shift
        for t, x in zip(trits, xs):
            dut.tm_trit.value = enc[t]
            dut.tm_x.value = x & 0xFF
            await RisingEdge(dut.clk)
        dut.tm_en.value = 0
        await FallingEdge(dut.clk)
        acc_want = sum(t * x for t, x in zip(trits, xs))
        q_want = int(rm.sat8(rm.rshift_round(acc_want, shift))) & 0xFF
        assert int(dut.tm_acc.value.to_signed()) == acc_want
        assert int(dut.tm_q8.value) == q_want


# ---------------------------------------------------------------- scan ALU
@cocotb.test()
async def test_scan_h_update(dut):
    """h_new = sat8(rr(abar*h + bbar*u, 7)) — random + corner cases."""
    await setup(dut)
    random.seed(7)
    cases = [(255, -128, -128, -128), (255, 127, 127, 127), (0, 0, 0, 0),
             (128, 1, -1, 1)]
    cases += [(random.randrange(256), random.randrange(-128, 128),
               random.randrange(-128, 128), random.randrange(-128, 128))
              for _ in range(400)]
    for ab, h, bb, u in cases:
        dut.abar.value = ab
        dut.h_in.value = h & 0xFF
        dut.bbar.value = bb & 0xFF
        dut.u_in.value = u & 0xFF
        await Timer(1, "ns")
        want = int(rm.sat8(rm.rshift_round(ab * h + bb * u, rm.S_SCAN))) & 0xFF
        got = int(dut.h_new.value)
        assert got == want, f"h_new({ab},{h},{bb},{u}): rtl={got} ref={want}"


@cocotb.test()
async def test_scan_mul_requant(dut):
    """mul_out = sat8(rr(a*b, shift)) signed/unsigned; mul_p raw product."""
    await setup(dut)
    random.seed(8)
    for _ in range(400):
        a = random.randrange(-128, 128)
        b = random.randrange(-128, 128)
        sh = random.choice([0, 1, 3, 4, 5, 7])
        au = random.randrange(2)
        av = a & 0xFF if not au else random.randrange(256)
        dut.mula.value = av if au else (a & 0xFF)
        dut.mulb.value = b & 0xFF
        dut.mula_unsigned.value = au
        dut.mshift.value = sh
        await Timer(1, "ns")
        aval = av if au else a
        prod = aval * b
        want = int(rm.sat8(rm.rshift_round(prod, sh))) & 0xFF if sh else \
            int(rm.sat8(prod)) & 0xFF
        assert int(dut.mul_p.value.to_signed()) == prod
        got = int(dut.mul_out.value)
        assert got == want, f"mul({aval},{b},sh={sh},u={au}): {got}!={want}"


@cocotb.test()
async def test_scan_y_accumulator(dut):
    """yacc += C*h over 16 steps, then requant view."""
    await setup(dut)
    random.seed(9)
    for _ in range(10):
        dut.mac_clr.value = 1
        await RisingEdge(dut.clk)
        dut.mac_clr.value = 0
        pairs = [(random.randrange(-128, 128), random.randrange(-128, 128))
                 for _ in range(rm.D_STATE)]
        dut.mac_en.value = 1
        for c, h in pairs:
            dut.mac_a.value = c & 0xFF
            dut.mac_b.value = h & 0xFF
            await RisingEdge(dut.clk)
        dut.mac_en.value = 0
        dut.mac_shift.value = rm.S_C
        await FallingEdge(dut.clk)
        acc_want = sum(c * h for c, h in pairs)
        q_want = int(rm.sat8(rm.rshift_round(acc_want, rm.S_C))) & 0xFF
        assert int(dut.yacc.value.to_signed()) == acc_want
        assert int(dut.yacc_q8.value) == q_want


@cocotb.test()
async def test_scan_worstcase_yacc(dut):
    """Accumulator must not overflow at the +/-16*127*127 extremes."""
    await setup(dut)
    for sign in (1, -1):
        dut.mac_clr.value = 1
        await RisingEdge(dut.clk)
        dut.mac_clr.value = 0
        dut.mac_en.value = 1
        dut.mac_a.value = 127
        dut.mac_b.value = (127 * sign) & 0xFF
        for _ in range(16):
            await RisingEdge(dut.clk)
        dut.mac_en.value = 0
        await FallingEdge(dut.clk)
        assert int(dut.yacc.value.to_signed()) == sign * 16 * 127 * 127


# ------------------------------------------------------------ golden vectors
@cocotb.test()
async def test_scan_step_vs_golden_trace(dut):
    """Drive one full golden scan channel through the primitives and match
    the traced h values bit-exactly (layer 0, last token)."""
    import numpy as np
    await setup(dut)
    rng = np.random.default_rng(rm.SEED)
    layers, _, _ = rm.gen_weights(rng)
    t = np.load(rm.os.path.join(rm.os.path.dirname(rm.os.path.abspath(
        rm.__file__)), "trace.npz"))
    step, layer = 7, 0
    delta = t["delta"][step][layer]
    u = t["u"][step][layer]
    dbc = t["dbc"][step][layer]
    B = dbc[rm.DT_RANK:rm.DT_RANK + rm.D_STATE]
    h_prev = t["h"][step - 1][layer] if step else np.zeros((rm.D_INNER, rm.D_STATE))
    h_want = t["h"][step][layer]
    A = layers[layer]["A"]
    for c in range(0, rm.D_INNER, 17):  # subsample channels for sim speed
        for n in range(rm.D_STATE):
            # dA via mul path (raw product), abar via PWL, h' via h-update
            dut.mula.value = int(delta[c]) & 0xFF
            dut.mulb.value = int(A[c][n]) & 0xFF
            dut.mula_unsigned.value = 1
            await Timer(1, "ns")
            dA = int(dut.mul_p.value.to_signed())
            dut.pwl_sel.value = 2
            dut.pwl_x.value = dA & 0xFFFF
            await Timer(1, "ns")
            abar = int(dut.pwl_y.value)
            # bbar via mul path
            dut.mula.value = int(delta[c]) & 0xFF
            dut.mulb.value = int(B[n]) & 0xFF
            dut.mshift.value = rm.S_DB
            await Timer(1, "ns")
            bbar = int(dut.mul_out.value)
            # h update
            dut.abar.value = abar
            dut.h_in.value = int(h_prev[c][n]) & 0xFF
            dut.bbar.value = bbar
            dut.u_in.value = int(u[c]) & 0xFF
            await Timer(1, "ns")
            got = s8(int(dut.h_new.value))
            assert got == int(h_want[c][n]), \
                f"h[{c}][{n}]: rtl={got} golden={int(h_want[c][n])}"
