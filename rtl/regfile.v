// regfile — the 64-byte working register file (the ONLY on-die data storage
// besides pipeline registers; never grows to model scale — spec §14).
// One sync write port, two async read ports (trit fetch / operand).
`default_nettype none

module regfile (
    input  wire       clk,
    input  wire       we,
    input  wire [5:0] waddr,
    input  wire [7:0] wdata,
    input  wire [5:0] raddr_a,
    output wire [7:0] rdata_a,
    // port B only ever addresses the lower half (operand staging area);
    // 5 bits halves the read mux
    input  wire [4:0] raddr_b,
    output wire [7:0] rdata_b
);
    reg [7:0] mem [0:63];

    always @(posedge clk)
        if (we) mem[waddr] <= wdata;

    assign rdata_a = mem[raddr_a];
    assign rdata_b = mem[{1'b0, raddr_b}];
endmodule

`default_nettype wire
