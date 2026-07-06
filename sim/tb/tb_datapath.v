// Milestone 5 harness: all datapath primitives side by side, driven
// independently by cocotb.
`timescale 1ns/1ps

module tb_datapath;
    reg clk = 0;
    reg rst_n = 0;

    // ternary_mac
    reg        tm_clr = 0, tm_en = 0;
    reg  [1:0] tm_trit = 0;
    reg  [7:0] tm_x = 0;
    reg  [1:0] tm_shift = 0;
    wire signed [17:0] tm_acc;
    wire [7:0] tm_q8;
    ternary_mac tm (.clk(clk), .rst_n(rst_n), .clr(tm_clr), .en(tm_en),
                    .trit(tm_trit), .x(tm_x), .shift(tm_shift),
                    .acc(tm_acc), .q8(tm_q8));

    // scan_alu (single shared multiplier, serialized h update / MAC)
    reg  [7:0] mula = 0, mulb = 0;
    reg        mula_unsigned = 0;
    reg  [3:0] mshift = 0;
    reg        p_latch = 0;
    wire [7:0] mul_out, h_new;
    wire signed [16:0] mul_pq;
    reg        mac_en = 0, mac_clr = 0;
    reg  [3:0] mac_shift = 0;
    wire signed [19:0] yacc;
    wire [7:0] yacc_q8;
    scan_alu sa (.clk(clk), .rst_n(rst_n),
                 .mula(mula), .mulb(mulb), .mula_unsigned(mula_unsigned),
                 .mshift(mshift), .mul_out(mul_out), .mul_pq(mul_pq),
                 .p_latch(p_latch), .h_new(h_new),
                 .mac_en(mac_en), .mac_clr(mac_clr), .mac_shift(mac_shift),
                 .yacc(yacc), .yacc_q8(yacc_q8));

    // pwl_nonlin
    reg  [15:0] pwl_x = 0;
    reg  [1:0]  pwl_sel = 0;
    wire [7:0]  pwl_y;
    pwl_nonlin pw (.x(pwl_x), .sel(pwl_sel), .y(pwl_y));
endmodule
