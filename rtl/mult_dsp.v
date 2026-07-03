// mult_dsp — optional SB_MAC16 wrapper (FPGA convenience only; USE_DSP=1).
// Same interface as mult_synth. The default/tested build never uses this —
// TT has no DSP (spec §14).
`default_nettype none

module mult_dsp (
    input  wire [7:0]  a,
    input  wire [7:0]  b,
    input  wire        a_unsigned,
    output wire [16:0] p
);
`ifdef ICE40
    // dynamic signedness: zero- or sign-extend into 16 bits, multiply signed
    wire [15:0] ma = a_unsigned ? {8'h00, a} : {{8{a[7]}}, a};
    wire [15:0] mb = {{8{b[7]}}, b};
    wire [31:0] mo;
    SB_MAC16 #(
        .TOPOUTPUT_SELECT(2'b11), .BOTOUTPUT_SELECT(2'b11),
        .A_SIGNED(1'b1), .B_SIGNED(1'b1)
    ) mac (
        .A(ma), .B(mb), .C(16'h0), .D(16'h0),
        .O(mo), .CLK(1'b0), .CE(1'b1),
        .IRSTTOP(1'b0), .IRSTBOT(1'b0), .ORSTTOP(1'b0), .ORSTBOT(1'b0),
        .AHOLD(1'b0), .BHOLD(1'b0), .CHOLD(1'b0), .DHOLD(1'b0),
        .OHOLDTOP(1'b0), .OHOLDBOT(1'b0), .OLOADTOP(1'b0), .OLOADBOT(1'b0),
        .ADDSUBTOP(1'b0), .ADDSUBBOT(1'b0), .CO(), .CI(1'b0),
        .ACCUMCI(1'b0), .ACCUMCO(), .SIGNEXTIN(1'b0), .SIGNEXTOUT()
    );
    assign p = mo[16:0];
`else
    // non-FPGA builds fall back to the synthesizable multiplier
    mult_synth m (.a(a), .b(b), .a_unsigned(a_unsigned), .p(p));
`endif
endmodule

`default_nettype wire
