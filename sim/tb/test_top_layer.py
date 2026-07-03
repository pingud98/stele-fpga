"""Milestone 6: one full Mamba block end-to-end on the TT top, state streamed
through the behavioural HyperRAM, bit-exact against the golden trace
(step 0, layer 0). Runs with N_LAYERS=1, N_TOK=1 via the CSR boot stream, so
the boot path is exercised too."""

import numpy as np

import cocotb

import reference_model as rm
import stele_tb as h


@cocotb.test()
async def test_single_layer_bitexact(dut):
    await h.reset(dut)
    await h.boot(dut, h.csr_stream({4: 1, 16: 1}))  # N_LAYERS=1, N_TOK=1
    await h.start(dut, rm.BOS)
    tokens, cyc = await h.run_until_halt(dut, 3_000_000)
    dut._log.info(f"single layer + LM head in {cyc} cycles, tokens={tokens}")

    t = np.load("../../golden/trace.npz")
    sb = rm.SCRATCH_BASE
    stb = rm.STATE_BASE

    def scratch(off, n):
        return h.as_i8(h.read_mem(dut, sb + off, n))

    # embedding landed in scratch x?? x is overwritten by RES_ADD; compare
    # the final layer-0 outputs instead, phase by phase:
    exp = {k: t[k][0][0] for k in
           ("x1", "z", "u", "dbc", "delta", "h", "y_gate", "res", "x_out")}

    np.testing.assert_array_equal(scratch(rm.SC_X1, 128), exp["x1"], "x1")
    np.testing.assert_array_equal(scratch(rm.SC_Z, 128), exp["z"], "z")
    np.testing.assert_array_equal(scratch(rm.SC_U, 128), exp["u"], "u")
    np.testing.assert_array_equal(scratch(rm.SC_DBC, 36), exp["dbc"], "dbc")
    delta = h.read_mem(dut, sb + rm.SC_DT, 128).astype(np.int64)  # unsigned
    np.testing.assert_array_equal(delta, exp["delta"], "delta")
    np.testing.assert_array_equal(scratch(rm.SC_Y, 128), exp["y_gate"], "y_gate")
    np.testing.assert_array_equal(scratch(rm.SC_RES, 64), exp["res"], "res")
    np.testing.assert_array_equal(scratch(rm.SC_X, 64), exp["x_out"], "x_out")

    hmem = h.as_i8(h.read_mem(dut, stb, 128 * 16)).reshape(128, 16)
    np.testing.assert_array_equal(hmem, exp["h"], "h state")

    # ring after one step: [0, 0, x1[c]]
    ring = h.as_i8(h.read_mem(dut, stb + rm.ST_RING, 128 * 4)).reshape(128, 4)
    np.testing.assert_array_equal(ring[:, 0], np.zeros(128), "ring[0]")
    np.testing.assert_array_equal(ring[:, 1], np.zeros(128), "ring[1]")
    np.testing.assert_array_equal(ring[:, 2], exp["x1"], "ring[2]")

    # emitted token: argmax of LM head over the layer-0 output
    rng = np.random.default_rng(rm.SEED)
    _, lm_head, _ = rm.gen_weights(rng)
    logits = lm_head @ exp["x_out"]
    assert tokens == [int(np.argmax(logits))], \
        f"token {tokens} != argmax {int(np.argmax(logits))}"
    assert int(dut.hram.err_count.value) == 0, "tCSM violation"
