// Full-system harness: TT top + behavioural HyperRAM loaded with the golden
// image. The host side (boot stream, start token) is driven by cocotb.
`timescale 1ns/1ps

module tb_top;
    reg clk = 0;
    reg rst_n = 0;
    reg host_drive = 0;
    reg in_valid = 0;
    reg cfg_mode = 0;
    reg [7:0] host_data = 8'h00;

    wire [7:0] uo_out, uio_out, uio_oe;
    wire       rwds;
    wire [7:0] uio;

    // three-way bus: DUT, host, HyperRAM
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_bus
            assign uio[i] = uio_oe[i] ? uio_out[i] : 1'bz;
        end
    endgenerate
    assign uio = host_drive ? host_data : 8'hzz;

    wire [7:0] ui_in = {4'b0000, cfg_mode, in_valid, host_drive, rwds};

    tt_um_stele_ssm dut (
        .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n)
    );

    hyperram_model #(
        .LATENCY(6),
        .IMAGE_FILE("../../golden/hyperram_image.hex")
    ) hram (
        .ck(uo_out[0]), .csn(uo_out[1]), .dq(uio), .rwds(rwds)
    );
endmodule
