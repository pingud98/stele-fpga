"""Shared host-side helpers for the full-system testbench (tb_top)."""

import numpy as np

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

import reference_model as rm

CLK_NS = 20


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, "ns").start())
    dut.rst_n.value = 0
    dut.host_drive.value = 0
    dut.in_valid.value = 0
    dut.cfg_mode.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)


def csr_stream(overrides=None):
    """64-byte boot stream from golden defaults; overrides keyed by CSR index."""
    regs = dict(rm.CSR_DEFAULTS)
    regs.update(overrides or {})
    out = []
    for idx in range(32):
        v = regs.get(idx, 0)
        out += [(v >> 8) & 0xFF, v & 0xFF]
    return out


async def boot(dut, stream):
    """Stream CSR bytes over uio with cfg_mode high, one in_valid pulse per
    byte (uio_in is registered in the top, so hold data one extra cycle)."""
    dut.cfg_mode.value = 1
    dut.host_drive.value = 1
    for b in stream:
        dut.host_data.value = b
        await RisingEdge(dut.clk)   # data lands in uio_in_q
        dut.in_valid.value = 1
        await RisingEdge(dut.clk)
        dut.in_valid.value = 0
        await RisingEdge(dut.clk)
    dut.cfg_mode.value = 0
    dut.host_drive.value = 0
    await RisingEdge(dut.clk)


async def start(dut, token):
    """Present the start token and wait for busy."""
    dut.host_drive.value = 1
    dut.host_data.value = token
    await RisingEdge(dut.clk)       # into uio_in_q
    dut.in_valid.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.in_valid.value = 0
    dut.host_drive.value = 0        # release the bus (core waits for this)
    await RisingEdge(dut.clk)
    assert int(dut.uo_out.value) & 0x10, "busy did not rise"


async def run_until_halt(dut, max_cycles, collect_tokens=True):
    """Wait for busy to fall; collect tokens on out_valid rising edges."""
    tokens = []
    prev_ov = 0
    for cyc in range(max_cycles):
        await FallingEdge(dut.clk)
        uo = int(dut.uo_out.value)
        ov = (uo >> 2) & 1
        if ov and not prev_ov and collect_tokens:
            tokens.append(int(dut.uio_out.value))
        prev_ov = ov
        if not (uo >> 4) & 1:   # busy fell
            return tokens, cyc
    raise TimeoutError(f"core still busy after {max_cycles} cycles")


def read_mem(dut, base, length):
    return np.array([int(dut.hram.mem[base + k].value) for k in range(length)],
                    dtype=np.uint8)


def as_i8(a):
    return a.astype(np.int8).astype(np.int64)
