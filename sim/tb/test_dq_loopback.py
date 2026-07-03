"""Milestone 1: SB_IO-style registered bidir DQ loopback (generic sim build).

Contract of hyperbus_dq_io (both builds): dout/oe are registered to the pad
(1 clk), pad is registered to din (1 clk). All stimulus changes at rising
edges; all checks at falling edges (stable, and writes stay legal).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge


async def start_clk(dut):
    cocotb.start_soon(Clock(dut.clk, 20, "ns").start())
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_drive_path(dut):
    """oe=1: dout appears on pad one clk later."""
    await start_clk(dut)
    dut.ext_oe.value = 0
    dut.oe.value = 1
    for val in (0x00, 0xA5, 0xFF, 0x3C):
        dut.dout.value = val
        await RisingEdge(dut.clk)   # dout_q <= dout
        await FallingEdge(dut.clk)
        assert int(dut.pad.value) == val, f"pad={dut.pad.value} want {val:#x}"


@cocotb.test()
async def test_tristate(dut):
    """oe=0: pad released to high-Z one clk later."""
    await start_clk(dut)
    dut.ext_oe.value = 0
    dut.oe.value = 1
    dut.dout.value = 0x55
    await RisingEdge(dut.clk)
    dut.oe.value = 0
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert str(dut.pad.value).lower() == "z" * 8, f"pad={dut.pad.value}"


@cocotb.test()
async def test_receive_path(dut):
    """oe=0 and external drive: value lands in din one clk after the pad."""
    await start_clk(dut)
    dut.oe.value = 0
    dut.ext_oe.value = 1
    for val in (0x11, 0xEE, 0x80, 0x7F):
        dut.ext_drive.value = val
        await RisingEdge(dut.clk)   # pad settles to val; din_q samples old pad
        await RisingEdge(dut.clk)   # din_q <= val
        await FallingEdge(dut.clk)
        assert int(dut.din.value) == val, f"din={dut.din.value} want {val:#x}"


@cocotb.test()
async def test_oe_turnaround_stream(dut):
    """Alternate drive and receive with OE toggling (the pattern the PHY uses
    at CA->read turnaround). Exactly one driver at any time."""
    await start_clk(dut)
    for i in range(8):
        drive_val = (0x10 + i) & 0xFF
        recv_val = (0xE0 + i) & 0xFF
        # drive phase
        dut.ext_oe.value = 0
        dut.oe.value = 1
        dut.dout.value = drive_val
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        assert int(dut.pad.value) == drive_val
        # turnaround to receive
        dut.oe.value = 0
        await RisingEdge(dut.clk)      # oe_q clears; pad released
        dut.ext_oe.value = 1
        dut.ext_drive.value = recv_val
        await RisingEdge(dut.clk)      # pad = recv_val
        await RisingEdge(dut.clk)      # din_q <= recv_val
        await FallingEdge(dut.clk)
        assert int(dut.din.value) == recv_val, f"i={i} din={dut.din.value}"
        dut.ext_oe.value = 0
        await RisingEdge(dut.clk)
