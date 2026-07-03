"""Demo: the seeded-random verification model, full 8-token generation with a
reviewable I/O log (demo/logs/random_model_generation.log). Same run as the
milestone-7 test but narrated: boot bytes, prompt, per-token output, state
digests, golden comparison."""

import os

import cocotb
import numpy as np

import reference_model as rm
import stele_tb as h

LOG = os.path.join(os.path.dirname(__file__),
                   "../../demo/logs/random_model_generation.log")


@cocotb.test()
async def demo_random_model_generation(dut):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    log = open(LOG, "w")
    w = lambda s="": log.write(s + "\n")

    w("STELE — seeded-random verification model, full generation (simulation)")
    w("=" * 70)
    w(f"model    : ternary/int8 selective SSM, weights seeded-random "
      f"(seed 0x{rm.SEED:X})")
    w(f"config   : D_MODEL={rm.D_MODEL} N_LAYERS={rm.N_LAYERS} "
      f"D_STATE={rm.D_STATE} D_INNER={rm.D_INNER} VOCAB={rm.VOCAB}")
    w(f"memory   : weights {rm.WEIGHTS_BASE:#x}.. state {rm.STATE_BASE:#x}.. "
      f"scratch {rm.SCRATCH_BASE:#x}.. (all in HyperRAM)")
    w()

    await h.reset(dut)
    stream = h.csr_stream()
    w(f"boot     : {len(stream)} CSR bytes over uio (cfg_mode=1):")
    for i in range(0, 64, 16):
        w("           " + " ".join(f"{b:02x}" for b in stream[i:i + 16]))
    await h.boot(dut, stream)

    w(f"input    : prompt token {rm.BOS} (BOS) via host_drive/in_valid")
    await h.start(dut, rm.BOS)
    tokens, cyc = await h.run_until_halt(dut, 30_000_000)

    t = np.load(os.path.join(os.path.dirname(__file__),
                             "../../golden/trace.npz"))
    exp = [int(v) for v in t["tokens"][1:]]

    w()
    w(f"output   : {len(tokens)} tokens in {cyc} clk cycles")
    w(f"  {'step':>4} {'rtl':>5} {'golden':>7}  match")
    for i, (got, want) in enumerate(zip(tokens, exp)):
        w(f"  {i:>4} {got:>5} {want:>7}  {'ok' if got == want else 'MISMATCH'}")
    w()

    # post-run state digests read back from the HyperRAM model
    for l in range(rm.N_LAYERS):
        hm = h.as_i8(h.read_mem(dut, rm.STATE_BASE + l * rm.ST_STRIDE,
                                rm.D_INNER * rm.D_STATE))
        ok = np.array_equal(hm.reshape(rm.D_INNER, rm.D_STATE),
                            t["h_final"][l])
        w(f"state    : layer {l} final h  [c0] = "
          + " ".join(f"{v:4d}" for v in hm[:16])
          + f"   golden match: {'ok' if ok else 'MISMATCH'}")
    sc = h.as_i8(h.read_mem(dut, rm.SCRATCH_BASE + rm.SC_X, 16))
    w(f"scratch  : final residual x[0:16] = "
      + " ".join(f"{v:4d}" for v in sc))

    ok = tokens == exp
    w()
    w(f"bit-exact vs golden trace : {'PASS' if ok else 'FAIL'}")
    w(f"tCSM violations           : {int(dut.hram.err_count.value)}")
    log.close()
    assert ok
    assert int(dut.hram.err_count.value) == 0
