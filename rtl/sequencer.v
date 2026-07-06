// sequencer — microcoded per-token FSM (spec §8).
//
// The layer program lives in a small microcode ROM (`ucode` case block):
// 8 phases per layer — IN_PROJ, CONV, SCAN_PREP(x_proj), DT_PROJ, SCAN,
// GATE, OUT_PROJ, RES_ADD — then LM_HEAD (argmax) and EMBED per token.
// Reordering or dropping phases is a ROM edit, not a datapath respin.
//
// Everything model-sized lives in HyperRAM; on-die storage is the 64-byte
// regfile plus scalar staging registers. All HyperRAM writes are word
// (16-bit) granular: per-element results are paired via wb0/wb1 before
// writing, and the conv ring rows are 4-byte padded.
//
// PH_READ / PH_WRITE act as microcoded subroutines: set p_* / dst / src,
// jump to S_RD_ISSUE / S_WR_ISSUE with ret set to the continuation state.
`default_nettype none

module sequencer (
    input  wire        clk,
    input  wire        rst_n,
    // host token interface (via top)
    input  wire        in_valid,
    input  wire        host_drive,
    input  wire        cfg_mode,
    input  wire [7:0]  token_in,
    output reg  [7:0]  token_out,
    output reg         out_valid,
    output wire        in_req,
    output reg         busy,
    output wire [2:0]  fsm_dbg,
    // CSR fields
    input  wire [3:0]  latency,
    input  wire [7:0]  max_burst,
    input  wire [2:0]  capture,
    input  wire [15:0] d_model,
    input  wire [15:0] n_layers,
    input  wire [15:0] d_inner,
    input  wire [15:0] d_state,
    input  wire [15:0] dt_rank,
    input  wire [15:0] vocab,
    input  wire [22:0] weights_base,
    input  wire [22:0] state_base,
    input  wire [22:0] scratch_base,
    input  wire [15:0] n_tok,
    input  wire [15:0] l_stride,
    input  wire [15:0] st_stride,
    input  wire [15:0] off_conv,
    input  wire [15:0] off_wx,
    input  wire [15:0] off_wdt,
    input  wire [15:0] off_a,
    input  wire [15:0] off_wout,
    input  wire [15:0] off_lmhead,
    input  wire [15:0] off_embed,
    input  wire [15:0] ring_off,
    // pads
    output wire        hb_ck,
    output wire        hb_csn,
    output wire [7:0]  dq_out,
    output wire        dq_oe,
    input  wire [7:0]  dq_in,
    input  wire        rwds_in
);

    // ---------------- fixed-point spec (mirrors golden) -----------------
    localparam [1:0] S_IN = 2'd3, S_CONV = 2'd1, S_XP = 2'd2, S_DT = 2'd1,
                     S_OUT = 2'd3;
    localparam [3:0] S_DB = 4'd4, S_C = 4'd6, S_G = 4'd5;
    // scratch byte offsets
    localparam [15:0] SC_X = 16'd0,  SC_X1 = 16'd64,  SC_Z = 16'd192,
                      SC_U = 16'd320, SC_DBC = 16'd448, SC_DT = 16'd512,
                      SC_Y = 16'd640, SC_RES = 16'd832;

    // ---------------- states -------------------------------------------
    localparam [6:0]
        S_IDLE      = 7'd0,  S_TOK_START = 7'd1,
        S_EMB_RD    = 7'd2,  S_EMB_WR    = 7'd3,  S_EMB_NEXT = 7'd4,
        S_DISPATCH  = 7'd5,  S_PHASE_NEXT= 7'd6,
        S_TM_ROW    = 7'd7,  S_TM_WREAD  = 7'd8,  S_TM_XREAD = 7'd9,
        S_TM_CHNEXT = 7'd10, S_TM_WB     = 7'd11, S_TM_ROWNEXT = 7'd12,
        S_DTS_DTR   = 7'd13, S_DTS_CHUNK = 7'd14, S_DTS_MAC  = 7'd15,
        S_DTS_Q     = 7'd16, S_DTS_WB    = 7'd17, S_DTS_NEXT = 7'd18,
        S_CV_KB     = 7'd19, S_CV_RING   = 7'd20, S_CV_X1    = 7'd21,
        S_CV_MAC    = 7'd22, S_CV_Q      = 7'd23, S_CV_STAGE = 7'd24,
        S_CV_RINGWR = 7'd25, S_CV_UWR    = 7'd26, S_CV_NEXT  = 7'd27,
        S_SC_B      = 7'd28, S_SC_C      = 7'd29, S_SC_CH    = 7'd30,
        S_SC_U      = 7'd31, S_SC_A      = 7'd32, S_SC_H     = 7'd33,
        S_SC_N1     = 7'd34, S_SC_N2     = 7'd35, S_SC_HWR   = 7'd36,
        S_SC_Y      = 7'd37, S_SC_NEXT   = 7'd38,
        S_GT_Y      = 7'd39, S_GT_Z      = 7'd40, S_GT_CALC  = 7'd41,
        S_GT_WR     = 7'd42, S_GT_NEXT   = 7'd43,
        S_VA_X      = 7'd44, S_VA_R      = 7'd45, S_VA_CALC  = 7'd46,
        S_VA_WR     = 7'd47, S_VA_NEXT   = 7'd48,
        S_LM_INIT   = 7'd49, S_EMIT      = 7'd50, S_HALT     = 7'd51,
        S_RD_ISSUE  = 7'd52, S_RD_WAIT   = 7'd53,
        S_WR_ISSUE  = 7'd54, S_WR_WAIT   = 7'd55,
        S_LADV      = 7'd57,
        S_SC_N3     = 7'd58, S_SC_N4    = 7'd59, S_SC_N5    = 7'd60,
        S_GT_C2     = 7'd61,
        // consume-cycles: scan_alu registers its product, so every
        // multiplier use is a present-state followed by a consume-state
        S_SC_N1B    = 7'd62, S_SC_N2B   = 7'd63, S_SC_N3B   = 7'd64,
        S_SC_N4B    = 7'd65, S_SC_N5B   = 7'd66, S_GT_C3    = 7'd67,
        S_DTS_Q2    = 7'd68, S_CV_Q2    = 7'd69,
        // PWL input is registered (timing): route x, then read y
        S_SC_N1C    = 7'd70, S_DTS_Q3   = 7'd71, S_CV_Q3    = 7'd72,
        S_GT_CALC2  = 7'd73;

    reg [6:0] state, ret, ret2;

    // ---------------- PHY ----------------------------------------------
    reg         cmd_valid, cmd_write, cmd_reg;
    reg  [22:0] p_addr;          // BYTE address (converted to word addr)
    reg  [15:0] p_len;
    wire        cmd_ready, wr_ready, rd_valid, phy_done;
    wire [7:0]  rd_data;
    reg  [7:0]  wr_data_mux;

    hyperbus_phy phy (
        .clk(clk), .rst_n(rst_n),
        .cfg_latency(latency), .cfg_max_burst(max_burst),
        .cfg_capture(capture),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_write(cmd_write), .cmd_reg(cmd_reg),
        .cmd_addr(p_addr[22:1]), .cmd_len(p_len),
        .wr_data(wr_data_mux), .wr_ready(wr_ready),
        .rd_data(rd_data), .rd_valid(rd_valid), .done(phy_done),
        .hb_ck(hb_ck), .hb_csn(hb_csn),
        .dq_out(dq_out), .dq_oe(dq_oe),
        .dq_in(dq_in), .rwds_in(rwds_in)
    );

    // ---------------- regfile ------------------------------------------
    reg         rf_we;
    reg  [5:0]  rf_waddr;
    reg  [7:0]  rf_wdata;
    reg  [5:0]  ra;
    reg  [4:0]  rb;
    wire [7:0]  rda, rdb;
    regfile rf (.clk(clk), .we(rf_we), .waddr(rf_waddr), .wdata(rf_wdata),
                .raddr_a(ra), .rdata_a(rda),
                .raddr_b(rb), .rdata_b(rdb));

    // ---------------- layer bases --------------------------------------
    reg  layer_rst, layer_next;
    wire [22:0] wl_base, sl_base;
    addr_gen ag (.clk(clk), .rst_n(rst_n),
                 .layer_rst(layer_rst), .layer_next(layer_next),
                 .weights_base(weights_base), .state_base(state_base),
                 .l_stride(l_stride), .st_stride(st_stride),
                 .wl_base(wl_base), .sl_base(sl_base));

    // ---------------- datapath units -----------------------------------
    // NB: unit enables are COMBINATIONAL, decoded from the current state, so
    // they are sampled at the same edge as the combinationally muxed
    // operands they belong to. Registered enables would lag one cycle.
    wire        tm_clr, tm_en;
    reg  [1:0]  tm_trit;
    reg  [7:0]  tm_x;
    reg  [1:0]  tm_shift;
    wire signed [17:0] tm_acc;
    wire [7:0]  tm_q8;
    ternary_mac tmac (.clk(clk), .rst_n(rst_n), .clr(tm_clr), .en(tm_en),
                      .trit(tm_trit), .x(tm_x), .shift(tm_shift),
                      .acc(tm_acc), .q8(tm_q8));

    reg  [7:0]  sa_mula, sa_mulb;
    reg         sa_mula_u;
    reg  [3:0]  sa_mshift;
    wire [7:0]  sa_mulout, sa_hnew;
    wire signed [16:0] sa_mulpq;
    wire        sa_mac_en, sa_mac_clr, sa_p_latch;
    wire signed [19:0] sa_yacc;
    wire [7:0]  sa_yq8;
    scan_alu salu (.clk(clk), .rst_n(rst_n),
                   .mula(sa_mula), .mulb(sa_mulb), .mula_unsigned(sa_mula_u),
                   .mshift(sa_mshift), .mul_out(sa_mulout), .mul_pq(sa_mulpq),
                   .p_latch(sa_p_latch), .h_new(sa_hnew),
                   .mac_en(sa_mac_en), .mac_clr(sa_mac_clr), .mac_shift(S_C),
                   .yacc(sa_yacc), .yacc_q8(sa_yq8));

    // PWL input register: the state-decoded operand mux lands here, and the
    // evaluator (which contains a 10x8 multiplier) runs from the register —
    // consumers read pwl_y one cycle after routing pwl_x.
    reg  [15:0] pwl_x;
    reg  [1:0]  pwl_sel;
    reg  [15:0] pwl_x_q;
    reg  [1:0]  pwl_sel_q;
    wire [7:0]  pwl_y;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pwl_x_q   <= 16'd0;
            pwl_sel_q <= 2'd0;
        end else begin
            pwl_x_q   <= pwl_x;
            pwl_sel_q <= pwl_sel;
        end
    end
    pwl_nonlin pwl (.x(pwl_x_q), .sel(pwl_sel_q), .y(pwl_y));


    // ---------------- sequencer registers ------------------------------
    reg [2:0]  uidx;
    reg [15:0] layer;
    reg [15:0] tok_cnt;
    reg [7:0]  cur_tok;

    // TMAC phase parameters (loaded by ucode dispatch)
    reg [8:0]  rows;
    reg [7:0]  cols;
    reg [7:0]  wrow_bytes;
    reg [1:0]  q_shift;
    reg        am_mode;          // argmax (LM head)
    reg [22:0] w_row_addr, x_base_a, out_base_a;

    reg [8:0]  row;              // row / channel counter
    reg [1:0]  chunk;
    reg [2:0]  echunk;           // embed chunk
    reg [7:0]  col;              // column within 64-wide chunk / j counters
    reg [4:0]  n_idx;
    reg [7:0]  rd_cnt;           // bytes received in current PH_READ

    // PH_READ destination / PH_WRITE source
    localparam [1:0] DST_RF = 2'd0, DST_MAC = 2'd1, DST_BYTE = 2'd2;
    localparam [1:0] SRC_RF = 2'd0, SRC_WB = 2'd1;
    reg [1:0]  dst, src;
    reg [5:0]  rf_wptr, rf_rptr;
    reg        byte_lane;
    reg [1:0]  creg_sel;         // 0 delta, 1 u, 2 kb, 3 x1b
    reg [7:0]  delta_c, u_c, kb, x1b;
    reg [7:0]  bbar_r, hnew_r, g_r, q8_r;

    reg        wr_idx;           // which wb byte is being sent

    // word-pair writeback staging
    reg [7:0]  wb0, wb1;

    // argmax
    reg signed [17:0] best;
    reg [7:0]  best_ix;

    reg [7:0]  abar_r;
    reg [2:0]  emit_cnt;

    assign in_req  = (state == S_IDLE) && !cfg_mode;
    assign fsm_dbg = busy ? uidx : 3'b111;

    // plain TMAC writeback view (dt/conv nonlinearities go via q8_r + PWL)
    wire [7:0] q_nl = tm_q8;

    // combinational datapath strobes, aligned with operand muxes below
    assign tm_clr = (state == S_TM_ROW) || (state == S_DTS_CHUNK) ||
                    (state == S_DTS_Q)  || (state == S_CV_X1);
    assign tm_en  = (state == S_DTS_MAC) || (state == S_CV_MAC) ||
                    (state == S_RD_WAIT && dst == DST_MAC && rd_valid);
    assign sa_mac_clr = (state == S_SC_H) || (state == S_SC_NEXT);
    assign sa_mac_en  = (state == S_SC_N5B);
    assign sa_p_latch = (state == S_SC_N3B);

    // write data mux (combinational; rf_rptr/wr_idx advance on wr_ready)
    always @* begin
        if (src == SRC_RF) wr_data_mux = rda;
        else               wr_data_mux = wr_idx ? wb1 : wb0;
    end

    // trit extraction helpers
    wire [7:0] trit_byte_tm  = rda;                    // rf[col>>2]
    wire [1:0] trit_tm = trit_byte_tm[{col[1:0], 1'b0} +: 2];
    wire [1:0] trit_dts = rda[{n_idx[1:0], 1'b0} +: 2]; // rf[j] lane n
    wire [1:0] trit_cv  = kb[{n_idx[1:0], 1'b0} +: 2];

    // saturating byte add for RES_ADD
    wire signed [8:0] va_sum = {rda[7], rda} + {rdb[7], rdb};
    wire [7:0] va_q = (va_sum > 9'sd127) ? 8'd127 :
                      (va_sum < -9'sd128) ? 8'h80 : va_sum[7:0];

    // ---------------- combinational port routing -----------------------
    always @* begin
        // defaults
        ra = 6'd0; rb = 5'd0;
        pwl_x = 16'd0; pwl_sel = 2'd0;
        sa_mula = 8'd0; sa_mulb = 8'd0; sa_mula_u = 1'b0; sa_mshift = 4'd0;
        tm_trit = 2'd0; tm_x = 8'd0; tm_shift = q_shift;

        case (state)
            S_RD_WAIT: begin
                // MAC streaming: trit from rf, x from rd_data
                ra      = {2'b00, col[5:2]};
                tm_trit = trit_tm;
                tm_x    = rd_data;
            end
            S_WR_ISSUE, S_WR_WAIT: begin
                ra = rf_rptr;
            end

            S_DTS_MAC: begin
                ra      = {2'b00, col[3:0]};        // w byte for row j
                rb      = 5'd16 + n_idx;            // dtr[k]
                tm_trit = trit_dts;
                tm_x    = rdb;
            end
            S_DTS_Q2: begin
                pwl_sel = 2'd0;                     // softplus(q8_r)
                pwl_x   = {{8{q8_r[7]}}, q8_r};
            end
            S_CV_MAC: begin
                ra      = {4'b0000, n_idx[1:0]};   // ring bytes rf[0..2]
                tm_trit = trit_cv;
                tm_x    = (n_idx[1:0] == 2'd3) ? x1b : rda;
            end
            S_CV_STAGE: begin
                rb = {3'b000, n_idx[1:0]} + 5'd1;  // rf[1], rf[2]
            end
            S_CV_Q2: begin
                pwl_sel = 2'd1;                     // silu(q8_r)
                pwl_x   = {{8{q8_r[7]}}, q8_r};
            end
            S_SC_N1: begin                      // present delta*A[n]
                ra       = {2'b00, n_idx[3:0]};     // A[n] in rf[0..15]
                sa_mula  = delta_c;
                sa_mulb  = rda;
                sa_mula_u = 1'b1;
            end
            S_SC_N1B: begin                     // consume: exp(dA)
                pwl_sel  = 2'd2;
                pwl_x    = sa_mulpq[15:0];
            end
            S_SC_N2: begin                      // present delta*B[n]
                ra       = 6'd32 + {2'b00, n_idx[3:0]};  // B[n]
                sa_mula  = delta_c;
                sa_mulb  = rda;
                sa_mula_u = 1'b1;
            end
            S_SC_N2B: begin                     // consume: bbar
                sa_mshift = S_DB;
            end
            S_SC_N3: begin                      // present abar*h[n]
                ra       = 6'd16 + {2'b00, n_idx[3:0]};  // h[n]
                sa_mula  = abar_r;
                sa_mulb  = rda;
                sa_mula_u = 1'b1;
            end
            // S_SC_N3B: consume (p_latch strobe only)
            S_SC_N4: begin                      // present bbar*u
                sa_mula  = bbar_r;
                sa_mulb  = u_c;
            end
            // S_SC_N4B: consume: h_new = rr(p_r + mul_pq, 7)
            S_SC_N5: begin                      // present C[n]*h_new
                ra       = 6'd48 + {2'b00, n_idx[3:0]};  // C[n]
                sa_mula  = rda;
                sa_mulb  = hnew_r;
            end
            // S_SC_N5B: consume (mac_en strobe only)
            S_GT_CALC: begin                    // g_r <= silu(z[j])
                rb       = 5'd16 + {1'b0, col[3:0]};  // z[j]
                pwl_sel  = 2'd1;
                pwl_x    = {{8{rdb[7]}}, rdb};
            end
            S_GT_C2: begin                      // present y[j]*g_r
                ra       = {2'b00, col[3:0]};       // y[j]
                sa_mula  = rda;
                sa_mulb  = g_r;
            end
            S_GT_C3: begin                      // consume: requant, write back
                sa_mshift = S_G;
            end
            S_VA_CALC: begin
                ra = {2'b00, col[3:0]};
                rb = 5'd16 + {1'b0, col[3:0]};
            end
            default: ;
        endcase
    end

    // ---------------- main FSM -----------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; ret <= S_IDLE; ret2 <= S_IDLE;
            cmd_valid <= 1'b0; cmd_write <= 1'b0; cmd_reg <= 1'b0;
            p_addr <= 23'd0; p_len <= 16'd0;
            rf_we <= 1'b0; rf_waddr <= 6'd0; rf_wdata <= 8'd0;
            layer_rst <= 1'b0; layer_next <= 1'b0;
            uidx <= 3'd0; layer <= 16'd0; tok_cnt <= 16'd0; cur_tok <= 8'd0;
            rows <= 9'd0; cols <= 8'd0; wrow_bytes <= 8'd0;
            q_shift <= 2'd0; am_mode <= 1'b0;
            w_row_addr <= 23'd0; x_base_a <= 23'd0; out_base_a <= 23'd0;
            row <= 9'd0; chunk <= 2'd0; echunk <= 3'd0; col <= 8'd0;
            n_idx <= 5'd0; rd_cnt <= 8'd0;
            dst <= DST_RF; src <= SRC_RF;
            rf_wptr <= 6'd0; rf_rptr <= 6'd0;
            byte_lane <= 1'b0; creg_sel <= 2'd0;
            delta_c <= 8'd0; u_c <= 8'd0; kb <= 8'd0; x1b <= 8'd0;
            bbar_r <= 8'd0; hnew_r <= 8'd0; g_r <= 8'd0; q8_r <= 8'd0;
            wb0 <= 8'd0; wb1 <= 8'd0; wr_idx <= 1'b0;
            best <= 18'sd0; best_ix <= 8'd0; abar_r <= 8'd0;
            emit_cnt <= 3'd0;
            token_out <= 8'd0; out_valid <= 1'b0; busy <= 1'b0;
        end else begin
            // one-shot strobes
            cmd_valid  <= 1'b0;
            rf_we      <= 1'b0;
            layer_rst  <= 1'b0;
            layer_next <= 1'b0;
            out_valid  <= 1'b0;

            case (state)
                // ------------------------------------------------ control
                S_IDLE: begin
                    busy <= 1'b0;
                    if (in_valid && !cfg_mode && host_drive) begin
                        cur_tok <= token_in;
                        tok_cnt <= 16'd0;
                        busy    <= 1'b1;
                        state   <= S_TOK_START;
                    end
                end

                S_TOK_START: begin
                    // wait for the host to release uio before touching DQ
                    if (!host_drive) begin
                        layer_rst <= 1'b1;
                        layer     <= 16'd0;
                        uidx      <= 3'd0;
                        echunk    <= 3'd0;
                        state     <= S_EMB_RD;
                    end
                end

                // EMBED: copy embed[cur_tok] -> scratch x, 16B chunks
                S_EMB_RD: begin
                    p_addr  <= weights_base + {7'd0, off_embed}
                               + {9'd0, cur_tok, 6'b000000} + {16'd0, echunk, 4'b0000};
                    p_len   <= 16'd8;
                    cmd_write <= 1'b0; cmd_reg <= 1'b0;
                    dst     <= DST_RF; rf_wptr <= 6'd0;
                    ret     <= S_EMB_WR;
                    state   <= S_RD_ISSUE;
                end
                S_EMB_WR: begin
                    p_addr  <= scratch_base + {7'd0, SC_X} + {16'd0, echunk, 4'b0000};
                    p_len   <= 16'd8;
                    src     <= SRC_RF; rf_rptr <= 6'd0;
                    ret     <= S_EMB_NEXT;
                    state   <= S_WR_ISSUE;
                end
                S_EMB_NEXT: begin
                    echunk <= echunk + 3'd1;
                    if ({13'd0, echunk} + 16'd1 >= (d_model >> 4))
                        state <= S_DISPATCH;
                    else
                        state <= S_EMB_RD;
                end

                // ---------------------------------------------- microcode
                S_DISPATCH: begin
                    row <= 9'd0; chunk <= 2'd0; col <= 8'd0; n_idx <= 5'd0;
                    am_mode <= 1'b0;
                    case (uidx)
                        3'd0: begin // IN_PROJ
                            rows       <= d_inner[7:0] << 1;
                            cols       <= d_model[7:0];
                            wrow_bytes <= d_model[7:0] >> 2;
                            q_shift    <= S_IN;
                            w_row_addr <= wl_base;
                            x_base_a   <= scratch_base + {7'd0, SC_X};
                            out_base_a <= scratch_base + {7'd0, SC_X1};
                            state      <= S_TM_ROW;
                        end
                        3'd1: begin // CONV
                            rows    <= {1'b0, d_inner[7:0]};
                            q_shift <= S_CONV;
                            state   <= S_CV_KB;
                        end
                        3'd2: begin // x_proj -> dbc
                            rows       <= dt_rank[8:0] + (d_state[7:0] << 1);
                            cols       <= d_inner[7:0];
                            wrow_bytes <= d_inner[7:0] >> 2;
                            q_shift    <= S_XP;
                            w_row_addr <= wl_base + {7'd0, off_wx};
                            x_base_a   <= scratch_base + {7'd0, SC_U};
                            out_base_a <= scratch_base + {7'd0, SC_DBC};
                            state      <= S_TM_ROW;
                        end
                        3'd3: begin // dt_proj (small rows) + softplus
                            rows       <= {1'b0, d_inner[7:0]};
                            q_shift    <= S_DT;
                            w_row_addr <= wl_base + {7'd0, off_wdt};
                            out_base_a <= scratch_base + {7'd0, SC_DT};
                            state      <= S_DTS_DTR;
                        end
                        3'd4: begin // SCAN
                            rows  <= {1'b0, d_inner[7:0]};
                            state <= S_SC_B;
                        end
                        3'd5: begin // GATE
                            rows  <= {1'b0, d_inner[7:0]};
                            state <= S_GT_Y;
                        end
                        3'd6: begin // OUT_PROJ
                            rows       <= {1'b0, d_model[7:0]};
                            cols       <= d_inner[7:0];
                            wrow_bytes <= d_inner[7:0] >> 2;
                            q_shift    <= S_OUT;
                            w_row_addr <= wl_base + {7'd0, off_wout};
                            x_base_a   <= scratch_base + {7'd0, SC_Y};
                            out_base_a <= scratch_base + {7'd0, SC_RES};
                            state      <= S_TM_ROW;
                        end
                        default: begin // RES_ADD
                            rows  <= {1'b0, d_model[7:0]};
                            state <= S_VA_X;
                        end
                    endcase
                end

                S_PHASE_NEXT: begin
                    if (uidx == 3'd7) begin
                        uidx <= 3'd0;
                        layer_next <= 1'b1;
                        layer <= layer + 16'd1;
                        if (layer + 16'd1 >= n_layers)
                            state <= S_LM_INIT;
                        else
                            state <= S_LADV;
                    end else begin
                        uidx  <= uidx + 3'd1;
                        state <= S_DISPATCH;
                    end
                end

                // one settle cycle so addr_gen applies the layer stride
                // BEFORE S_DISPATCH latches w_row_addr from wl_base
                S_LADV: state <= S_DISPATCH;

                // ---------------------------------------------- TMAC
                S_TM_ROW: begin
                    chunk  <= 2'd0;
                    state  <= S_TM_WREAD;
                end
                S_TM_WREAD: begin
                    p_addr  <= w_row_addr + {17'd0, chunk, 4'b0000};
                    p_len   <= 16'd8;
                    dst     <= DST_RF; rf_wptr <= 6'd0;
                    ret     <= S_TM_XREAD;
                    state   <= S_RD_ISSUE;
                end
                S_TM_XREAD: begin
                    p_addr  <= x_base_a + {15'd0, chunk, 6'b000000};
                    p_len   <= {10'd0, 6'd32};
                    dst     <= DST_MAC; col <= 8'd0;
                    ret     <= S_TM_CHNEXT;
                    state   <= S_RD_ISSUE;
                end
                S_TM_CHNEXT: begin
                    chunk <= chunk + 2'd1;
                    // chunks of 64 columns: done when chunk+1 == cols/64
                    if ({2'd0, chunk} + 4'd1 >= {2'b00, cols[7:6]})
                        state <= S_TM_WB;
                    else
                        state <= S_TM_WREAD;
                end
                S_TM_WB: begin
                    if (am_mode) begin
                        if (row == 9'd0 || tm_acc > best) begin
                            best    <= tm_acc;
                            best_ix <= row[7:0];
                        end
                        state <= S_TM_ROWNEXT;
                    end else if (!row[0]) begin
                        wb0   <= q_nl;
                        state <= S_TM_ROWNEXT;
                    end else begin
                        wb1   <= q_nl;
                        p_addr <= out_base_a + {14'd0, row} - 23'd1;
                        p_len  <= 16'd1;
                        src    <= SRC_WB; wr_idx <= 1'b0;
                        ret    <= S_TM_ROWNEXT;
                        state  <= S_WR_ISSUE;
                    end
                end
                S_TM_ROWNEXT: begin
                    row        <= row + 9'd1;
                    w_row_addr <= w_row_addr + {15'd0, wrow_bytes};
                    if (row + 9'd1 >= rows)
                        state <= am_mode ? S_EMIT : S_PHASE_NEXT;
                    else
                        state <= S_TM_ROW;
                end

                // ---------------------------------------------- dt_proj
                S_DTS_DTR: begin
                    p_addr  <= scratch_base + {7'd0, SC_DBC};
                    p_len   <= 16'd2;
                    dst     <= DST_RF; rf_wptr <= 6'd16;
                    ret     <= S_DTS_CHUNK;
                    state   <= S_RD_ISSUE;
                end
                S_DTS_CHUNK: begin
                    p_addr  <= w_row_addr + {14'd0, row};
                    p_len   <= 16'd8;
                    dst     <= DST_RF; rf_wptr <= 6'd0;
                    col     <= 8'd0;
                    n_idx   <= 5'd0;
                    ret     <= S_DTS_MAC;
                    state   <= S_RD_ISSUE;
                end
                S_DTS_MAC: begin
                    if (n_idx == 5'd3) begin
                        n_idx <= 5'd0;
                        state <= S_DTS_Q;
                    end else
                        n_idx <= n_idx + 5'd1;
                end
                S_DTS_Q: begin
                    q8_r  <= tm_q8;                // requant view registered
                    state <= S_DTS_Q2;
                end
                S_DTS_Q2: state <= S_DTS_Q3;       // pwl input registers
                S_DTS_Q3: begin
                    rf_we    <= 1'b1;
                    rf_waddr <= 6'd32 + {2'b00, col[3:0]};
                    rf_wdata <= pwl_y;             // softplus(q8_r)
                    if (col[3:0] == 4'd15) begin
                        state <= S_DTS_WB;
                    end else begin
                        col   <= col + 8'd1;
                        state <= S_DTS_MAC;
                    end
                end
                S_DTS_WB: begin
                    p_addr  <= out_base_a + {14'd0, row};
                    p_len   <= 16'd8;
                    src     <= SRC_RF; rf_rptr <= 6'd32;
                    ret     <= S_DTS_NEXT;
                    state   <= S_WR_ISSUE;
                end
                S_DTS_NEXT: begin
                    row <= row + 9'd16;
                    if (row + 9'd16 >= rows)
                        state <= S_PHASE_NEXT;
                    else
                        state <= S_DTS_CHUNK;
                end

                // ---------------------------------------------- CONV
                S_CV_KB: begin
                    p_addr    <= wl_base + {7'd0, off_conv} + ({14'd0, row} & ~23'd1);
                    p_len     <= 16'd1;
                    dst       <= DST_BYTE;
                    byte_lane <= row[0];
                    creg_sel  <= 2'd2;             // kb
                    ret       <= S_CV_RING;
                    state     <= S_RD_ISSUE;
                end
                S_CV_RING: begin
                    p_addr  <= sl_base + {7'd0, ring_off} + ({14'd0, row} << 2);
                    p_len   <= 16'd2;
                    dst     <= DST_RF; rf_wptr <= 6'd0;
                    ret     <= S_CV_X1;
                    state   <= S_RD_ISSUE;
                end
                S_CV_X1: begin
                    p_addr    <= (scratch_base + {7'd0, SC_X1} + {14'd0, row}) & ~23'd1;
                    p_len     <= 16'd1;
                    dst       <= DST_BYTE;
                    byte_lane <= row[0];
                    creg_sel  <= 2'd3;             // x1b
                    n_idx     <= 5'd0;
                    ret       <= S_CV_MAC;
                    state     <= S_RD_ISSUE;
                end
                S_CV_MAC: begin
                    if (n_idx == 5'd3) begin
                        n_idx <= 5'd0;
                        state <= S_CV_Q;
                    end else
                        n_idx <= n_idx + 5'd1;
                end
                S_CV_Q: begin
                    q8_r  <= tm_q8;
                    state <= S_CV_Q2;
                end
                S_CV_Q2: state <= S_CV_Q3;         // pwl input registers
                S_CV_Q3: begin
                    if (!row[0]) wb0 <= pwl_y;      // silu(q8_r)
                    else         wb1 <= pwl_y;
                    n_idx <= 5'd0;
                    state <= S_CV_STAGE;
                end
                S_CV_STAGE: begin
                    // stage new ring row [old1, old2, x1, 0] into rf[8..11]
                    rf_we    <= 1'b1;
                    rf_waddr <= 6'd8 + {3'b000, n_idx[1:0] + 2'd0};
                    case (n_idx[1:0])
                        2'd0: rf_wdata <= rdb;      // rf[1] via port b
                        2'd1: rf_wdata <= rdb;      // rf[2]
                        2'd2: rf_wdata <= x1b;
                        default: rf_wdata <= 8'd0;
                    endcase
                    n_idx <= n_idx + 5'd1;
                    if (n_idx[1:0] == 2'd3)
                        state <= S_CV_RINGWR;
                end
                S_CV_RINGWR: begin
                    p_addr  <= sl_base + {7'd0, ring_off} + ({14'd0, row} << 2);
                    p_len   <= 16'd2;
                    src     <= SRC_RF; rf_rptr <= 6'd8;
                    ret     <= S_CV_UWR;
                    state   <= S_WR_ISSUE;
                end
                S_CV_UWR: begin
                    if (row[0]) begin
                        p_addr <= scratch_base + {7'd0, SC_U} + {14'd0, row} - 23'd1;
                        p_len  <= 16'd1;
                        src    <= SRC_WB; wr_idx <= 1'b0;
                        ret    <= S_CV_NEXT;
                        state  <= S_WR_ISSUE;
                    end else
                        state <= S_CV_NEXT;
                end
                S_CV_NEXT: begin
                    row <= row + 9'd1;
                    if (row + 9'd1 >= rows)
                        state <= S_PHASE_NEXT;
                    else
                        state <= S_CV_KB;
                end

                // ---------------------------------------------- SCAN
                S_SC_B: begin
                    p_addr  <= scratch_base + {7'd0, SC_DBC} + {7'd0, dt_rank};
                    p_len   <= 16'd8;
                    dst     <= DST_RF; rf_wptr <= 6'd32;
                    ret     <= S_SC_C;
                    state   <= S_RD_ISSUE;
                end
                S_SC_C: begin
                    p_addr  <= scratch_base + {7'd0, SC_DBC} + {7'd0, dt_rank}
                               + {7'd0, d_state};
                    p_len   <= 16'd8;
                    dst     <= DST_RF; rf_wptr <= 6'd48;
                    ret     <= S_SC_CH;
                    state   <= S_RD_ISSUE;
                end
                S_SC_CH: begin
                    p_addr    <= (scratch_base + {7'd0, SC_DT} + {14'd0, row}) & ~23'd1;
                    p_len     <= 16'd1;
                    dst       <= DST_BYTE;
                    byte_lane <= row[0];
                    creg_sel  <= 2'd0;             // delta_c
                    ret       <= S_SC_U;
                    state     <= S_RD_ISSUE;
                end
                S_SC_U: begin
                    p_addr    <= (scratch_base + {7'd0, SC_U} + {14'd0, row}) & ~23'd1;
                    p_len     <= 16'd1;
                    dst       <= DST_BYTE;
                    byte_lane <= row[0];
                    creg_sel  <= 2'd1;             // u_c
                    ret       <= S_SC_A;
                    state     <= S_RD_ISSUE;
                end
                S_SC_A: begin
                    p_addr  <= wl_base + {7'd0, off_a} + ({14'd0, row} << 4);
                    p_len   <= 16'd8;
                    dst     <= DST_RF; rf_wptr <= 6'd0;
                    ret     <= S_SC_H;
                    state   <= S_RD_ISSUE;
                end
                S_SC_H: begin
                    p_addr  <= sl_base + ({14'd0, row} << 4);
                    p_len   <= 16'd8;
                    dst     <= DST_RF; rf_wptr <= 6'd16;
                    n_idx   <= 5'd0;
                    ret     <= S_SC_N1;
                    state   <= S_RD_ISSUE;
                end
                S_SC_N1:  state <= S_SC_N1B;    // product registers
                S_SC_N1B: state <= S_SC_N1C;    // pwl input registers
                S_SC_N1C: begin
                    abar_r <= pwl_y;               // exp(delta*A[n])
                    state  <= S_SC_N2;
                end
                S_SC_N2:  state <= S_SC_N2B;
                S_SC_N2B: begin
                    bbar_r <= sa_mulout;           // rr(delta*B[n], S_DB)
                    state  <= S_SC_N3;
                end
                S_SC_N3:  state <= S_SC_N3B;
                S_SC_N3B: state <= S_SC_N4;        // p_r latched this edge
                S_SC_N4:  state <= S_SC_N4B;
                S_SC_N4B: begin
                    rf_we    <= 1'b1;
                    rf_waddr <= 6'd16 + {2'b00, n_idx[3:0]};
                    rf_wdata <= sa_hnew;
                    hnew_r   <= sa_hnew;
                    state    <= S_SC_N5;
                end
                S_SC_N5:  state <= S_SC_N5B;
                S_SC_N5B: begin                    // yacc += C[n]*h_new here
                    if (n_idx[3:0] == d_state[3:0] - 4'd1) begin
                        n_idx <= 5'd0;
                        state <= S_SC_HWR;
                    end else begin
                        n_idx <= n_idx + 5'd1;
                        state <= S_SC_N1;
                    end
                end
                S_SC_HWR: begin
                    p_addr  <= sl_base + ({14'd0, row} << 4);
                    p_len   <= 16'd8;
                    src     <= SRC_RF; rf_rptr <= 6'd16;
                    ret     <= S_SC_Y;
                    state   <= S_WR_ISSUE;
                end
                S_SC_Y: begin
                    if (!row[0]) begin
                        wb0   <= sa_yq8;
                        state <= S_SC_NEXT;
                    end else begin
                        wb1   <= sa_yq8;
                        p_addr <= scratch_base + {7'd0, SC_Y} + {14'd0, row} - 23'd1;
                        p_len  <= 16'd1;
                        src    <= SRC_WB; wr_idx <= 1'b0;
                        ret    <= S_SC_NEXT;
                        state  <= S_WR_ISSUE;
                    end
                end
                S_SC_NEXT: begin
                    row <= row + 9'd1;
                    if (row + 9'd1 >= rows)
                        state <= S_PHASE_NEXT;
                    else
                        state <= S_SC_CH;
                end

                // ---------------------------------------------- GATE
                S_GT_Y: begin
                    p_addr  <= scratch_base + {7'd0, SC_Y} + ({14'd0, row} << 0);
                    p_len   <= 16'd8;
                    dst     <= DST_RF; rf_wptr <= 6'd0;
                    ret     <= S_GT_Z;
                    state   <= S_RD_ISSUE;
                end
                S_GT_Z: begin
                    p_addr  <= scratch_base + {7'd0, SC_Z} + ({14'd0, row} << 0);
                    p_len   <= 16'd8;
                    dst     <= DST_RF; rf_wptr <= 6'd16;
                    col     <= 8'd0;
                    ret     <= S_GT_CALC;
                    state   <= S_RD_ISSUE;
                end
                S_GT_CALC: state <= S_GT_CALC2;    // pwl input registers
                S_GT_CALC2: begin
                    g_r   <= pwl_y;                // silu(z[j])
                    state <= S_GT_C2;
                end
                S_GT_C2:  state <= S_GT_C3;      // product registers
                S_GT_C3: begin
                    rf_we    <= 1'b1;
                    rf_waddr <= {2'b00, col[3:0]};
                    rf_wdata <= sa_mulout;         // sat8(rr(y*g_r, S_G))
                    if (col[3:0] == 4'd15) begin
                        state <= S_GT_WR;
                    end else begin
                        col   <= col + 8'd1;
                        state <= S_GT_CALC;
                    end
                end
                S_GT_WR: begin
                    p_addr  <= scratch_base + {7'd0, SC_Y} + ({14'd0, row} << 0);
                    p_len   <= 16'd8;
                    src     <= SRC_RF; rf_rptr <= 6'd0;
                    ret     <= S_GT_NEXT;
                    state   <= S_WR_ISSUE;
                end
                S_GT_NEXT: begin
                    row <= row + 9'd16;
                    if (row + 9'd16 >= rows)
                        state <= S_PHASE_NEXT;
                    else
                        state <= S_GT_Y;
                end

                // ---------------------------------------------- RES_ADD
                S_VA_X: begin
                    p_addr  <= scratch_base + {7'd0, SC_X} + {14'd0, row};
                    p_len   <= 16'd8;
                    dst     <= DST_RF; rf_wptr <= 6'd0;
                    ret     <= S_VA_R;
                    state   <= S_RD_ISSUE;
                end
                S_VA_R: begin
                    p_addr  <= scratch_base + {7'd0, SC_RES} + {14'd0, row};
                    p_len   <= 16'd8;
                    dst     <= DST_RF; rf_wptr <= 6'd16;
                    col     <= 8'd0;
                    ret     <= S_VA_CALC;
                    state   <= S_RD_ISSUE;
                end
                S_VA_CALC: begin
                    rf_we    <= 1'b1;
                    rf_waddr <= {2'b00, col[3:0]};
                    rf_wdata <= va_q;
                    if (col[3:0] == 4'd15)
                        state <= S_VA_WR;
                    else
                        col <= col + 8'd1;
                end
                S_VA_WR: begin
                    p_addr  <= scratch_base + {7'd0, SC_X} + {14'd0, row};
                    p_len   <= 16'd8;
                    src     <= SRC_RF; rf_rptr <= 6'd0;
                    ret     <= S_VA_NEXT;
                    state   <= S_WR_ISSUE;
                end
                S_VA_NEXT: begin
                    row <= row + 9'd16;
                    if (row + 9'd16 >= rows)
                        state <= S_PHASE_NEXT;
                    else
                        state <= S_VA_X;
                end

                // ---------------------------------------------- LM head
                S_LM_INIT: begin
                    rows       <= vocab[8:0];
                    cols       <= d_model[7:0];
                    wrow_bytes <= d_model[7:0] >> 2;
                    am_mode    <= 1'b1;
                    w_row_addr <= weights_base + {7'd0, off_lmhead};
                    x_base_a   <= scratch_base + {7'd0, SC_X};
                    row        <= 9'd0;
                    state      <= S_TM_ROW;
                end

                S_EMIT: begin
                    token_out <= best_ix;
                    out_valid <= 1'b1;
                    emit_cnt  <= emit_cnt + 3'd1;
                    if (emit_cnt == 3'd3) begin
                        emit_cnt <= 3'd0;
                        cur_tok  <= best_ix;
                        tok_cnt  <= tok_cnt + 16'd1;
                        if (tok_cnt + 16'd1 >= n_tok)
                            state <= S_HALT;
                        else
                            state <= S_TOK_START;
                    end
                end

                S_HALT: begin
                    busy  <= 1'b0;
                    state <= S_HALT;
                end

                // ------------------------------------- PH_READ subroutine
                S_RD_ISSUE: begin
                    cmd_write <= 1'b0; cmd_reg <= 1'b0;
                    cmd_valid <= 1'b1;
                    rd_cnt    <= 8'd0;
                    state     <= S_RD_WAIT;
                end
                S_RD_WAIT: begin
                    if (rd_valid) begin
                        rd_cnt <= rd_cnt + 8'd1;
                        case (dst)
                            DST_RF: begin
                                rf_we    <= 1'b1;
                                rf_waddr <= rf_wptr;
                                rf_wdata <= rd_data;
                                rf_wptr  <= rf_wptr + 6'd1;
                            end
                            DST_MAC: begin
                                col   <= col + 8'd1;
                            end
                            default: begin // DST_BYTE
                                if (rd_cnt == {7'd0, byte_lane}) begin
                                    case (creg_sel)
                                        2'd0: delta_c <= rd_data;
                                        2'd1: u_c     <= rd_data;
                                        2'd2: kb      <= rd_data;
                                        default: x1b  <= rd_data;
                                    endcase
                                end
                            end
                        endcase
                    end
                    if (phy_done)
                        state <= ret;
                end

                // ------------------------------------ PH_WRITE subroutine
                S_WR_ISSUE: begin
                    cmd_write <= 1'b1; cmd_reg <= 1'b0;
                    cmd_valid <= 1'b1;
                    state     <= S_WR_WAIT;
                end
                S_WR_WAIT: begin
                    if (wr_ready) begin
                        if (src == SRC_RF)
                            rf_rptr <= rf_rptr + 6'd1;
                        else
                            wr_idx <= ~wr_idx;
                    end
                    if (phy_done) begin
                        wr_idx <= 1'b0;
                        state  <= ret;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ret2 reserved for nested subroutines (unused today)
    wire _unused = &{1'b0, ret2, sa_mulpq, va_sum[8], token_in[7], p_addr[0],
                     cols[5:0], layer[15:8], cmd_ready, sa_yacc,
                     d_inner[15:8], vocab[15:9]};

endmodule

`default_nettype wire
