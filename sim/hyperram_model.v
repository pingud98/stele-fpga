// hyperram_model — behavioural HyperBus RAM for simulation (the contract the
// PHY is verified against). Generic 3.3 V x8 part, ISSI IS66WVH-class.
//
// Protocol contract (SDR-degraded mode; edges are CK edges, both polarities,
// numbered from 1 = first CK edge after CS# falls):
//   edges 1..6      : CA bytes, CA[47:40] first, sampled from DQ.
//   during CA       : model drives RWDS = cfg_extra_latency (1 -> 2x latency),
//                     released after edge 6.
//   T               : LATENCY * (cfg_extra_latency ? 2 : 1) CK cycles.
//   data            : first byte on edge 7 + 2*T (register writes: edge 7,
//                     zero latency); one byte per edge; 16-bit words big-endian
//                     (high byte first); linear burst, address auto-increment.
//   reads           : model drives DQ and RWDS (RWDS high on high-byte edges).
//   writes          : model samples DQ; RWDS==1 from master masks the byte
//                     (this PHY never drives RWDS - TT maps it input-only).
//   tCSM            : CS# low longer than TCSM_NS raises $error, err_count++.
//
// Register space (AS=1): word addr 0x0 = ID0 (0x0c81), 0x1 = ID1, 0x800 = CR0
// (writable, readable). Memory space: mem[], loaded from IMAGE_FILE ($readmemh,
// one byte per line) when non-empty.
//
// Testbench hooks (hierarchical): cfg_extra_latency, err_count, cr0, mem[].

`timescale 1ns/1ps

module hyperram_model #(
    parameter MEM_BYTES  = 1 << 20,
    parameter LATENCY    = 6,
    parameter TCSM_NS    = 4000,
    parameter IMAGE_FILE = ""
)(
    input  wire       ck,
    input  wire       csn,
    inout  wire [7:0] dq,
    inout  wire       rwds
);

    reg [7:0] mem [0:MEM_BYTES-1];
    reg [8*160-1:0] img_plusarg;
    integer i;
    initial begin
        for (i = 0; i < MEM_BYTES; i = i + 1) mem[i] = 8'h00;
        if ($value$plusargs("IMAGE=%s", img_plusarg))
            $readmemh(img_plusarg, mem);   // per-run override (demos)
        else if (IMAGE_FILE != "")
            $readmemh(IMAGE_FILE, mem);
    end

    // testbench-pokeable configuration / status
    reg        cfg_extra_latency = 1'b0;
    integer    err_count = 0;
    reg [15:0] cr0 = 16'h8f1f;

    // transaction state
    reg [47:0] ca = 48'h0;
    integer    edge_cnt = 0;
    reg        rd = 1'b0, as = 1'b0;
    reg [31:0] waddr = 32'h0;      // 16-bit word address
    integer    data_start = 0;     // edge number of first data byte
    realtime   t_fall = 0;
    reg        tcsm_flagged = 1'b0;

    // pad drivers
    reg        dq_oe    = 1'b0;
    reg  [7:0] dq_out   = 8'h00;
    reg        rwds_oe  = 1'b0;
    reg        rwds_out = 1'b0;
    assign dq   = dq_oe   ? dq_out   : 8'hzz;
    assign rwds = rwds_oe ? rwds_out : 1'bz;

    wire [31:0] lat_cycles = LATENCY * (cfg_extra_latency ? 2 : 1);

    function [7:0] reg_read_byte(input [31:0] a, input hi);
        reg [15:0] w;
        begin
            case (a)
                32'h000: w = 16'h0c81;   // ID0
                32'h001: w = 16'h0000;   // ID1
                32'h800: w = cr0;        // CR0
                default: w = 16'h0000;
            endcase
            reg_read_byte = hi ? w[15:8] : w[7:0];
        end
    endfunction

    task check_tcsm;
        begin
            if (!tcsm_flagged && ($realtime - t_fall) > TCSM_NS) begin
                tcsm_flagged = 1;
                err_count = err_count + 1;
                $display("[%0t] HYPERRAM ERROR: tCSM violated, CS# low %0.0f ns (limit %0d)",
                         $time, $realtime - t_fall, TCSM_NS);
            end
        end
    endtask

    always @(negedge csn) begin
        t_fall       = $realtime;
        edge_cnt     = 0;
        tcsm_flagged = 0;
        dq_oe        = 0;
        rwds_out     = cfg_extra_latency;  // latency indication during CA
        rwds_oe      = 1;
    end

    always @(posedge csn) begin
        check_tcsm;
        dq_oe   = 0;
        rwds_oe = 0;
    end

    always @(ck) if (!csn) begin : ck_edge
        integer off;
        check_tcsm;
        edge_cnt = edge_cnt + 1;
        if (edge_cnt <= 6) begin
            ca = {ca[39:0], dq};
            if (edge_cnt == 6) begin
                rd      = ca[47];
                as      = ca[46];
                waddr   = {ca[44:16], ca[2:0]};
                rwds_oe = 0;
                data_start = (!rd && as) ? 7 : 7 + 2 * lat_cycles;
            end
        end else if (edge_cnt >= data_start) begin
            off = edge_cnt - data_start;
            if (rd) begin
                dq_oe    = 1;
                dq_out   = as ? reg_read_byte(waddr + off / 2, (off % 2) == 0)
                              : mem[(waddr * 2 + off) % MEM_BYTES];
                rwds_oe  = 1;
                rwds_out = (off % 2) == 0;
            end else if (as) begin
                if (off == 0) cr0[15:8] = dq;
                if (off == 1) cr0[7:0]  = dq;
            end else if (rwds !== 1'b1) begin
                mem[(waddr * 2 + off) % MEM_BYTES] = dq;
            end
        end
    end

endmodule
