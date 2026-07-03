// tt_um_stele_ssm — Tiny Tapeout compatible top (spec §5 pin map).
//
//   uio[7:0]  : HyperRAM DQ when CS# low; token byte when CS# high
//   uo[0] CK, uo[1] CS#, uo[2] out_valid, uo[3] in_req, uo[4] busy,
//   uo[7:5] fsm_dbg
//   ui[0] RWDS, ui[1] host_drive, ui[2] in_valid, ui[3] cfg_mode
//
// All design logic sits behind this boundary; the icebreaker wrapper only
// maps these ports to SB_IO pads.
`default_nettype none

module tt_um_stele_ssm (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    wire rwds       = ui_in[0];
    wire host_drive = ui_in[1];
    wire in_valid   = ui_in[2];
    wire cfg_mode   = ui_in[3];

    // registered input path for DQ (the PHY's fixed capture offset counts
    // from this register, identically on FPGA and TT)
    reg [7:0] uio_in_q;
    always @(posedge clk) uio_in_q <= uio_in;

    // CSRs
    wire        boot_done;
    wire [3:0]  latency;
    wire [7:0]  max_burst;
    wire [2:0]  capture;
    wire [15:0] d_model, n_layers, d_inner, d_state, dt_rank, vocab;
    wire [31:0] weights_base, state_base, scratch_base;
    wire [15:0] n_tok, l_stride, st_stride;
    wire [15:0] off_conv, off_wx, off_wdt, off_a, off_wout;
    wire [15:0] off_lmhead, off_embed, ring_off;

    csr u_csr (
        .clk(clk), .rst_n(rst_n),
        .cfg_mode(cfg_mode), .in_valid(in_valid), .boot_byte(uio_in_q),
        .boot_done(boot_done),
        .latency(latency), .max_burst(max_burst), .capture(capture),
        .d_model(d_model), .n_layers(n_layers), .d_inner(d_inner),
        .d_state(d_state), .dt_rank(dt_rank), .vocab(vocab),
        .weights_base(weights_base), .state_base(state_base),
        .scratch_base(scratch_base), .n_tok(n_tok),
        .l_stride(l_stride), .st_stride(st_stride),
        .off_conv(off_conv), .off_wx(off_wx), .off_wdt(off_wdt),
        .off_a(off_a), .off_wout(off_wout), .off_lmhead(off_lmhead),
        .off_embed(off_embed), .ring_off(ring_off)
    );

    // core
    wire [7:0] token_out;
    wire       out_valid, in_req, busy;
    wire [2:0] fsm_dbg;
    wire       hb_ck, hb_csn;
    wire [7:0] dq_out;
    wire       dq_oe;

    sequencer u_seq (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .host_drive(host_drive), .cfg_mode(cfg_mode),
        .token_in(uio_in_q),
        .token_out(token_out), .out_valid(out_valid), .in_req(in_req),
        .busy(busy), .fsm_dbg(fsm_dbg),
        .latency(latency), .max_burst(max_burst), .capture(capture),
        .d_model(d_model), .n_layers(n_layers), .d_inner(d_inner),
        .d_state(d_state), .dt_rank(dt_rank), .vocab(vocab),
        .weights_base(weights_base), .state_base(state_base),
        .scratch_base(scratch_base), .n_tok(n_tok),
        .l_stride(l_stride), .st_stride(st_stride),
        .off_conv(off_conv), .off_wx(off_wx), .off_wdt(off_wdt),
        .off_a(off_a), .off_wout(off_wout), .off_lmhead(off_lmhead),
        .off_embed(off_embed), .ring_off(ring_off),
        .hb_ck(hb_ck), .hb_csn(hb_csn),
        .dq_out(dq_out), .dq_oe(dq_oe),
        .dq_in(uio_in_q), .rwds_in(rwds)
    );

    // uio sharing rule (spec §5): CS# low -> DQ; CS# high -> token lane.
    // host_drive forces the core off the bus unconditionally.
    wire drive = !host_drive && (dq_oe || (hb_csn && out_valid));
    assign uio_out = hb_csn ? token_out : dq_out;
    assign uio_oe  = {8{drive}};

    assign uo_out = {fsm_dbg, busy, in_req, out_valid, hb_csn, hb_ck};

    wire _unused = &{1'b0, ena, ui_in[7:4], boot_done};

endmodule

`default_nettype wire
