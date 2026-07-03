// regfile — the 64-byte working register file (the ONLY on-die data storage
// besides pipeline registers; never grows to model scale — spec §14).
// One sync write port, three async read ports (trit fetch / operand / C).
`default_nettype none

module regfile (
    input  wire       clk,
    input  wire       we,
    input  wire [5:0] waddr,
    input  wire [7:0] wdata,
    input  wire [5:0] raddr_a,
    output wire [7:0] rdata_a,
    input  wire [5:0] raddr_b,
    output wire [7:0] rdata_b,
    input  wire [5:0] raddr_c,
    output wire [7:0] rdata_c
);
    reg [7:0] mem [0:63];

    always @(posedge clk)
        if (we) mem[waddr] <= wdata;

    assign rdata_a = mem[raddr_a];
    assign rdata_b = mem[raddr_b];
    assign rdata_c = mem[raddr_c];
endmodule

`default_nettype wire
