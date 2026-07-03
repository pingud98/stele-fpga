#!/usr/bin/env python3
"""STELE golden reference: bit-exact fixed-point ternary/int8 selective-SSM
forward pass (numpy only). Generates, deterministically from a fixed seed:

  golden/hyperram_image.bin / .hex  -- weights+state+scratch memory image
  golden/trace.npz                  -- per-phase intermediates + logits/tokens
  golden/csr_config.hex             -- CSR boot stream (32 x 16-bit regs)
  golden/params.json                -- dims/shifts/offsets for cocotb tests
  rtl/pwl_tables.vh                 -- shared PWL segment tables

The weights are seeded-random (runbook §4): bit-exact RTL verification does
not require a *trained* model. All arithmetic below is integer and must be
mirrored exactly by the RTL:
  rshift_round(v,s) = (v + 2^(s-1)) >> s   (arithmetic/floor shift)
  sat8(v)           = clamp(v, -128, 127)
"""

import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pwl  # noqa: E402

# ---------------------------------------------------------------- config
SEED = 0xC0FFEE

D_MODEL = 64
N_LAYERS = 2
D_STATE = 16          # N
D_CONV = 4
E = 2
D_INNER = E * D_MODEL  # 128
DT_RANK = 4
VOCAB = 128
N_TOK = 8             # tokens to generate
BOS = 1

# Requantisation shifts (fixed-point spec; baked into RTL as localparams)
S_IN = 3      # IN_PROJ acc -> int8
S_CONV = 1    # conv acc -> int8
S_XP = 2      # x_proj acc -> int8
S_DT = 1      # dt_proj acc -> int8
S_DB = 4      # (delta*B) -> int8 Bbar
S_SCAN = 7    # (Abar*h + Bbar*u) -> int8 h'
S_C = 6       # sum C*h -> int8 y
S_G = 5       # y*silu(z) -> int8
S_OUT = 3     # OUT_PROJ acc -> int8

# HyperRAM byte-address map
WEIGHTS_BASE = 0x00000
STATE_BASE = 0x40000
SCRATCH_BASE = 0x50000

# Weights region per-layer offsets (streaming order, spec §9)
SZ_WIN = 2 * D_INNER * D_MODEL // 4      # 4096
SZ_CONV = D_INNER * D_CONV // 4          # 128
SZ_WX = (DT_RANK + 2 * D_STATE) * D_INNER // 4   # 1152
SZ_WDT = D_INNER * DT_RANK // 4          # 128
SZ_A = D_INNER * D_STATE                 # 2048
SZ_WOUT = D_MODEL * D_INNER // 4         # 2048
OFF_WIN = 0
OFF_CONV = OFF_WIN + SZ_WIN
OFF_WX = OFF_CONV + SZ_CONV
OFF_WDT = OFF_WX + SZ_WX
OFF_A = OFF_WDT + SZ_WDT
OFF_WOUT = OFF_A + SZ_A
L_STRIDE = OFF_WOUT + SZ_WOUT            # 9600 bytes/layer
OFF_LMHEAD = N_LAYERS * L_STRIDE
SZ_LMHEAD = VOCAB * D_MODEL // 4         # 2048
OFF_EMBED = OFF_LMHEAD + SZ_LMHEAD
SZ_EMBED = VOCAB * D_MODEL               # 8192

# State region per-layer offsets
ST_H = 0
SZ_H = D_INNER * D_STATE                 # 2048
ST_RING = SZ_H
SZ_RING = D_INNER * (D_CONV - 1)         # 384
ST_STRIDE = SZ_H + SZ_RING               # 2432 bytes/layer

# Scratch byte offsets (from SCRATCH_BASE)
SC_X = 0        # residual stream x, D_MODEL
SC_X1 = 64      # pre-conv x', D_INNER
SC_Z = 192      # gate input z, D_INNER
SC_U = 320      # post-conv/silu u, D_INNER
SC_DBC = 448    # dt_rank+2N raw x_proj out (dtr|B|C), 36
SC_DT = 512     # delta (uint8 Q4.4), D_INNER
SC_Y = 640      # scan/gate output y, D_INNER
SC_RES = 832    # OUT_PROJ result before residual add, D_MODEL
SCRATCH_SIZE = 1024

MEM_BYTES = 1 << 20  # behavioural model memory size (1 MiB)


# ---------------------------------------------------------------- helpers
def rshift_round(v, s):
    """Round-to-nearest arithmetic right shift (matches RTL)."""
    return (v + (1 << (s - 1))) >> s


def sat8(v):
    return np.clip(v, -128, 127)


def pack_trits(w):
    """Pack ternary array (row-major, values in {-1,0,1}) 4 trits/byte.
    Encoding per trit: 00=0, 01=+1, 10=-1. Trit i of a byte in bits [2i+1:2i]."""
    flat = w.flatten()
    assert flat.size % 4 == 0
    enc = np.where(flat == 1, 1, np.where(flat == -1, 2, 0)).astype(np.uint8)
    enc = enc.reshape(-1, 4)
    return (enc[:, 0] | (enc[:, 1] << 2) | (enc[:, 2] << 4) | (enc[:, 3] << 6)).astype(np.uint8)


def pwl_vec(spec, x):
    return np.array([spec.eval(int(v)) for v in np.asarray(x).flatten()],
                    dtype=np.int64).reshape(np.shape(x))


# ---------------------------------------------------------------- weights
def gen_weights(rng):
    tern = lambda *shape: rng.choice(np.array([-1, 0, 0, 1], dtype=np.int64),
                                     size=shape)
    layers = []
    for _ in range(N_LAYERS):
        layers.append({
            "w_in": tern(2 * D_INNER, D_MODEL),
            "conv": tern(D_INNER, D_CONV),
            "w_x": tern(DT_RANK + 2 * D_STATE, D_INNER),
            "w_dt": tern(D_INNER, DT_RANK),
            "A": rng.integers(-32, -1, size=(D_INNER, D_STATE), dtype=np.int64),
            "w_out": tern(D_MODEL, D_INNER),
        })
    lm_head = tern(VOCAB, D_MODEL)
    embed = rng.integers(-96, 97, size=(VOCAB, D_MODEL), dtype=np.int64)
    return layers, lm_head, embed


# ---------------------------------------------------------------- forward
def tmac(w, x, shift):
    """Ternary matvec + requant: rows of w in {-1,0,1}, x int8."""
    acc = w @ x                       # int accumulate (int32 range)
    return sat8(rshift_round(acc, shift))


def block_forward(wl, x, h, ring, trace=None):
    """One Mamba block, quantised. Mutates h, ring. Returns new x."""
    # IN_PROJ
    xz = tmac(wl["w_in"], x, S_IN)
    x1, z = xz[:D_INNER], xz[D_INNER:]
    # CONV (depthwise causal, K=D_CONV, ring holds previous K-1 inputs oldest-first)
    win = np.concatenate([ring, x1.reshape(D_INNER, 1)], axis=1)  # [D_INNER,K]
    conv_acc = np.sum(wl["conv"] * win, axis=1)
    u = sat8(rshift_round(conv_acc, S_CONV))
    u = pwl_vec(pwl.SILU, u)
    ring[:, :-1] = win[:, 1:-1]
    ring[:, -1] = x1
    # SCAN_PREP
    dbc = tmac(wl["w_x"], u, S_XP)
    dtr, B, C = dbc[:DT_RANK], dbc[DT_RANK:DT_RANK + D_STATE], dbc[DT_RANK + D_STATE:]
    dtpre = tmac(wl["w_dt"], dtr, S_DT)
    delta = pwl_vec(pwl.SOFTPLUS, dtpre)          # uint8 Q4.4, per channel
    # SCAN
    y = np.zeros(D_INNER, dtype=np.int64)
    for c in range(D_INNER):
        dA = delta[c] * wl["A"][c]                # int16 Q8.8, <= 0
        abar = pwl_vec(pwl.EXP, dA)               # uint8 Q0.7
        bbar = sat8(rshift_round(delta[c] * B, S_DB))
        hc = sat8(rshift_round(abar * h[c] + bbar * u[c], S_SCAN))
        h[c] = hc
        y[c] = sat8(rshift_round(int(np.sum(C * hc)), S_C))
    # GATE
    g = pwl_vec(pwl.SILU, z)
    y_g = sat8(rshift_round(y * g, S_G))
    # OUT_PROJ + residual
    res = tmac(wl["w_out"], y_g, S_OUT)
    x_out = sat8(x + res)
    if trace is not None:
        trace.update(x1=x1.copy(), z=z.copy(), u=u.copy(), dbc=dbc.copy(),
                     delta=delta.copy(), h=h.copy(), y_scan=y.copy(),
                     y_gate=y_g.copy(), res=res.copy(), x_out=x_out.copy())
    return x_out


def generate(layers, lm_head, embed):
    """Autoregressive generation from BOS; returns tokens and full trace."""
    h = [np.zeros((D_INNER, D_STATE), dtype=np.int64) for _ in range(N_LAYERS)]
    ring = [np.zeros((D_INNER, D_CONV - 1), dtype=np.int64) for _ in range(N_LAYERS)]
    tokens = [BOS]
    steps = []
    for _ in range(N_TOK):
        x = embed[tokens[-1]].copy()
        ltr = []
        for l in range(N_LAYERS):
            tr = {}
            x = block_forward(layers[l], x, h[l], ring[l], tr)
            ltr.append(tr)
        logits = lm_head @ x                       # int32, no requant
        tok = int(np.argmax(logits))               # ties -> lowest index
        tokens.append(tok)
        steps.append({"x_in": embed[tokens[-2]].copy(), "layers": ltr,
                      "logits": logits.copy(), "token": tok})
    return tokens, steps, h, ring


# ---------------------------------------------------------------- float ref
def generate_float(layers, lm_head, embed):
    """Dequantised float model with the same weights, for sanity bounds only."""
    import math
    hs = [np.zeros((D_INNER, D_STATE)) for _ in range(N_LAYERS)]
    rings = [np.zeros((D_INNER, D_CONV - 1)) for _ in range(N_LAYERS)]
    silu = lambda v: v / (1.0 + np.exp(-v))
    tokens = [BOS]
    for _ in range(N_TOK):
        x = embed[tokens[-1]] / 8.0
        for l in range(N_LAYERS):
            wl = layers[l]
            xz = (wl["w_in"] @ x) / (1 << S_IN) * 8.0 / 8.0
            x1, z = xz[:D_INNER], xz[D_INNER:]
            win = np.concatenate([rings[l], x1.reshape(-1, 1)], axis=1)
            u = silu(np.sum(wl["conv"] * win, axis=1) / (1 << S_CONV))
            rings[l][:, :-1] = win[:, 1:-1]
            rings[l][:, -1] = x1
            dbc = (wl["w_x"] @ u) / (1 << S_XP) * 8.0
            dtr = dbc[:DT_RANK]
            B = dbc[DT_RANK:DT_RANK + D_STATE]
            C = dbc[DT_RANK + D_STATE:]
            dt = np.log1p(np.exp((wl["w_dt"] @ dtr) / (1 << S_DT)))
            y = np.zeros(D_INNER)
            for c in range(D_INNER):
                abar = np.exp(dt[c] * wl["A"][c] / 16.0)
                hc = abar * hs[l][c] + dt[c] * B / 16.0 * u[c]
                hs[l][c] = hc
                y[c] = np.sum(C * hc) / (1 << (S_C - S_DB - 3))
            y = y * silu(z)
            x = x + (wl["w_out"] @ y) / (1 << S_OUT) * 8.0 / 8.0
        logits = lm_head @ x
        tokens.append(int(np.argmax(logits)))
    return tokens


# ---------------------------------------------------------------- image
def build_image(layers, lm_head, embed):
    img = np.zeros(SCRATCH_BASE + SCRATCH_SIZE, dtype=np.uint8)
    for l, wl in enumerate(layers):
        base = WEIGHTS_BASE + l * L_STRIDE
        img[base + OFF_WIN:base + OFF_WIN + SZ_WIN] = pack_trits(wl["w_in"])
        img[base + OFF_CONV:base + OFF_CONV + SZ_CONV] = pack_trits(wl["conv"])
        img[base + OFF_WX:base + OFF_WX + SZ_WX] = pack_trits(wl["w_x"])
        img[base + OFF_WDT:base + OFF_WDT + SZ_WDT] = pack_trits(wl["w_dt"])
        img[base + OFF_A:base + OFF_A + SZ_A] = (wl["A"].flatten() & 0xFF).astype(np.uint8)
        img[base + OFF_WOUT:base + OFF_WOUT + SZ_WOUT] = pack_trits(wl["w_out"])
    img[WEIGHTS_BASE + OFF_LMHEAD:WEIGHTS_BASE + OFF_LMHEAD + SZ_LMHEAD] = pack_trits(lm_head)
    img[WEIGHTS_BASE + OFF_EMBED:WEIGHTS_BASE + OFF_EMBED + SZ_EMBED] = \
        (embed.flatten() & 0xFF).astype(np.uint8)
    # state + scratch regions already zero
    return img


# ---------------------------------------------------------------- CSRs
CSR_DEFAULTS = {
    0: 6,                       # LATENCY (initial latency, CK cycles)
    1: 16,                      # MAX_BURST (words per transaction)
    2: 1,                       # CLK_DIV (CK = clk/2)
    3: D_MODEL, 4: N_LAYERS, 5: D_INNER, 6: D_STATE, 7: D_CONV,
    8: DT_RANK, 9: VOCAB,
    10: WEIGHTS_BASE & 0xFFFF, 11: WEIGHTS_BASE >> 16,
    12: STATE_BASE & 0xFFFF, 13: STATE_BASE >> 16,
    14: SCRATCH_BASE & 0xFFFF, 15: SCRATCH_BASE >> 16,
    16: N_TOK, 17: BOS, 18: 0,  # PACKING=0 (2-bit/trit)
}


def csr_bytes():
    out = bytearray()
    for i in range(32):
        v = CSR_DEFAULTS.get(i, 0)
        out += bytes([v >> 8, v & 0xFF])
    return bytes(out)


# ---------------------------------------------------------------- main
def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    gold = os.path.join(root, "golden")
    rng = np.random.default_rng(SEED)
    layers, lm_head, embed = gen_weights(rng)

    pwl.emit_verilog_header(os.path.join(root, "rtl", "pwl_tables.vh"))

    img = build_image(layers, lm_head, embed)
    img.tofile(os.path.join(gold, "hyperram_image.bin"))
    with open(os.path.join(gold, "hyperram_image.hex"), "w") as f:
        f.write("\n".join(format(b, "02x") for b in img) + "\n")

    with open(os.path.join(gold, "csr_config.hex"), "w") as f:
        f.write("\n".join(format(b, "02x") for b in csr_bytes()) + "\n")

    tokens, steps, h, ring = generate(layers, lm_head, embed)
    tr = {"tokens": np.array(tokens, dtype=np.int64),
          "logits": np.stack([s["logits"] for s in steps]),
          "h_final": np.stack(h), "ring_final": np.stack(ring)}
    for key in ("x_in",):
        tr[key] = np.stack([s[key] for s in steps])
    for key in ("x1", "z", "u", "dbc", "delta", "h", "y_scan", "y_gate",
                "res", "x_out"):
        tr[key] = np.stack([[s["layers"][l][key] for l in range(N_LAYERS)]
                            for s in steps])
    np.savez(os.path.join(gold, "trace.npz"), **tr)

    params = {k: v for k, v in globals().items()
              if k.isupper() and isinstance(v, int)}
    params["CSR"] = {str(k): v for k, v in CSR_DEFAULTS.items()}
    with open(os.path.join(gold, "params.json"), "w") as f:
        json.dump(params, f, indent=1, sort_keys=True)

    print(f"tokens: {tokens}")
    print(f"image:  {len(img)} bytes; trace steps: {len(steps)}")


if __name__ == "__main__":
    main()
