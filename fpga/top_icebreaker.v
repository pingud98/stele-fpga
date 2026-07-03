// top_icebreaker — thin wrapper mapping the TT-compatible core to icebreaker
// pins. All design logic stays in tt_um_stele_ssm; this file only owns pads.
//
// DQ pads are inferred unregistered tri-states, matching the simulation
// testbench exactly, so the CSR capture-offset default (2) is valid on
// hardware at first light. rtl/hyperbus_dq_io.v (registered SB_IO) is the
// tested upgrade path if pad timing needs hardening later — it shifts the
// capture offset by one, which the CSR absorbs.
//
// Clock: 12 MHz board oscillator, no PLL (CK = 3 MHz — deliberately slow for
// first light; icepll can raise it once milestone 3 passes on hardware).
`default_nettype none

module top_icebreaker (
    input  wire       CLK,        // 12 MHz
    input  wire       BTN_N,      // user button = reset (active low)
    inout  wire [7:0] HRAM_DQ,
    output wire       HRAM_CK,
    output wire       HRAM_CSN,
    input  wire       HRAM_RWDS,
    output wire       OUT_VALID,
    output wire       IN_REQ,
    input  wire       HOST_DRIVE,
    input  wire       IN_VALID,
    input  wire       CFG_MODE,
    output wire [2:0] FSM_DBG,
    output wire       LEDG_N      // busy indicator (active low LED)
);

    // reset synchronizer from the button
    reg [3:0] rst_sr = 4'b0000;
    always @(posedge CLK) rst_sr <= {rst_sr[2:0], BTN_N};
    wire rst_n = rst_sr[3];

    wire [7:0] uo_out, uio_out, uio_oe;

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_dq
            assign HRAM_DQ[i] = uio_oe[i] ? uio_out[i] : 1'bz;
        end
    endgenerate

    tt_um_stele_ssm core (
        .ui_in   ({4'b0000, CFG_MODE, IN_VALID, HOST_DRIVE, HRAM_RWDS}),
        .uo_out  (uo_out),
        .uio_in  (HRAM_DQ),
        .uio_out (uio_out),
        .uio_oe  (uio_oe),
        .ena     (1'b1),
        .clk     (CLK),
        .rst_n   (rst_n)
    );

    assign HRAM_CK   = uo_out[0];
    assign HRAM_CSN  = uo_out[1];
    assign OUT_VALID = uo_out[2];
    assign IN_REQ    = uo_out[3];
    assign LEDG_N    = ~uo_out[4];
    assign FSM_DBG   = uo_out[7:5];

endmodule

`default_nettype wire
