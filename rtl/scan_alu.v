// scan_alu — the single shared int8 multiply datapath (UP5K area budget:
// exactly ONE 8x8 multiplier in the whole design; every product is
// time-multiplexed through it by the sequencer).
//
// Paths, mirroring golden/reference_model.py exactly:
// PIPELINED: the raw product is registered (mul_pq <= mula*mulb every clk),
// so the multiplier never chains into the requant/PWL/accumulate logic —
// consumers use results one cycle after presenting operands (12 MHz closure).
//  - mul_out = sat8(round_shift(mul_pq, mshift)); mula optionally unsigned.
//    mul_pq is also exported raw (dA for the exp PWL).
//  - p_latch: p_r <= mul_pq (first half of the h update, abar*h).
//  - h_new = sat8(round_shift(p_r + mul_pq, S_SCAN=7)) — second half
//    (mul_pq = bbar*u, p_r = abar*h latched earlier).
//  - mac_en: yacc += mul_pq (y accumulation, C[n]*h_new); mac_clr clears;
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
    output wire signed [16:0] mul_pq,   // registered raw product
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

    wire signed [16:0] mul_p;
    generate
        if (USE_DSP) begin : g_dsp
            mult_dsp m (.a(mula), .b(mulb), .a_unsigned(mula_unsigned),
                        .p(mul_p));
        end else begin : g_synth
            mult_synth m (.a(mula), .b(mulb), .a_unsigned(mula_unsigned),
                          .p(mul_p));
        end
    endgenerate

    // product pipeline register — the timing cut
    reg signed [16:0] mul_pq_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) mul_pq_r <= 17'sd0;
        else        mul_pq_r <= mul_p;
    end
    assign mul_pq = mul_pq_r;

    // ---- requant view (of the registered product) -----------------------
    // Only two shift amounts exist in the design (S_DB=4, S_G=5), so this is
    // a 2:1 select of fixed shifts, not a barrel shifter (timing-critical).
    wire signed [17:0] gext  = {mul_pq_r[16], mul_pq_r};
    wire signed [17:0] grnd4 = gext + 18'sd8;
    wire signed [17:0] grnd5 = gext + 18'sd16;
    wire signed [17:0] gshf  = (mshift == 4'd5) ? (grnd5 >>> 5)
                                                : (grnd4 >>> 4);
    assign mul_out = (gshf > 18'sd127)  ? 8'd127 :
                     (gshf < -18'sd128) ? 8'h80  : gshf[7:0];

    // ---- h' = sat8(rr(p_r + mul_p, 7)) ---------------------------------
    reg signed [16:0] p_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       p_r <= 17'sd0;
        else if (p_latch) p_r <= mul_pq_r;
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
            yacc <= yacc + {{3{mul_pq_r[16]}}, mul_pq_r};
    end

    wire signed [20:0] yacc_e = {yacc[19], yacc};
    wire signed [20:0] yrnd = yacc_e + (21'sd1 <<< (mac_shift - 4'd1));
    wire signed [20:0] yshf = (mac_shift == 4'd0) ? yacc_e
                                                  : (yrnd >>> mac_shift);
    assign yacc_q8 = (yshf > 21'sd127)  ? 8'd127 :
                     (yshf < -21'sd128) ? 8'h80  : yshf[7:0];

endmodule

`default_nettype wire
