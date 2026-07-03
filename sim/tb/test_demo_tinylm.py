"""Demo: the tiny trained language model (bigram Markov, corpus-trained by
counting) running on the full STELE system in simulation — CSR boot over uio,
prompt token in, generated text out. Writes demo/logs/tinylm_generation.log.

Run with: make TEST=demo_tinylm  (loads golden/tinylm_image.hex via +IMAGE)
"""

import json
import os

import cocotb
from cocotb.triggers import RisingEdge

import stele_tb as h

HERE = os.path.dirname(__file__)
LOG = os.path.join(HERE, "../../demo/logs/tinylm_generation.log")
META = os.path.join(HERE, "../../golden/tinylm_meta.json")


@cocotb.test()
async def demo_tiny_language_model(dut):
    with open(META) as f:
        meta = json.load(f)
    alpha = meta["alphabet"]
    detok = lambda t: alpha[t] if t < len(alpha) else "?"

    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    log = open(LOG, "w")
    w = lambda s="": log.write(s + "\n")

    w("STELE — tiny trained language model on the full system (simulation)")
    w("=" * 68)
    w(f"model    : order-1 Markov (bigram), MLE-trained on corpus "
      f"{meta['corpus']!r}")
    w(f"           embedded in the quantised SSM pipeline (one-hot embedding,")
    w(f"           ternary bigram LM head; both Mamba layers execute fully,")
    w(f"           W_out=0 so the residual stream carries the token through)")
    w(f"bigram   : " + " ".join(f"{detok(int(k))!r}->{detok(v)!r}"
                                for k, v in meta["bigram"].items()))
    w()

    await h.reset(dut)

    stream = h.csr_stream({16: meta["n_gen"]})   # N_TOK
    w(f"boot     : cfg_mode=1, streamed {len(stream)} CSR bytes over uio:")
    for i in range(0, 64, 16):
        w("           " + " ".join(f"{b:02x}" for b in stream[i:i + 16]))
    await h.boot(dut, stream)

    start = meta["start_token"]
    w(f"input    : host_drive+in_valid, prompt token {start} "
      f"({detok(start)!r}) on uio")
    await h.start(dut, start)

    w(f"running  : {meta['n_gen']} tokens, autoregressive "
      f"(embedding -> 2 layers -> LM head argmax per token)...")
    tokens, cyc = await h.run_until_halt(dut, 40_000_000)
    text = detok(start) + "".join(detok(t) for t in tokens)

    w()
    w(f"output   : {len(tokens)} tokens in {cyc} clk cycles "
      f"({cyc // max(len(tokens), 1)} cycles/token)")
    for i, t in enumerate(tokens):
        w(f"  token[{i:2d}] uio=0x{t:02x} ({t:3d}) -> {detok(t)!r}")
    w()
    w(f"prompt + generated text : {text!r}")
    w(f"reference (numpy)       : {meta['expected_text']!r}")

    ok_tokens = tokens == meta["expected_tokens"][1:]
    tcsm = int(dut.hram.err_count.value)
    w()
    w(f"bit-exact vs trained reference : {'PASS' if ok_tokens else 'FAIL'}")
    w(f"tCSM violations                : {tcsm}")
    log.close()

    assert ok_tokens, f"{tokens} != {meta['expected_tokens'][1:]}"
    assert tcsm == 0
