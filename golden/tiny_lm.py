#!/usr/bin/env python3
"""tiny_lm — a deliberately trivial *trained* language model for the STELE
demo: an order-1 Markov (bigram) character model, trained by maximum
likelihood (counting) on a tiny corpus, embedded in the real quantised
architecture:

  - embedding table: one-hot rows (scaled to 96) for the 27-char alphabet
  - LM head: ternary bigram transition matrix (+1 at the trained successor)
  - both Mamba layers keep the seeded-random weights and execute fully
    (conv, scan, gate all run on real data); only W_out is zeroed, so the
    residual stream carries the token embedding through to the LM head and
    the learned bigram behaviour is exact.

Generation is greedy argmax, so the model deterministically reproduces its
training text — which is the point: the RTL must match it token for token.

Outputs: golden/tinylm_image.hex/.bin, golden/tinylm_meta.json.
"""

import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reference_model as rm  # noqa: E402

CORPUS = "fpga works"   # cyclic; every char has a unique successor
N_GEN = 20              # tokens to generate in the demo
ALPHABET = " abcdefghijklmnopqrstuvwxyz"


def tok(ch):
    return ALPHABET.index(ch)


def detok(t):
    return ALPHABET[t] if t < len(ALPHABET) else "?"


def train_bigram(corpus):
    """MLE bigram: count successors over the (cyclic) corpus, take argmax."""
    counts = np.zeros((rm.VOCAB, rm.VOCAB), dtype=np.int64)
    for i, ch in enumerate(corpus):
        counts[tok(corpus[(i + 1) % len(corpus)]), tok(ch)] += 1
    succ = {}
    for t in set(tok(c) for c in corpus):
        succ[t] = int(np.argmax(counts[:, t]))
    return succ


def build():
    rng = np.random.default_rng(rm.SEED)
    layers, _, _ = rm.gen_weights(rng)
    for wl in layers:
        wl["w_out"] = np.zeros_like(wl["w_out"])   # pass-through residual

    succ = train_bigram(CORPUS)

    embed = np.zeros((rm.VOCAB, rm.D_MODEL), dtype=np.int64)
    for t in range(min(rm.VOCAB, rm.D_MODEL)):
        embed[t, t] = 96                            # one-hot, scaled

    lm_head = np.zeros((rm.VOCAB, rm.D_MODEL), dtype=np.int64)
    for t, nxt in succ.items():
        lm_head[nxt, t] = 1                         # ternary +1 at successor

    return layers, lm_head, embed, succ


def generate(layers, lm_head, embed, start_tok, n_gen):
    """Same loop as rm.generate but parametrised start/count."""
    h = [np.zeros((rm.D_INNER, rm.D_STATE), dtype=np.int64)
         for _ in range(rm.N_LAYERS)]
    ring = [np.zeros((rm.D_INNER, rm.D_CONV - 1), dtype=np.int64)
            for _ in range(rm.N_LAYERS)]
    tokens = [start_tok]
    for _ in range(n_gen):
        x = embed[tokens[-1]].copy()
        for l in range(rm.N_LAYERS):
            x = rm.block_forward(layers[l], x, h[l], ring[l])
        logits = lm_head @ x
        tokens.append(int(np.argmax(logits)))
    return tokens


def main():
    gold = os.path.dirname(os.path.abspath(__file__))
    layers, lm_head, embed, succ = build()

    img = rm.build_image(layers, lm_head, embed)
    img.tofile(os.path.join(gold, "tinylm_image.bin"))
    with open(os.path.join(gold, "tinylm_image.hex"), "w") as f:
        f.write("\n".join(format(b, "02x") for b in img) + "\n")

    start = tok(CORPUS[0])
    tokens = generate(layers, lm_head, embed, start, N_GEN)
    text = "".join(detok(t) for t in tokens)

    meta = {
        "corpus": CORPUS,
        "alphabet": ALPHABET,
        "bigram": {str(k): v for k, v in sorted(succ.items())},
        "start_token": start,
        "n_gen": N_GEN,
        "expected_tokens": tokens,
        "expected_text": text,
    }
    with open(os.path.join(gold, "tinylm_meta.json"), "w") as f:
        json.dump(meta, f, indent=1)

    print(f"corpus:   {CORPUS!r}")
    print(f"bigram:   {[f'{detok(int(k))}->{detok(v)}' for k, v in sorted(succ.items())]}")
    print(f"generated({N_GEN} from {detok(start)!r}): {text!r}")


if __name__ == "__main__":
    main()
