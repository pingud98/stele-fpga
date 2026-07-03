// Milestone 1 testbench: registered bidirectional DQ with OE toggling.
// The pad is shared between the DUT and an external driver owned by the test.
`timescale 1ns/1ps

module tb_dq_loopback;
    reg        clk = 0;
    reg        oe = 0;
    reg  [7:0] dout = 8'h00;
    wire [7:0] din;
    wire [7:0] pad;

    // external side of the pad (the "HyperRAM")
    reg        ext_oe = 0;
    reg  [7:0] ext_drive = 8'h00;
    assign pad = ext_oe ? ext_drive : 8'hzz;

    hyperbus_dq_io dut (
        .clk  (clk),
        .oe   (oe),
        .dout (dout),
        .din  (din),
        .pad  (pad)
    );
endmodule
