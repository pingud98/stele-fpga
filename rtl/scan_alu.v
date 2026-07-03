// scan_alu — the single shared int8 multiply datapath (UP5K area budget:
// exactly ONE 8x8 multiplier in the whole design; every product is
// time-multiplexed through it by the sequencer).
//
// Paths, mirroring golden/reference_model.py exactly:
//  - mul_out = sat8(round_shift(mula*mulb, mshift)); mula optionally
//    unsigned. mul_p is the raw product (dA for the exp PWL).
//  - p_latch: p_r <= mul_p (first half of the h update, abar*h).
//  - h_new = sat8(round_shift(p_r + mul_p, S_SCAN=7)) — second half
//    (mul_p = bbar*u live, p_r = abar*h latched).
//  - mac_en: yacc += mul_p (y accumulation, C[n]*h_new); mac_clr clears;
//    yacc_q8 = sat8(round_shift(yacc, mac_shift)).
`default_nettype none

module scan_alu #(
    parameter USE_DSP = 0   // 1: SB_MAC16 wrapper (FPGA convenience only);
                            // 0 (default, tested, TT path): mult_synth
)(
    input  wire        clk,
    input  wire        rst_n,
    // shared multiplier + requant
    input  wire [7:0]  mula,
    input  wire [7:0]  mulb,
    input  wire        mula_unsigned,
    input  wire [3:0]  mshift,
    output wire [7:0]  mul_out,
    output wire signed [16:0] mul_p,
    // two-step h update
    input  wire        p_latch,
    output wire [7:0]  h_new,
    // y accumulator
    input  wire        mac_en,
    input  wire        mac_clr,
    input  wire [3:0]  mac_shift,
    output reg  signed [19:0] yacc,    // |sum| <= 16*127*127 = 258064
    output wire [7:0]  yacc_q8
);
    localparam S_SCAN = 4'd7;

    generate
        if (USE_DSP) begin : g_dsp
            mult_dsp m (.a(mula), .b(mulb), .a_unsigned(mula_unsigned),
                        .p(mul_p));
        end else begin : g_synth
            mult_synth m (.a(mula), .b(mulb), .a_unsigned(mula_unsigned),
                          .p(mul_p));
        end
    endgenerate

    // ---- generic requant view ------------------------------------------
    wire signed [17:0] gext = {mul_p[16], mul_p};
    wire signed [17:0] grnd = (gext + (18'sd1 <<< (mshift - 4'd1)));
    wire signed [17:0] gshf = (mshift == 4'd0) ? gext : (grnd >>> mshift);
    assign mul_out = (gshf > 18'sd127)  ? 8'd127 :
                     (gshf < -18'sd128) ? 8'h80  : gshf[7:0];

    // ---- h' = sat8(rr(p_r + mul_p, 7)) ---------------------------------
    reg signed [16:0] p_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       p_r <= 17'sd0;
        else if (p_latch) p_r <= mul_p;
    end

    wire signed [17:0] hsum = {p_r[16], p_r} + gext;
    wire signed [17:0] hrnd = (hsum + (18'sd1 <<< (S_SCAN - 1))) >>> S_SCAN;
    assign h_new = (hrnd > 18'sd127)  ? 8'd127 :
                   (hrnd < -18'sd128) ? 8'h80  : hrnd[7:0];

    // ---- y accumulator --------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            yacc <= 20'sd0;
        else if (mac_clr)
            yacc <= 20'sd0;
        else if (mac_en)
            yacc <= yacc + {{3{mul_p[16]}}, mul_p};
    end

    wire signed [20:0] yacc_e = {yacc[19], yacc};
    wire signed [20:0] yrnd = yacc_e + (21'sd1 <<< (mac_shift - 4'd1));
    wire signed [20:0] yshf = (mac_shift == 4'd0) ? yacc_e
                                                  : (yrnd >>> mac_shift);
    assign yacc_q8 = (yshf > 21'sd127)  ? 8'd127 :
                     (yshf < -21'sd128) ? 8'h80  : yshf[7:0];

endmodule

`default_nettype wire
