// PHY <-> behavioural HyperRAM harness (milestones 2-4).
// Mirrors the TT top's I/O registering: the PHY sees dq_in one clk behind
// the pad, exactly as the core will via its uio_in input register.
`timescale 1ns/1ps

module tb_phy;
    reg         clk = 0;
    reg         rst_n = 0;

    reg  [3:0]  cfg_latency = 4'd6;
    reg  [7:0]  cfg_max_burst = 8'd16;
    reg  [2:0]  cfg_capture = 3'd1;

    reg         cmd_valid = 0;
    wire        cmd_ready;
    reg         cmd_write = 0;
    reg         cmd_reg = 0;
    reg  [31:0] cmd_addr = 0;
    reg  [15:0] cmd_len = 0;

    reg  [7:0]  wr_data = 0;
    wire        wr_ready;
    wire [7:0]  rd_data;
    wire        rd_valid;
    wire        done;

    wire        hb_ck, hb_csn;
    wire [7:0]  phy_dq_out;
    wire        phy_dq_oe;

    // shared DQ bus: PHY drives when oe, model drives during reads
    wire [7:0]  dq = phy_dq_oe ? phy_dq_out : 8'hzz;
    wire        rwds;

    // input registers (as in the TT top)
    reg  [7:0]  dq_in_q = 0;
    always @(posedge clk) dq_in_q <= dq;

    hyperbus_phy phy (
        .clk(clk), .rst_n(rst_n),
        .cfg_latency(cfg_latency), .cfg_max_burst(cfg_max_burst),
        .cfg_capture(cfg_capture),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_write(cmd_write), .cmd_reg(cmd_reg),
        .cmd_addr(cmd_addr), .cmd_len(cmd_len),
        .wr_data(wr_data), .wr_ready(wr_ready),
        .rd_data(rd_data), .rd_valid(rd_valid), .done(done),
        .hb_ck(hb_ck), .hb_csn(hb_csn),
        .dq_out(phy_dq_out), .dq_oe(phy_dq_oe),
        .dq_in(dq_in_q), .rwds_in(rwds)
    );

    hyperram_model #(.LATENCY(6)) hram (
        .ck(hb_ck), .csn(hb_csn), .dq(dq), .rwds(rwds)
    );
endmodule
