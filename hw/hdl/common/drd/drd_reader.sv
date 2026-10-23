/**
 * Ryloth direct read ports (2026-10-20): user-side read engine for one direct read port (axi_drd[k]).
 *
 * Takes commands (card physical address, length in bytes; both multiples of 64 B) and reads them with aligned INCR
 * bursts that never cross a BURST_BEATS x 64 B boundary (1 KiB by default: the HBM ports take at most 16 beats of
 * 32 B per stack, so each stack sees an aligned burst of at most 512 B and the shell's protocol converter has nothing
 * to split). Responses come back in order (one ID), so data leaves as an AXI4-Stream in command order; tlast marks
 * the last beat of a command issued with cmd_last = 1. Commands are accepted one at a time; the next command starts
 * issuing while the previous one's data is still returning.
 *
 * Two rules keep the HBM read return free of back-pressure from this master (board 10/20 step 5: with several
 * masters on one pseudo-channel pair, a master that stalls the return of one stack while waiting for the other
 * stack deadlocks the pair through the shell's hbm_wide merge, which needs both halves of every beat):
 *   1. at most max_out bursts in flight (runtime input, <= MAX_OUT). hbm_wide(_rd) holds each stack's half in a
 *      128-beat FIFO (256 with DRD_WIDE), so with max_out <= 8 (16 wide; x 16 beats per stack) a stack can run ahead
 *      of the other by at most the FIFO depth and the shell never stalls an HBM port on this master's account;
 *   2. the R channel is always accepted: every beat requested has a reserved slot in the output FIFO (FIFO_BEATS,
 *      credits in beats), so a slow consumer on m_t* stops new bursts from being issued instead of stalling the shell.
 *
 * Scaling step B (2026-10-22 night): DATA_BITS = 1024 for the wide direct ports (128-byte beats; commands and
 * addresses in multiples of 128 B; pass BURST_BEATS = 8 to keep 1 KiB bursts, i.e. the same 16 beats per stack).
 *
 * anns15d (2026-10-22): cmd_dest rides with each command and comes out as m_tdest on every beat of that command (the
 * per-port demux routes dest 1 to the centroid lane, dest 0 to the score unit); a zero-length command with cmd_last
 * produces one null beat (m_tkeep 0, m_tlast 1, m_tdest) behind all earlier data, so a consumer that received no
 * data still sees the end of its query.
 */

`timescale 1ns / 1ps

module drd_reader #(
    parameter integer ADDR_BITS   = 34,
    parameter integer DATA_BITS   = 512,
    parameter integer MAX_OUT     = 32,
    parameter integer BURST_BEATS = 16,
    parameter integer FIFO_BEATS  = 512,
    parameter integer DEFAULT_OUT = 8      // bursts in flight when max_out = 0 (16 for the wide ports at HCLK = 2 x ACLK)
) (
    input  logic                    aclk,
    input  logic                    aresetn,

    input  logic [7:0]              max_out,     // bursts in flight allowed now (0 = DEFAULT_OUT); clamped to MAX_OUT

    input  logic                    cmd_valid,
    output logic                    cmd_ready,
    input  logic [ADDR_BITS-1:0]    cmd_addr,
    input  logic [31:0]             cmd_len,
    input  logic                    cmd_last,
    input  logic                    cmd_dest,

    AXI4.m                          m_axi,

    output logic [DATA_BITS-1:0]    m_tdata,
    output logic                    m_tvalid,
    output logic                    m_tlast,
    output logic                    m_tkeep_all,   // 0 only on a null beat
    output logic                    m_tdest,
    input  logic                    m_tready,

    output logic                    busy
);

localparam integer BS       = $clog2(DATA_BITS / 8);   // byte offset bits of a beat (6 for 512, 7 for 1024)
localparam integer OUT_BITS = $clog2(MAX_OUT + 1);
localparam integer PTR_BITS = (MAX_OUT > 1) ? $clog2(MAX_OUT) : 1;
localparam integer BB_BITS  = $clog2(BURST_BEATS);
localparam integer FB_BITS  = $clog2(FIFO_BEATS);
localparam integer CR_BITS  = $clog2(FIFO_BEATS + 1);

logic [OUT_BITS-1:0] max_out_eff;
always_comb begin
    if (max_out == 0)           max_out_eff = (MAX_OUT < DEFAULT_OUT) ? OUT_BITS'(MAX_OUT) : OUT_BITS'(DEFAULT_OUT);
    else if (max_out > MAX_OUT) max_out_eff = OUT_BITS'(MAX_OUT);
    else                        max_out_eff = OUT_BITS'(max_out);
end

// ---------------------------------------------------------------- AR generator
logic                   gen_active;
logic [ADDR_BITS-BS-1:0] gen_beat;       // address in beats
logic [31-BS:0]         gen_left;        // beats left in the current command
logic                   gen_last;
logic                   gen_dest;
logic                   null_pending;    // a zero-length last command waits for the bursts in flight, then one null beat
logic                   null_dest;
logic [OUT_BITS-1:0]    n_out;           // bursts in flight
logic [CR_BITS-1:0]     credits;         // output FIFO beats not yet reserved by a burst in flight or held

wire [BB_BITS:0]  to_boundary = BURST_BEATS - gen_beat[BB_BITS-1:0];
wire [BB_BITS:0]  this_beats  = (gen_left < to_boundary) ? gen_left[BB_BITS:0] : to_boundary;
wire              final_burst = (gen_left == this_beats);
wire              ar_fire     = m_axi.arvalid && m_axi.arready;
wire              r_fire      = m_axi.rvalid && m_axi.rready;
wire              r_end       = r_fire && m_axi.rlast;

// Issue condition: a full burst's worth of credits must be free (BURST_BEATS >= this_beats), so arvalid depends only
// on registered state and not on this_beats (gen_beat -> to_boundary -> 26-bit compare -> mux -> credit compare was
// the reader's critical path at 200 MHz, 10/21: 9 logic levels into the CE of every gen_* register). The reservation
// itself still charges the exact this_beats; a short final burst merely waits until 16 slots are free.
assign m_axi.arvalid = gen_active && (n_out < max_out_eff) && (credits >= CR_BITS'(BURST_BEATS));
assign m_axi.araddr  = {{(64-ADDR_BITS){1'b0}}, gen_beat, {BS{1'b0}}};
assign m_axi.arlen   = 8'(this_beats - 1);
assign m_axi.arburst = 2'b01;
assign m_axi.arcache = 4'b0011;
assign m_axi.arid    = 0;
assign m_axi.arlock  = 1'b0;
assign m_axi.arprot  = 3'b010;
assign m_axi.arqos   = 4'b0;
assign m_axi.arregion = 4'b0;
assign m_axi.arsize  = 3'(BS);

assign cmd_ready = !gen_active && !null_pending;

wire pop;   // a beat leaves the reader (defined with the output FIFO below)
wire null_push;   // the null beat enters the output FIFO (defined below)

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        gen_active   <= 1'b0;
        null_pending <= 1'b0;
        n_out        <= '0;
        credits      <= CR_BITS'(FIFO_BEATS);
    end
    else begin
        if (cmd_valid && cmd_ready && (cmd_len[31:BS] != 0)) begin
            gen_active <= 1'b1;
            gen_beat   <= cmd_addr[ADDR_BITS-1:BS];
            gen_left   <= cmd_len[31:BS];
            gen_last   <= cmd_last;
            gen_dest   <= cmd_dest;
        end
        else if (cmd_valid && cmd_ready && cmd_last) begin   // zero-length last command: one null beat later
            null_pending <= 1'b1;
            null_dest    <= cmd_dest;
        end
        else if (ar_fire) begin
            gen_beat <= gen_beat + this_beats;
            gen_left <= gen_left - this_beats;
            if (final_burst) gen_active <= 1'b0;
        end
        n_out   <= n_out + (ar_fire ? 1 : 0) - (r_end ? 1 : 0);
        credits <= credits - (ar_fire ? CR_BITS'(this_beats) : '0) + (pop ? 1 : 0);
        if (null_push) null_pending <= 1'b0;
    end
end

// ---------------------------------------------------------------- tlast / dest bookkeeping (per burst in flight)
logic [MAX_OUT-1:0]     lastq;
logic [MAX_OUT-1:0]     destq;
logic [PTR_BITS-1:0]    wp, rp;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        wp <= '0; rp <= '0;
    end
    else begin
        if (ar_fire) begin
            lastq[wp] <= final_burst && gen_last;
            destq[wp] <= gen_dest;
            wp <= (wp == PTR_BITS'(MAX_OUT - 1)) ? '0 : wp + 1;
        end
        if (r_end) rp <= (rp == PTR_BITS'(MAX_OUT - 1)) ? '0 : rp + 1;
    end
end

// ---------------------------------------------------------------- R channel -> output FIFO -> stream
// Every beat in flight has a reserved slot (credits), so the FIFO never overflows and rready can stay high; the
// !full term is a guard only.
logic [DATA_BITS+2:0]   mem [FIFO_BEATS];        // {null, dest, tlast, data}
logic [FB_BITS-1:0]     wp_f, rp_f;
logic [FB_BITS:0]       count;
logic                   out_valid;
logic [DATA_BITS+2:0]   out_data;

wire full  = (count == FIFO_BEATS);
wire empty = (count == 0);
wire r_push = m_axi.rvalid && m_axi.rready;
// the null beat takes a slot once every earlier burst has returned and no data is arriving this cycle
assign null_push = null_pending && (n_out == 0) && !r_push && !full;
wire push  = r_push || null_push;
wire rd    = !empty && (!out_valid || m_tready);
assign pop = m_tvalid && m_tready;

assign m_axi.rready = !full;

always_ff @(posedge aclk) begin
    if (push) mem[wp_f] <= r_push ? {1'b0, destq[rp], m_axi.rlast && lastq[rp], m_axi.rdata}
                                  : {1'b1, null_dest, 1'b1, {DATA_BITS{1'b0}}};
    if (rd)   out_data  <= mem[rp_f];
end

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        wp_f <= '0; rp_f <= '0; count <= '0; out_valid <= 1'b0;
    end
    else begin
        if (push) wp_f <= wp_f + 1;
        if (rd)   rp_f <= rp_f + 1;
        count <= count + (push ? 1 : 0) - (rd ? 1 : 0);
        if (rd)            out_valid <= 1'b1;
        else if (m_tready) out_valid <= 1'b0;
    end
end

assign m_tvalid    = out_valid;
assign m_tdata     = out_data[DATA_BITS-1:0];
assign m_tlast     = out_data[DATA_BITS];
assign m_tdest     = out_data[DATA_BITS+1];
assign m_tkeep_all = !out_data[DATA_BITS+2];

assign busy = gen_active || null_pending || (n_out != 0) || !empty || out_valid;

// ---------------------------------------------------------------- no write half
assign m_axi.awaddr   = 0;
assign m_axi.awburst  = 2'b01;
assign m_axi.awcache  = 4'b0;
assign m_axi.awid     = 0;
assign m_axi.awlen    = 8'b0;
assign m_axi.awlock   = 1'b0;
assign m_axi.awprot   = 3'b0;
assign m_axi.awqos    = 4'b0;
assign m_axi.awregion = 4'b0;
assign m_axi.awsize   = 3'b0;
assign m_axi.awvalid  = 1'b0;
assign m_axi.wdata    = 0;
assign m_axi.wlast    = 1'b0;
assign m_axi.wstrb    = 0;
assign m_axi.wvalid   = 1'b0;
assign m_axi.bready   = 1'b1;

endmodule
