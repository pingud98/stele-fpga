// pwl_nonlin — piecewise-linear softplus / SiLU / exp, 8 segments each.
// Bit-exact mirror of golden/pwl.py::PwlSpec.eval; tables come from the
// generated rtl/pwl_tables.vh (shared with the numpy reference by
// construction).
//
//   sel=0 softplus: x is int8 Q4.3 (sign-extended to 16) -> uint8 Q4.4
//   sel=1 silu    : x is int8 Q4.3                       -> int8  Q4.3
//   sel=2 exp     : x is int16 Q8.8, domain [-2048,-1]   -> uint8 Q0.7
`default_nettype none

module pwl_nonlin (
    input  wire [15:0] x,     // signed
    input  wire [1:0]  sel,
    output wire [7:0]  y
);
`include "pwl_tables.vh"

    wire signed [15:0] xs = x;

    // domain clamp + segment/offset extraction
    reg  [10:0] u;            // 0..2047 (exp) / 0..255 (int8 funcs)
    reg  [2:0]  seg;
    reg  [7:0]  dx;
    reg  [3:0]  mshift;
    reg  signed [9:0] bsel, msel;
    reg  signed [9:0] ymin, ymax;

    // upper bits of xc/ycl are dead by construction (post-clamp ranges)
    /* verilator lint_off UNUSEDSIGNAL */
    reg signed [15:0] xc;
    /* verilator lint_on UNUSEDSIGNAL */

    always @* begin
        if (sel == 2'd2) begin
            xc = (xs < -16'sd2048) ? -16'sd2048 :
                 (xs > -16'sd1)    ? -16'sd1    : xs;
            // for xc in [-2048,-1] the low 11 bits equal xc+2048 (0..2047)
            u  = xc[10:0];
            seg = u[10:8];
            dx  = u[7:0];
            mshift = 4'd8;
            bsel = PWL_EXP_B[seg*10 +: 10];
            msel = PWL_EXP_M[seg*10 +: 10];
            ymin = 10'sd0;
            ymax = 10'sd127;
        end else begin
            xc = (xs < -16'sd128) ? -16'sd128 :
                 (xs > 16'sd127)  ? 16'sd127  : xs;
            u  = {3'b000, xc[7:0] ^ 8'h80};  // xc + 128, 0..255
            seg = u[7:5];
            dx  = {3'b000, u[4:0]};
            mshift = 4'd6;
            if (sel == 2'd0) begin
                bsel = PWL_SOFTPLUS_B[seg*10 +: 10];
                msel = PWL_SOFTPLUS_M[seg*10 +: 10];
                ymin = 10'sd0;
                ymax = 10'sd255;
            end else begin
                bsel = PWL_SILU_B[seg*10 +: 10];
                msel = PWL_SILU_M[seg*10 +: 10];
                ymin = -10'sd128;
                ymax = 10'sd127;
            end
        end
    end

    // y = B + round_shift(M*dx, mshift), clamped.
    // All sign extensions via explicitly signed wires — a bare concat is
    // unsigned and would force logical shifts / unsigned comparisons.
    wire signed [17:0] prod   = msel * $signed({1'b0, dx});
    wire signed [18:0] prod_e = {prod[17], prod};
    wire signed [18:0] bsel_e = {{9{bsel[9]}}, bsel};
    wire signed [18:0] ymin_e = {{9{ymin[9]}}, ymin};
    wire signed [18:0] ymax_e = {{9{ymax[9]}}, ymax};
    wire signed [18:0] rnd  = prod_e + (19'sd1 <<< (mshift - 4'd1));
    wire signed [18:0] yv   = bsel_e + (rnd >>> mshift);
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [18:0] ycl  = (yv < ymin_e) ? ymin_e :
                              (yv > ymax_e) ? ymax_e : yv;
    /* verilator lint_on UNUSEDSIGNAL */
    assign y = ycl[7:0];

endmodule

`default_nettype wire
