"""Demo: sample HyperBus PHY operations with a human-readable I/O log.
Writes demo/logs/phy_ops.log. Reuses the tb_phy harness and the proven
run_read/run_write drivers from test_phy."""

import os
import random

import cocotb

from test_phy import setup, run_read, run_write

LOG = os.path.join(os.path.dirname(__file__), "../../demo/logs/phy_ops.log")


class Log:
    def __init__(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.f = open(path, "w")

    def w(self, line=""):
        self.f.write(line + "\n")

    def op(self, title):
        self.w()
        self.w("-" * 64)
        self.w(title)
        self.w("-" * 64)


def hx(data):
    return " ".join(f"{b:02x}" for b in data)


@cocotb.test()
async def demo_phy_operations(dut):
    log = Log(LOG)
    log.w("STELE HyperBus PHY — sample operations (simulation)")
    log.w("PHY <-> behavioural HyperRAM model; clk 50 MHz, CK 12.5 MHz,")
    log.w("latency 6 CK, capture offset 2 clk, max burst 16 words")
    await setup(dut)

    log.op("OP 1: ID register read (AS=1, word addr 0x000)")
    data = await run_read(dut, 0x0, 1, reg=True)
    log.w(f"  request : READ  reg[0x000], 1 word")
    log.w(f"  response: {hx(data)}  (ID0 = 0x{data[0]:02x}{data[1]:02x})")
    assert (data[0] << 8) | data[1] == 0x0C81

    log.op("OP 2: ID register read with 2x latency (RWDS high during CA)")
    dut.hram.cfg_extra_latency.value = 1
    data = await run_read(dut, 0x0, 1, reg=True)
    dut.hram.cfg_extra_latency.value = 0
    log.w(f"  request : READ  reg[0x000], 1 word, device signals 2x latency")
    log.w(f"  response: {hx(data)}  (sampled-RWDS path)")
    assert (data[0] << 8) | data[1] == 0x0C81

    log.op("OP 3: CR0 register write (zero latency) + readback")
    log.w(f"  request : WRITE reg[0x800] <= ab cd")
    await run_write(dut, 0x800, [0xAB, 0xCD], reg=True)
    data = await run_read(dut, 0x800, 1, reg=True)
    log.w(f"  readback: {hx(data)}")
    assert data == [0xAB, 0xCD]

    log.op("OP 4: single memory word write -> read-back (DQ turnaround)")
    log.w(f"  request : WRITE mem[word 0x100] <= de ad")
    await run_write(dut, 0x100, [0xDE, 0xAD])
    data = await run_read(dut, 0x100, 1)
    log.w(f"  readback: {hx(data)}")
    assert data == [0xDE, 0xAD]

    log.op("OP 5: 16-word burst write -> burst read (one transaction each)")
    random.seed(0xD5)
    payload = [random.randrange(256) for _ in range(32)]
    log.w(f"  write   : mem[word 0x400..0x40f] <=")
    log.w(f"            {hx(payload[:16])}")
    log.w(f"            {hx(payload[16:])}")
    await run_write(dut, 0x400, payload)
    data = await run_read(dut, 0x400, 16)
    log.w(f"  readback: {hx(data[:16])}")
    log.w(f"            {hx(data[16:])}")
    assert data == payload

    log.op("OP 6: 64-word transfer, auto-split for tCSM (max_burst=16)")
    from cocotb.triggers import RisingEdge
    payload = [(3 * i + 1) & 0xFF for i in range(128)]
    rises = [0]

    async def count():
        while True:
            await RisingEdge(dut.hb_csn)
            rises[0] += 1
    task = cocotb.start_soon(count())
    await run_write(dut, 0x1000, payload)
    wr_txn = rises[0]
    data = await run_read(dut, 0x1000, 64)
    task.kill()
    log.w(f"  write   : 64 words -> {wr_txn} HyperBus transactions (CA re-issued)")
    log.w(f"  read    : 64 words -> {rises[0] - wr_txn} transactions")
    log.w(f"  data ok : {data == payload}; tCSM violations: "
          f"{int(dut.hram.err_count.value)}")
    assert data == payload
    assert int(dut.hram.err_count.value) == 0

    log.w()
    log.w("all PHY sample operations completed OK")
    log.f.close()
