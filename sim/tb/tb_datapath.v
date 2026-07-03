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
    reg  [3:0] tm_shift = 0;
    wire signed [17:0] tm_acc;
    wire [7:0] tm_q8;
    ternary_mac tm (.clk(clk), .rst_n(rst_n), .clr(tm_clr), .en(tm_en),
                    .trit(tm_trit), .x(tm_x), .shift(tm_shift),
                    .acc(tm_acc), .q8(tm_q8));

    // scan_alu
    reg  [7:0] abar = 0, h_in = 0, bbar = 0, u_in = 0;
    wire [7:0] h_new;
    reg  [7:0] mula = 0, mulb = 0;
    reg        mula_unsigned = 0;
    reg  [3:0] mshift = 0;
    wire [7:0] mul_out;
    wire signed [16:0] mul_p;
    reg        mac_en = 0, mac_clr = 0;
    reg  [7:0] mac_a = 0, mac_b = 0;
    reg  [3:0] mac_shift = 0;
    wire signed [19:0] yacc;
    wire [7:0] yacc_q8;
    scan_alu sa (.clk(clk), .rst_n(rst_n),
                 .abar(abar), .h_in(h_in), .bbar(bbar), .u_in(u_in),
                 .h_new(h_new),
                 .mula(mula), .mulb(mulb), .mula_unsigned(mula_unsigned),
                 .mshift(mshift), .mul_out(mul_out), .mul_p(mul_p),
                 .mac_en(mac_en), .mac_clr(mac_clr),
                 .mac_a(mac_a), .mac_b(mac_b), .mac_shift(mac_shift),
                 .yacc(yacc), .yacc_q8(yacc_q8));

    // pwl_nonlin
    reg  [15:0] pwl_x = 0;
    reg  [1:0]  pwl_sel = 0;
    wire [7:0]  pwl_y;
    pwl_nonlin pw (.x(pwl_x), .sel(pwl_sel), .y(pwl_y));
endmodule
