"""Milestone 7: full per-token generation — all layers + LM head + embedding
lookup, 8 tokens, bit-exact against golden/trace.npz (tokens, final SSM state,
final conv ring buffers)."""

import numpy as np

import cocotb

import reference_model as rm
import stele_tb as h


@cocotb.test()
async def test_full_generation_bitexact(dut):
    await h.reset(dut)
    await h.boot(dut, h.csr_stream())          # golden defaults, 2 layers, 8 tokens
    await h.start(dut, rm.BOS)
    tokens, cyc = await h.run_until_halt(dut, 30_000_000)
    dut._log.info(f"generated {len(tokens)} tokens in {cyc} cycles: {tokens}")

    t = np.load("../../golden/trace.npz")
    exp_tokens = [int(v) for v in t["tokens"][1:]]
    assert tokens == exp_tokens, f"tokens {tokens} != golden {exp_tokens}"

    # final SSM state, both layers
    for l in range(rm.N_LAYERS):
        hmem = h.as_i8(h.read_mem(dut, rm.STATE_BASE + l * rm.ST_STRIDE,
                                  rm.D_INNER * rm.D_STATE)).reshape(
                                      rm.D_INNER, rm.D_STATE)
        np.testing.assert_array_equal(hmem, t["h_final"][l], f"h layer {l}")

    # final ring buffers (RTL rows are [w0,w1,w2,pad])
    for l in range(rm.N_LAYERS):
        ring = h.as_i8(h.read_mem(dut, rm.STATE_BASE + l * rm.ST_STRIDE
                                  + rm.ST_RING, rm.D_INNER * 4)).reshape(
                                      rm.D_INNER, 4)
        np.testing.assert_array_equal(ring[:, :3], t["ring_final"][l],
                                      f"ring layer {l}")

    assert int(dut.hram.err_count.value) == 0, "tCSM violation during run"
