// addr_gen — per-layer base address registers (region base + stride).
// layer_rst returns to layer 0; layer_next advances both bases one layer.
// Everything else in the address path is running adders in the sequencer.
`default_nettype none

module addr_gen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        layer_rst,
    input  wire        layer_next,
    input  wire [22:0] weights_base,
    input  wire [22:0] state_base,
    input  wire [15:0] l_stride,
    input  wire [15:0] st_stride,
    output reg  [22:0] wl_base,      // this layer's weights base (bytes)
    output reg  [22:0] sl_base       // this layer's state base (bytes)
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wl_base <= 23'd0;
            sl_base <= 23'd0;
        end else if (layer_rst) begin
            wl_base <= weights_base;
            sl_base <= state_base;
        end else if (layer_next) begin
            wl_base <= wl_base + {7'd0, l_stride};
            sl_base <= sl_base + {7'd0, st_stride};
        end
    end
endmodule

`default_nettype wire
