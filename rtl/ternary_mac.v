// ternary_mac — the multiply-free MAC lane.
// trit: 00 = 0 (skip), 01 = +1 (acc += x), 10 = -1 (acc -= x), 11 = 0.
// 18-bit accumulator: |acc| <= 128*127 = 16256 for every matvec in the
// design, so 18 bits is exact (no overflow) and argmax comparisons match the
// golden int32 semantics bit-for-bit.
// q8 = sat8(round_shift(acc, shift)) is the requantised view of the live acc.
`default_nettype none

module ternary_mac (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clr,          // synchronous clear (takes priority)
    input  wire        en,           // accumulate this cycle
    input  wire [1:0]  trit,
    input  wire [7:0]  x,            // signed
    input  wire [1:0]  shift,        // requant shift for q8 (1..3)
    output reg  signed [17:0] acc,
    output wire [7:0]  q8
);

    wire signed [17:0] xe = {{10{x[7]}}, x};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc <= 18'sd0;
        else if (clr)
            acc <= 18'sd0;
        else if (en) begin
            case (trit)
                2'b01:   acc <= acc + xe;
                2'b10:   acc <= acc - xe;
                default: acc <= acc;
            endcase
        end
    end

    // round-to-nearest arithmetic shift (1..3), saturate to int8.
    // NB: concats are unsigned in Verilog and poison signed contexts (>>> and
    // comparisons), so sign-extension goes through explicitly signed wires.
    wire signed [18:0] acc_e = {acc[17], acc};
    wire signed [18:0] rnd = acc_e + (19'sd1 <<< (shift - 2'd1));
    wire signed [18:0] shf = rnd >>> shift;
    assign q8 = (shf > 19'sd127)  ? 8'd127 :
                (shf < -19'sd128) ? 8'h80  : shf[7:0];

endmodule

`default_nettype wire
