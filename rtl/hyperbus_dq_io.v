// hyperbus_dq_io — registered bidirectional DQ pad ring for the HyperBus PHY.
//
// FPGA build (`define ICE40): eight SB_IO primitives, registered output,
// registered output-enable, registered input — the fiddly iCE40 primitive
// isolated here per the brief.
//
// Generic build (sim / TT / lint): behaviourally identical plain registers
// with an explicit tri-state driver. One clk of latency in each direction in
// both builds; the PHY's capture-offset CSR absorbs any residual difference.
//
// On the TT top this module is NOT instantiated inside the core (TT has no
// inout ports) — the core exposes dout/oe/din and the harness or the FPGA
// wrapper owns the pad. This module is used by the icebreaker wrapper and by
// the milestone-1 loopback testbench.

module hyperbus_dq_io (
    input  wire       clk,
    input  wire       oe,       // 1 = drive pad
    input  wire [7:0] dout,     // core -> pad
    output wire [7:0] din,      // pad -> core (registered)
    inout  wire [7:0] pad
);

`ifdef ICE40
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_io
            SB_IO #(
                // [5:2]=1101: registered output, registered enable
                // [1:0]=00  : registered input
                .PIN_TYPE(6'b1101_00),
                .PULLUP(1'b0)
            ) io (
                .PACKAGE_PIN(pad[i]),
                .OUTPUT_CLK(clk),
                .INPUT_CLK(clk),
                .OUTPUT_ENABLE(oe),
                .D_OUT_0(dout[i]),
                .D_IN_0(din[i])
            );
        end
    endgenerate
`else
    reg [7:0] dout_q = 8'h00;
    reg       oe_q   = 1'b0;
    reg [7:0] din_q  = 8'h00;

    always @(posedge clk) begin
        dout_q <= dout;
        oe_q   <= oe;
        din_q  <= pad;
    end

    assign pad = oe_q ? dout_q : 8'hzz;
    assign din = din_q;
`endif

endmodule
