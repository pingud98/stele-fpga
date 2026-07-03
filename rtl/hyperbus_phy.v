// hyperbus_phy — SDR-degraded HyperBus master (the TT-faithful critical block).
//
// Scheme: internal clk only. CK toggles every 2 clk (CK = clk/4); one byte per
// CK edge. DQ/OE update on the clk cycle BEFORE each edge (tick=0 "setup",
// tick=1 "edge"), so outputs are stable a full clk around every CK edge and
// the slave's DDR capture sees centred data. Reads are captured from the
// externally registered dq_in at a fixed, configurable offset (cfg_capture
// clk cycles) after each generated edge — RWDS is sampled once during the CA
// phase for the latency count (1x/2x) and never used as a capture strobe.
//
// Edge numbering matches sim/hyperram_model.v: CA on edges 1..6; first data
// byte on edge 7 + 2*T (T = cfg_latency, doubled when RWDS was high during
// CA; T = 0 for register writes); one byte per edge, words big-endian.
//
// tCSM: transfers longer than cfg_max_burst words are split into multiple
// transactions with re-issued CA (address advances), CS# high between them.
//
// Command interface: pulse cmd_valid with cmd_* held; PHY latches when
// cmd_ready. Write bytes are consumed one per wr_ready pulse (the provider
// must always be able to supply the next byte). Read bytes appear as
// rd_valid/rd_data pulses. done pulses once after the final chunk.

`default_nettype none

module hyperbus_phy (
    input  wire        clk,
    input  wire        rst_n,
    // configuration (from CSRs)
    input  wire [3:0]  cfg_latency,    // initial latency, CK cycles
    input  wire [7:0]  cfg_max_burst,  // words per transaction (tCSM guard)
    input  wire [2:0]  cfg_capture,    // clk cycles from CK edge to capture
    // command
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire        cmd_write,
    input  wire        cmd_reg,        // register space (AS=1)
    input  wire [21:0] cmd_addr,       // 16-bit word address
    input  wire [15:0] cmd_len,        // word count
    // write stream
    input  wire [7:0]  wr_data,
    output wire        wr_ready,
    // read stream
    output wire [7:0]  rd_data,
    output wire        rd_valid,
    output reg         done,
    // pads (registered here; top maps to uio/uo)
    output reg         hb_ck,
    output reg         hb_csn,
    output reg  [7:0]  dq_out,
    output reg         dq_oe,
    input  wire [7:0]  dq_in,          // externally registered pad input
    input  wire        rwds_in
);

    localparam [2:0] ST_IDLE  = 3'd0,
                     ST_CSS   = 3'd1,   // CS# asserted, pre-CK gap
                     ST_CA    = 3'd2,
                     ST_LAT   = 3'd3,
                     ST_DATA  = 3'd4,
                     ST_DRAIN = 3'd5,
                     ST_CSH   = 3'd6;   // CS# high between chunks

    reg [2:0]  state;
    reg        tick;          // 0 = setup cycle, 1 = edge cycle
    reg [47:0] ca_sh;
    reg [4:0]  edge_cnt;      // edges within CA (1..6)
    reg [9:0]  phase_edges;   // edges remaining in LAT/DATA phase
    reg        lat2x;
    reg        rwds_q;
    reg [15:0] words_left;    // words remaining across all chunks
    reg [15:0] chunk_left;    // words remaining in current chunk
    reg [21:0] cur_addr;
    reg        t_write, t_reg;
    reg [7:0]  cap_sr;        // pending read-capture pulses
    reg [2:0]  csh_cnt;

    wire [4:0] lat_total = {1'b0, cfg_latency} << lat2x;  // 0..30 CK cycles

    assign cmd_ready = (state == ST_IDLE);
    assign wr_ready  = (state == ST_DATA) && t_write && !tick;
    assign rd_valid  = cap_sr[cfg_capture];
    assign rd_data   = dq_in;

    // next chunk size
    wire [15:0] this_chunk = (words_left > {8'h00, cfg_max_burst})
                             ? {8'h00, cfg_max_burst} : words_left;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= ST_IDLE;
            tick    <= 1'b0;
            hb_ck   <= 1'b0;
            hb_csn  <= 1'b1;
            dq_out  <= 8'h00;
            dq_oe   <= 1'b0;
            done    <= 1'b0;
            cap_sr  <= 8'h00;
            rwds_q  <= 1'b0;
            lat2x   <= 1'b0;
            edge_cnt <= 5'd0;
            phase_edges <= 10'd0;
            words_left <= 16'd0;
            chunk_left <= 16'd0;
            cur_addr <= 22'd0;
            t_write <= 1'b0;
            t_reg   <= 1'b0;
            ca_sh   <= 48'd0;
            csh_cnt <= 3'd0;
        end else begin
            done   <= 1'b0;
            rwds_q <= rwds_in;
            // read-capture delay line (bit 0 set on read data edges)
            cap_sr <= {cap_sr[6:0], 1'b0};

            case (state)
                ST_IDLE: begin
                    hb_csn <= 1'b1;
                    hb_ck  <= 1'b0;
                    dq_oe  <= 1'b0;
                    tick   <= 1'b0;
                    if (cmd_valid) begin
                        t_write    <= cmd_write;
                        t_reg      <= cmd_reg;
                        cur_addr   <= cmd_addr;
                        words_left <= (cmd_len == 16'd0) ? 16'd1 : cmd_len;
                        state      <= ST_CSS;
                    end
                end

                // start a chunk: assert CS#, give one clk of tCSS
                ST_CSS: begin
                    hb_csn     <= 1'b0;
                    chunk_left <= this_chunk;
                    ca_sh      <= {~t_write, t_reg, 1'b1,          // R/W#, AS, linear
                                   10'b0, cur_addr[21:3],
                                   13'b0, cur_addr[2:0]};
                    edge_cnt   <= 5'd0;
                    tick       <= 1'b0;
                    lat2x      <= 1'b0;
                    state      <= ST_CA;
                end

                ST_CA: begin
                    tick <= ~tick;
                    if (!tick) begin
                        // setup: present next CA byte
                        dq_out <= ca_sh[47:40];
                        ca_sh  <= {ca_sh[39:0], 8'h00};
                        dq_oe  <= 1'b1;
                    end else begin
                        // edge
                        hb_ck    <= ~hb_ck;
                        edge_cnt <= edge_cnt + 5'd1;
                        if (edge_cnt == 5'd3)
                            lat2x <= rwds_q;   // sampled RWDS latency indication
                        if (edge_cnt == 5'd5) begin
                            // 6th edge issued this cycle; CA done
                            if (t_write && t_reg) begin
                                // register write: zero latency
                                phase_edges <= {chunk_left[8:0], 1'b0};
                                state       <= ST_DATA;
                            end else begin
                                state <= ST_LAT;
                            end
                        end
                    end
                end

                ST_LAT: begin
                    tick <= ~tick;
                    if (!tick) begin
                        dq_oe <= 1'b0;                     // bus turnaround
                        // load edge budget on first setup cycle of the phase
                        if (phase_edges == 10'd0)
                            phase_edges <= {5'd0, lat_total} << 1;
                    end else begin
                        hb_ck <= ~hb_ck;
                        phase_edges <= phase_edges - 10'd1;
                        if (phase_edges == 10'd1) begin
                            phase_edges <= {chunk_left[8:0], 1'b0};
                            state       <= ST_DATA;
                        end
                    end
                    // cfg_latency must be >= 1 (CSR default 6); the only
                    // zero-latency case (register write) bypasses ST_LAT.
                end

                ST_DATA: begin
                    tick <= ~tick;
                    if (!tick) begin
                        if (t_write) begin
                            dq_out <= wr_data;
                            dq_oe  <= 1'b1;
                        end else begin
                            dq_oe <= 1'b0;
                        end
                    end else begin
                        hb_ck <= ~hb_ck;
                        if (!t_write)
                            cap_sr[0] <= 1'b1;             // capture this edge later
                        phase_edges <= phase_edges - 10'd1;
                        if (phase_edges == 10'd1) begin
                            state   <= ST_DRAIN;
                            csh_cnt <= 3'd7;
                        end
                    end
                end

                // let in-flight captures land, then raise CS#
                ST_DRAIN: begin
                    dq_oe   <= 1'b0;
                    csh_cnt <= csh_cnt - 3'd1;
                    if (csh_cnt == 3'd0) begin
                        hb_csn <= 1'b1;
                        // account the chunk just finished
                        words_left <= words_left - chunk_left;
                        cur_addr   <= cur_addr + {6'd0, chunk_left};
                        csh_cnt    <= 3'd3;
                        state      <= ST_CSH;
                    end
                end

                ST_CSH: begin
                    csh_cnt <= csh_cnt - 3'd1;
                    if (csh_cnt == 3'd0) begin
                        if (words_left == 16'd0) begin
                            done  <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            state <= ST_CSS;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
