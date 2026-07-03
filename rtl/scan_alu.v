// scan_alu — int8 multiply datapath for the selective-scan and gating phases.
// All multiplies go through mult_synth (mult_dsp only behind USE_DSP).
//
// Three paths, mirroring golden/reference_model.py exactly:
//  1. h-update (combinational):
//       h_new = sat8(round_shift(abar*h_in + bbar*u_in, S_SCAN=7))
//     abar unsigned Q0.7; h_in, bbar, u_in signed int8.
//  2. generic mul-requant (combinational):
//       mul_out = sat8(round_shift(mula*mulb, mshift)), mula optionally
//     unsigned — covers Bbar=(delta*B)>>4, gate y*silu(z)>>5, dA=delta*A
//     (via mul_p raw product output).
//  3. y-accumulator (registered): mac_en: yacc += mac_a*mac_b (signed),
//     mac_clr clears. 18-bit exact for |sum| <= 16*127*127.
`default_nettype none

module scan_alu (
    input  wire        clk,
    input  wire        rst_n,
    // h-update path
    input  wire [7:0]  abar,        // unsigned Q0.7
    input  wire [7:0]  h_in,        // signed
    input  wire [7:0]  bbar,        // signed
    input  wire [7:0]  u_in,        // signed
    output wire [7:0]  h_new,
    // generic mul-requant path
    input  wire [7:0]  mula,
    input  wire [7:0]  mulb,
    input  wire        mula_unsigned,
    input  wire [3:0]  mshift,
    output wire [7:0]  mul_out,
    output wire signed [16:0] mul_p,   // raw product (dA for the exp PWL)
    // y accumulator
    input  wire        mac_en,
    input  wire        mac_clr,
    input  wire [7:0]  mac_a,
    input  wire [7:0]  mac_b,
    input  wire [3:0]  mac_shift,
    output reg  signed [19:0] yacc,    // |sum| <= 16*127*127 = 258064
    output wire [7:0]  yacc_q8
);
    localparam S_SCAN = 4'd7;

    // ---- path 1: h' -------------------------------------------------
    wire signed [16:0] p_ah, p_bu;
    mult_synth m_ah (.a(abar), .b(h_in), .a_unsigned(1'b1), .p(p_ah));
    mult_synth m_bu (.a(bbar), .b(u_in), .a_unsigned(1'b0), .p(p_bu));

    wire signed [17:0] hsum = {p_ah[16], p_ah} + {p_bu[16], p_bu};
    wire signed [17:0] hrnd = (hsum + (18'sd1 <<< (S_SCAN - 1))) >>> S_SCAN;
    assign h_new = (hrnd > 18'sd127)  ? 8'd127 :
                   (hrnd < -18'sd128) ? 8'h80  : hrnd[7:0];

    // ---- path 2: generic mul-requant ---------------------------------
    mult_synth m_g (.a(mula), .b(mulb), .a_unsigned(mula_unsigned), .p(mul_p));
    wire signed [17:0] gext = {mul_p[16], mul_p};
    wire signed [17:0] grnd = (gext + (18'sd1 <<< (mshift - 4'd1)));
    wire signed [17:0] gshf = (mshift == 4'd0) ? gext : (grnd >>> mshift);
    assign mul_out = (gshf > 18'sd127)  ? 8'd127 :
                     (gshf < -18'sd128) ? 8'h80  : gshf[7:0];

    // ---- path 3: y accumulator ---------------------------------------
    wire signed [16:0] p_mac;
    mult_synth m_mac (.a(mac_a), .b(mac_b), .a_unsigned(1'b0), .p(p_mac));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            yacc <= 20'sd0;
        else if (mac_clr)
            yacc <= 20'sd0;
        else if (mac_en)
            yacc <= yacc + {{3{p_mac[16]}}, p_mac};
    end

    // explicit signed extension: concats are unsigned and would force a
    // logical shift / unsigned compare below
    wire signed [20:0] yacc_e = {yacc[19], yacc};
    wire signed [20:0] yrnd = yacc_e + (21'sd1 <<< (mac_shift - 4'd1));
    wire signed [20:0] yshf = (mac_shift == 4'd0) ? yacc_e
                                                  : (yrnd >>> mac_shift);
    assign yacc_q8 = (yshf > 21'sd127)  ? 8'd127 :
                     (yshf < -21'sd128) ? 8'h80  : yshf[7:0];

endmodule

`default_nettype wire
