// mult_synth — plain-Verilog signed multiplier (the path that ships to TT).
// a_unsigned=1 treats `a` as unsigned (used for Abar Q0.7 and delta Q4.4).
`default_nettype none

module mult_synth (
    input  wire [7:0]  a,
    input  wire [7:0]  b,
    input  wire        a_unsigned,
    output wire [16:0] p            // signed product
);
    wire signed [8:0]  ae = a_unsigned ? {1'b0, a} : {a[7], a};
    wire signed [8:0]  be = {b[7], b};
    assign p = ae * be;
endmodule

`default_nettype wire
