// csr — 32 x 16-bit configuration registers + boot loader.
// Reset defaults match golden/reference_model.py CSR_DEFAULTS for the tiny
// sim config, so the core can run without a boot stream; when cfg_mode is
// high, bytes presented with in_valid pulses stream all 32 registers in
// order, high byte first (64 bytes total = golden/csr_config.hex).
`default_nettype none

module csr (
    input  wire        clk,
    input  wire        rst_n,
    // boot stream
    input  wire        cfg_mode,
    input  wire        in_valid,      // one pulse per byte
    input  wire [7:0]  boot_byte,
    output reg         boot_done,
    // decoded fields
    output wire [3:0]  latency,
    output wire [7:0]  max_burst,
    output wire [2:0]  capture,
    output wire [15:0] d_model,
    output wire [15:0] n_layers,
    output wire [15:0] d_inner,
    output wire [15:0] d_state,
    output wire [15:0] dt_rank,
    output wire [15:0] vocab,
    output wire [31:0] weights_base,
    output wire [31:0] state_base,
    output wire [31:0] scratch_base,
    output wire [15:0] n_tok,
    output wire [15:0] l_stride,
    output wire [15:0] st_stride,
    output wire [15:0] off_conv,
    output wire [15:0] off_wx,
    output wire [15:0] off_wdt,
    output wire [15:0] off_a,
    output wire [15:0] off_wout,
    output wire [15:0] off_lmhead,
    output wire [15:0] off_embed,
    output wire [15:0] ring_off
);

    reg [15:0] r [0:31];
    reg [6:0]  bcnt;      // boot byte counter, 0..64

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // defaults = golden tiny config (see ASSUMPTIONS.md)
            r[0]  <= 16'd6;      // LATENCY
            r[1]  <= 16'd16;     // MAX_BURST
            r[2]  <= 16'd1;      // CLK_DIV (reserved)
            r[3]  <= 16'd64;     // D_MODEL
            r[4]  <= 16'd2;      // N_LAYERS
            r[5]  <= 16'd128;    // D_INNER
            r[6]  <= 16'd16;     // D_STATE
            r[7]  <= 16'd4;      // D_CONV
            r[8]  <= 16'd4;      // DT_RANK
            r[9]  <= 16'd128;    // VOCAB
            r[10] <= 16'h0000;   // WEIGHTS_BASE lo
            r[11] <= 16'h0000;   //              hi
            r[12] <= 16'h0000;   // STATE_BASE lo
            r[13] <= 16'h0004;   //            hi (0x40000)
            r[14] <= 16'h0000;   // SCRATCH_BASE lo
            r[15] <= 16'h0005;   //              hi (0x50000)
            r[16] <= 16'd8;      // N_TOK
            r[17] <= 16'd1;      // BOS (informational)
            r[18] <= 16'd0;      // PACKING
            r[19] <= 16'd2;      // CAPTURE
            r[20] <= 16'd9600;   // L_STRIDE
            r[21] <= 16'd2560;   // ST_STRIDE
            r[22] <= 16'd4096;   // OFF_CONV
            r[23] <= 16'd4224;   // OFF_WX
            r[24] <= 16'd5376;   // OFF_WDT
            r[25] <= 16'd5504;   // OFF_A
            r[26] <= 16'd7552;   // OFF_WOUT
            r[27] <= 16'd19200;  // OFF_LMHEAD
            r[28] <= 16'd21248;  // OFF_EMBED
            r[29] <= 16'd2048;   // RING_OFF
            r[30] <= 16'd0;
            r[31] <= 16'd0;
            bcnt      <= 7'd0;
            boot_done <= 1'b0;
        end else if (cfg_mode && in_valid && !bcnt[6]) begin
            if (bcnt[0])
                r[bcnt[5:1]][7:0]  <= boot_byte;
            else
                r[bcnt[5:1]][15:8] <= boot_byte;
            bcnt <= bcnt + 7'd1;
            if (bcnt == 7'd63)
                boot_done <= 1'b1;
        end
    end

    assign latency      = r[0][3:0];
    assign max_burst    = r[1][7:0];
    assign capture      = r[19][2:0];
    assign d_model      = r[3];
    assign n_layers     = r[4];
    assign d_inner      = r[5];
    assign d_state      = r[6];
    assign dt_rank      = r[8];
    assign vocab        = r[9];
    assign weights_base = {r[11], r[10]};
    assign state_base   = {r[13], r[12]};
    assign scratch_base = {r[15], r[14]};
    assign n_tok        = r[16];
    assign l_stride     = r[20];
    assign st_stride    = r[21];
    assign off_conv     = r[22];
    assign off_wx       = r[23];
    assign off_wdt      = r[24];
    assign off_a        = r[25];
    assign off_wout     = r[26];
    assign off_lmhead   = r[27];
    assign off_embed    = r[28];
    assign ring_off     = r[29];

    // silence unused warnings for reserved fields
    wire _unused = &{1'b0, r[2], r[7], r[17], r[18], r[30], r[31]};

endmodule

`default_nettype wire
