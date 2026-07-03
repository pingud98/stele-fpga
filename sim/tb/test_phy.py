"""HyperBus PHY vs behavioural model: milestones 2 (register read),
3 (single-word write -> read-back), 4 (bursts within tCSM, splitting)."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge


CLK_NS = 20  # 50 MHz internal clk -> CK = 12.5 MHz


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, "ns").start())
    dut.rst_n.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def issue(dut, write, reg, addr, length):
    while not dut.cmd_ready.value:
        await RisingEdge(dut.clk)
    dut.cmd_write.value = write
    dut.cmd_reg.value = reg
    dut.cmd_addr.value = addr
    dut.cmd_len.value = length
    dut.cmd_valid.value = 1
    await RisingEdge(dut.clk)
    dut.cmd_valid.value = 0


async def run_read(dut, addr, words, reg=False, timeout=200000):
    """Issue a read and collect 2*words bytes; returns byte list."""
    data = []
    await issue(dut, 0, int(reg), addr, words)
    for _ in range(timeout):
        await FallingEdge(dut.clk)
        if dut.rd_valid.value:
            data.append(int(dut.rd_data.value))
        if dut.done.value:
            break
    else:
        raise TimeoutError("read never completed")
    assert len(data) == 2 * words, f"got {len(data)} bytes, want {2*words}"
    return data


async def run_write(dut, addr, payload, reg=False, timeout=200000):
    """Issue a write of len(payload)//2 words, feeding bytes on wr_ready."""
    idx = 0
    dut.wr_data.value = payload[0]
    await issue(dut, 1, int(reg), addr, len(payload) // 2)
    for _ in range(timeout):
        await FallingEdge(dut.clk)
        if dut.wr_ready.value:
            # byte is consumed at the posedge that ends this cycle; only
            # advance the stream after that edge has passed
            await RisingEdge(dut.clk)
            idx += 1
            dut.wr_data.value = payload[idx] if idx < len(payload) else 0
        if dut.done.value:
            break
    else:
        raise TimeoutError("write never completed")
    assert idx == len(payload), f"consumed {idx} bytes, want {len(payload)}"


# ---------------------------------------------------------------- milestone 2
@cocotb.test()
async def test_m2_id_register_read(dut):
    """Config-register read: ID0 must return 0x0c81."""
    await setup(dut)
    data = await run_read(dut, 0x0, 1, reg=True)
    word = (data[0] << 8) | data[1]
    assert word == 0x0C81, f"ID0 = {word:#06x}"
    assert int(dut.hram.err_count.value) == 0


@cocotb.test()
async def test_m2_id_read_2x_latency(dut):
    """Same read with RWDS-high (2x latency) — sampled-RWDS path."""
    await setup(dut)
    dut.hram.cfg_extra_latency.value = 1
    data = await run_read(dut, 0x0, 1, reg=True)
    dut.hram.cfg_extra_latency.value = 0
    word = (data[0] << 8) | data[1]
    assert word == 0x0C81, f"ID0 with 2x latency = {word:#06x}"
    assert int(dut.hram.err_count.value) == 0


@cocotb.test()
async def test_m2_cr0_write_readback(dut):
    """Zero-latency register write (CR0), then read it back."""
    await setup(dut)
    await run_write(dut, 0x800, [0x12, 0x34], reg=True)
    assert int(dut.hram.cr0.value) == 0x1234
    data = await run_read(dut, 0x800, 1, reg=True)
    assert (data[0] << 8) | data[1] == 0x1234


# ---------------------------------------------------------------- milestone 3
@cocotb.test()
async def test_m3_single_word_write_readback(dut):
    """Single memory word write -> read-back (DQ turnaround + latency)."""
    await setup(dut)
    await run_write(dut, 0x100, [0xDE, 0xAD])
    assert int(dut.hram.mem[0x200].value) == 0xDE
    assert int(dut.hram.mem[0x201].value) == 0xAD
    data = await run_read(dut, 0x100, 1)
    assert data == [0xDE, 0xAD], f"read back {[hex(b) for b in data]}"
    assert int(dut.hram.err_count.value) == 0


@cocotb.test()
async def test_m3_write_readback_2x_latency(dut):
    """Write and read back with the 2x-latency indication active."""
    await setup(dut)
    dut.hram.cfg_extra_latency.value = 1
    await run_write(dut, 0x180, [0xCA, 0xFE])
    data = await run_read(dut, 0x180, 1)
    dut.hram.cfg_extra_latency.value = 0
    assert data == [0xCA, 0xFE]
    assert int(dut.hram.err_count.value) == 0


# ---------------------------------------------------------------- milestone 4
@cocotb.test()
async def test_m4_burst_within_tcsm(dut):
    """Burst of max_burst words in one transaction; no tCSM violation."""
    await setup(dut)
    random.seed(4)
    payload = [random.randrange(256) for _ in range(32)]  # 16 words
    await run_write(dut, 0x400, payload)
    data = await run_read(dut, 0x400, 16)
    assert data == payload
    assert int(dut.hram.err_count.value) == 0


@cocotb.test()
async def test_m4_long_transfer_splits(dut):
    """64-word transfer with max_burst=16 must split into 4 transactions
    (watch CS# rise between chunks) and stay tCSM-clean."""
    await setup(dut)
    random.seed(5)
    payload = [random.randrange(256) for _ in range(128)]  # 64 words

    rises = [0]

    async def count_cs_rises():
        while True:
            await RisingEdge(dut.hb_csn)
            rises[0] += 1

    watcher = cocotb.start_soon(count_cs_rises())
    await run_write(dut, 0x1000, payload)
    writes_rises = rises[0]
    data = await run_read(dut, 0x1000, 64)
    watcher.kill()
    assert data == payload
    assert writes_rises == 4, f"write split into {writes_rises} transactions"
    assert rises[0] == 8, f"total transactions {rises[0]}"
    assert int(dut.hram.err_count.value) == 0


@cocotb.test()
async def test_m4_unsplit_long_burst_violates_tcsm(dut):
    """Negative control: with the burst guard maxed out, a long single
    transaction must trip the model's tCSM assertion — proving the check
    is live and the splitting above is what protects us."""
    await setup(dut)
    dut.cfg_max_burst.value = 255
    payload = [i & 0xFF for i in range(256)]  # 128 words, one transaction
    await run_write(dut, 0x2000, payload)
    assert int(dut.hram.err_count.value) > 0, "tCSM checker never fired"
    dut.cfg_max_burst.value = 16


@cocotb.test()
async def test_m4_image_load_spotcheck(dut):
    """Read the golden HyperRAM image through the PHY and compare bytes."""
    import os
    import numpy as np
    await setup(dut)
    img = np.fromfile(os.path.join(os.path.dirname(__file__),
                                   "../../golden/hyperram_image.bin"),
                      dtype=np.uint8)
    # preload model memory directly (image load path itself is exercised in
    # stage 5 via the IMAGE_FILE parameter)
    for i in range(64):
        dut.hram.mem[i].value = int(img[i])
    data = await run_read(dut, 0x0, 32)
    assert data == list(img[:64]), "image spot-check mismatch"
