/**
 * Ryloth direct read ports (2026-10-20): user-side read engine for one direct read port (axi_drd[k]).
 *
 * Takes commands (card physical address, length in bytes; both multiples of 64 B) and reads them with aligned INCR
 * bursts that never cross a BURST_BEATS x 64 B boundary (1 KiB by default: the HBM ports take at most 16 beats of
 * 32 B per stack, so each stack sees an aligned burst of at most 512 B and the shell's protocol converter has nothing
 * to split). Up to MAX_OUT bursts are outstanding (the HBM accepts 64 reads per port). Responses come back in order
 * (one ID), so data leaves as an AXI4-Stream in command order; tlast marks the last beat of a command issued with
 * cmd_last = 1. Commands are accepted one at a time; the next command starts issuing while the previous one's data
 * is still returning.
 */

`timescale 1ns / 1ps

module drd_reader #(
    parameter integer ADDR_BITS   = 34,
    parameter integer MAX_OUT     = 32,
    parameter integer BURST_BEATS = 16
) (
    input  logic                    aclk,
    input  logic                    aresetn,

    input  logic                    cmd_valid,
    output logic                    cmd_ready,
    input  logic [ADDR_BITS-1:0]    cmd_addr,
    input  logic [31:0]             cmd_len,
    input  logic                    cmd_last,

    AXI4.m                          m_axi,

    output logic [511:0]            m_tdata,
    output logic                    m_tvalid,
    output logic                    m_tlast,
    input  logic                    m_tready,

    output logic                    busy
);

localparam integer OUT_BITS = $clog2(MAX_OUT + 1);
localparam integer PTR_BITS = (MAX_OUT > 1) ? $clog2(MAX_OUT) : 1;
localparam integer BB_BITS  = $clog2(BURST_BEATS);

// ---------------------------------------------------------------- AR generator
logic                   gen_active;
logic [ADDR_BITS-7:0]   gen_beat;        // address in 64 B beats
logic [31-6:0]          gen_left;        // beats left in the current command
logic                   gen_last;
logic [OUT_BITS-1:0]    n_out;           // bursts in flight

wire [BB_BITS:0]  to_boundary = BURST_BEATS - gen_beat[BB_BITS-1:0];
wire [BB_BITS:0]  this_beats  = (gen_left < to_boundary) ? gen_left[BB_BITS:0] : to_boundary;
wire              final_burst = (gen_left == this_beats);
wire              ar_fire     = m_axi.arvalid && m_axi.arready;
wire              r_fire      = m_axi.rvalid && m_axi.rready;
wire              r_end       = r_fire && m_axi.rlast;

assign m_axi.arvalid = gen_active && (n_out < MAX_OUT);
assign m_axi.araddr  = {{(64-ADDR_BITS){1'b0}}, gen_beat, 6'b0};
assign m_axi.arlen   = 8'(this_beats - 1);
assign m_axi.arburst = 2'b01;
assign m_axi.arcache = 4'b0011;
assign m_axi.arid    = 0;
assign m_axi.arlock  = 1'b0;
assign m_axi.arprot  = 3'b010;
assign m_axi.arqos   = 4'b0;
assign m_axi.arregion = 4'b0;
assign m_axi.arsize  = 3'b110;

assign cmd_ready = !gen_active;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        gen_active <= 1'b0;
        n_out      <= '0;
    end
    else begin
        if (cmd_valid && cmd_ready && (cmd_len[31:6] != 0)) begin
            gen_active <= 1'b1;
            gen_beat   <= cmd_addr[ADDR_BITS-1:6];
            gen_left   <= cmd_len[31:6];
            gen_last   <= cmd_last;
        end
        else if (ar_fire) begin
            gen_beat <= gen_beat + this_beats;
            gen_left <= gen_left - this_beats;
            if (final_burst) gen_active <= 1'b0;
        end
        n_out <= n_out + (ar_fire ? 1 : 0) - (r_end ? 1 : 0);
    end
end

// ---------------------------------------------------------------- tlast bookkeeping (one bit per burst in flight)
logic [MAX_OUT-1:0]     lastq;
logic [PTR_BITS-1:0]    wp, rp;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        wp <= '0; rp <= '0;
    end
    else begin
        if (ar_fire) begin
            lastq[wp] <= final_burst && gen_last;
            wp <= (wp == PTR_BITS'(MAX_OUT - 1)) ? '0 : wp + 1;
        end
        if (r_end) rp <= (rp == PTR_BITS'(MAX_OUT - 1)) ? '0 : rp + 1;
    end
end

// ---------------------------------------------------------------- R channel -> stream
assign m_tdata      = m_axi.rdata;
assign m_tvalid     = m_axi.rvalid;
assign m_tlast      = m_axi.rlast && lastq[rp];
assign m_axi.rready = m_tready;

assign busy = gen_active || (n_out != 0);

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
