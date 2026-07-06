// hyperbus_phy — SDR-degraded HyperBus master (the TT-faithful critical block).
//
// Clocking (clk/2 scheme): one byte per clk cycle; CK = clk/2. DQ and all
// controls update on POSEDGE clk; hb_ck is the design's only negedge
// register, toggling half a cycle later — so outputs are stable half a clk
// either side of every CK edge (centre-aligned, as HyperBus masters must
// drive writes), and read data driven by the slave on a CK edge is sampled
// by the externally registered dq_in at the following posedge. Still SDR
// from the logic's point of view: one transfer per CK edge, no DDR capture
// primitives, no calibrated delays. RWDS is sampled once during the CA
// phase for the 1x/2x latency count and never used as a capture strobe;
// reads are captured at a fixed configurable offset (cfg_capture clk cycles,
// default 1) after each edge cycle.
//
// Edge numbering matches sim/hyperram_model.v: CA on edges 1..6; first data
// byte on edge 7 + 2*T (T = cfg_latency, doubled when RWDS was high during
// CA; T = 0 for register writes); one byte per edge, words big-endian.
//
// tCSM: transfers longer than cfg_max_burst words are split into multiple
// transactions with re-issued CA. At 12 MHz clk (CK 6 MHz) the default
// max_burst=8 keeps every transaction under ~3 us (IS66WVH8M8 tCSM = 4 us).
//
// Command interface: pulse cmd_valid with cmd_* held; PHY latches when
// cmd_ready. Write bytes are consumed one per wr_ready cycle (one per clk
// during data; the provider must keep up). Read bytes appear as
// rd_valid/rd_data pulses (one per clk). done pulses once after the final
// chunk.

`default_nettype none

module hyperbus_phy (
    input  wire        clk,
    input  wire        rst_n,
    // configuration (from CSRs)
    input  wire [3:0]  cfg_latency,    // initial latency, CK cycles (>= 1)
    input  wire [7:0]  cfg_max_burst,  // words per transaction (tCSM guard)
    input  wire [2:0]  cfg_capture,    // clk cycles from edge cycle to capture
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
    output reg         hb_ck,          // negedge-clocked (see header)
    output reg         hb_csn,
    output reg  [7:0]  dq_out,
    output reg         dq_oe,
    input  wire [7:0]  dq_in,          // externally registered pad input
    input  wire        rwds_in
);

    localparam [2:0] ST_IDLE  = 3'd0,
                     ST_CSS   = 3'd1,   // CS# assert + first CA byte setup
                     ST_CA    = 3'd2,   // 6 edge cycles
                     ST_LAT   = 3'd3,   // 2*T edge cycles, bus released
                     ST_DATA  = 3'd4,   // 2*W edge cycles
                     ST_DRAIN = 3'd5,   // captures land, then CS# high
                     ST_CSH   = 3'd6;   // CS# high between chunks

    reg [2:0]  state;
    reg [39:0] ca_sh;          // remaining CA bytes after the first
    reg [2:0]  edge_cnt;       // CA edge cycles 1..6
    reg [9:0]  phase_edges;    // edge cycles remaining in LAT/DATA
    reg        lat2x;
    reg        rwds_q;
    reg [15:0] words_left;
    reg [15:0] chunk_left;
    reg [21:0] cur_addr;
    reg        t_write, t_reg;
    reg [7:0]  cap_sr;         // pending read-capture markers
    reg [2:0]  csh_cnt;

    wire [4:0] lat_total = {1'b0, cfg_latency} << lat2x;

    assign cmd_ready = (state == ST_IDLE);
    assign rd_valid  = cap_sr[cfg_capture];
    assign rd_data   = dq_in;
    // one write byte consumed per posedge that loads dq_out with stream
    // data: the first byte loads at the last CA (reg write) or last latency
    // cycle, so CK never pauses mid-transaction
    assign wr_ready  = t_write &&
                       ((state == ST_CA  && edge_cnt == 3'd6 && t_reg) ||
                        (state == ST_LAT && phase_edges == 10'd1) ||
                        (state == ST_DATA && phase_edges != 10'd1));

    wire [15:0] this_chunk = (words_left > {8'h00, cfg_max_burst})
                             ? {8'h00, cfg_max_burst} : words_left;

    // full CA word, available during ST_CSS (operands latched in ST_IDLE)
    wire [47:0] ca_full = {~t_write, t_reg, 1'b1,
                           10'b0, cur_addr[21:3],
                           13'b0, cur_addr[2:0]};

    // CK: the only negedge register — toggles half a cycle after the data
    // posedge of every edge cycle. Edge counts per chunk are even, so CK
    // always parks low.
    wire ck_en = (state == ST_CA) || (state == ST_LAT) || (state == ST_DATA);
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n)      hb_ck <= 1'b0;
        else if (ck_en)  hb_ck <= ~hb_ck;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            hb_csn <= 1'b1;
            dq_out <= 8'h00;
            dq_oe  <= 1'b0;
            done   <= 1'b0;
            cap_sr <= 8'h00;
            rwds_q <= 1'b0;
            lat2x  <= 1'b0;
            edge_cnt <= 3'd0;
            phase_edges <= 10'd0;
            words_left <= 16'd0;
            chunk_left <= 16'd0;
            cur_addr <= 22'd0;
            t_write <= 1'b0;
            t_reg   <= 1'b0;
            ca_sh   <= 40'd0;
            csh_cnt <= 3'd0;
        end else begin
            done   <= 1'b0;
            rwds_q <= rwds_in;
            cap_sr <= {cap_sr[6:0], 1'b0};

            case (state)
                ST_IDLE: begin
                    hb_csn <= 1'b1;
                    dq_oe  <= 1'b0;
                    if (cmd_valid) begin
                        t_write    <= cmd_write;
                        t_reg      <= cmd_reg;
                        cur_addr   <= cmd_addr;
                        words_left <= (cmd_len == 16'd0) ? 16'd1 : cmd_len;
                        state      <= ST_CSS;
                    end
                end

                // assert CS# and present the first CA byte on the same edge;
                // its CK edge follows half a cycle into the first CA cycle
                ST_CSS: begin
                    hb_csn     <= 1'b0;
                    dq_out     <= ca_full[47:40];
                    dq_oe      <= 1'b1;
                    ca_sh      <= ca_full[39:0];
                    chunk_left <= this_chunk;
                    edge_cnt   <= 3'd1;
                    lat2x      <= 1'b0;
                    state      <= ST_CA;
                end

                ST_CA: begin
                    // edge for the presented byte occurs mid-cycle; present
                    // the next byte at this ending posedge
                    dq_out <= ca_sh[39:32];
                    ca_sh  <= {ca_sh[31:0], 8'h00};
                    edge_cnt <= edge_cnt + 3'd1;
                    if (edge_cnt == 3'd4)
                        lat2x <= rwds_q;    // sampled-RWDS latency indication
                    if (edge_cnt == 3'd6) begin
                        if (t_write && t_reg) begin
                            // register write: zero latency; first data byte
                            // replaces the (dead) 7th CA shift byte
                            dq_out      <= wr_data;
                            phase_edges <= {chunk_left[8:0], 1'b0};
                            state       <= ST_DATA;
                        end else begin
                            phase_edges <= {4'd0, lat_total, 1'b0}; // 2*T
                            dq_oe       <= 1'b0;                    // turnaround
                            state       <= ST_LAT;
                        end
                    end
                end

                ST_LAT: begin
                    phase_edges <= phase_edges - 10'd1;
                    if (phase_edges == 10'd1) begin
                        phase_edges <= {chunk_left[8:0], 1'b0};
                        if (t_write) begin
                            dq_out <= wr_data;   // byte 0, edge next cycle
                            dq_oe  <= 1'b1;
                        end else begin
                            cap_sr[0] <= 1'b1;   // first data edge cycle next
                        end
                        state <= ST_DATA;
                    end
                end

                ST_DATA: begin
                    phase_edges <= phase_edges - 10'd1;
                    if (t_write)
                        dq_out <= wr_data;
                    else if (phase_edges != 10'd1)
                        cap_sr[0] <= 1'b1;       // another data edge cycle next
                    if (phase_edges == 10'd1) begin
                        dq_oe   <= 1'b0;
                        csh_cnt <= 3'd7;
                        state   <= ST_DRAIN;
                    end
                end

                ST_DRAIN: begin
                    dq_oe   <= 1'b0;
                    csh_cnt <= csh_cnt - 3'd1;
                    if (csh_cnt == 3'd0) begin
                        hb_csn     <= 1'b1;
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
