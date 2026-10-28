/**
 * Ryloth direct read ports, scaling step B (2026-10-22 night): read-only AXI gearbox between a 1024-bit direct port at
 * ACLK (user side, s_axi) and a 512-bit port at HCLK = 2 x ACLK (memory side, m_axi). Both sides move the same bytes per
 * second (128 B x ACLK = 64 B x HCLK), so the HBM side runs at twice the user clock while the user region stays at ACLK.
 *
 * AR (ACLK -> HCLK): one async FIFO entry per request; the length doubles (a 128-byte beat is two 64-byte beats), the
 * address is unchanged (requests are 128-byte aligned by the reader).
 * R (HCLK -> ACLK): the beats of a burst alternate between two 515-bit FIFO groups (even beats = lower address =
 * bits [511:0], odd beats = bits [1023:512]; each group is R_SUB async FIFOs side by side, 10/26); the ACLK side pops
 * both at once as one 1024-bit beat, rlast from the odd one. Bursts are whole 128-byte beats, so the pairing never
 * straddles a burst. Each beat is registered before its FIFO write and back-pressure comes from the FIFOs'
 * programmable-full flags (with room for the registered beats), so no combinational path runs from the upstream valid
 * into the FIFO write enables. (The first version wrote one 1027-bit
 * FIFO from a pairing register and missed 300 MHz on that write enable's fan-out: drd14w, 10/23 02:55.)
 *
 * Back-pressure: the user-side reader (drd_reader) reserves space for every beat it requests and always accepts R, so
 * this FIFO drains at the rate it fills. If it ever filled, the stall would reach hbm_wide_rd's per-stack FIFOs, which
 * hold all of a reader's bursts in flight (max_out x 16 beats <= 128), so the HBM ports are never stalled either.
 * Only the XPM FIFOs cross clocks (their own CDC constraints apply).
 */

`timescale 1ns / 1ps

module drd_gearbox #(
    parameter integer ADDR_BITS = 34
) (
    input  logic            aclk,
    input  logic            aresetn,
    input  logic            hclk,
    input  logic            hresetn,     // synchronized to hclk
    AXI4.s                  s_axi,       // 1024 bits, ACLK
    AXI4.m                  m_axi        // 512 bits, HCLK
);

localparam integer AR_BITS = ADDR_BITS + 8;
localparam integer R_BITS  = 512 + 3;    // {rresp, rlast, data} per half

// ---------------------------------------------------------------- AR: ACLK -> HCLK
logic                   ar_full, ar_empty, ar_wr_busy, ar_rd_busy;
logic [AR_BITS-1:0]     ar_dout;

wire ar_wr = s_axi.arvalid && s_axi.arready;
assign s_axi.arready = !ar_full && !ar_wr_busy;

xpm_fifo_async #(
    .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(16), .WRITE_DATA_WIDTH(AR_BITS), .READ_DATA_WIDTH(AR_BITS),
    .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .CDC_SYNC_STAGES(2), .ECC_MODE("no_ecc"), .RELATED_CLOCKS(0),
    .USE_ADV_FEATURES("0000"), .WAKEUP_TIME(0), .DOUT_RESET_VALUE("0"), .FULL_RESET_VALUE(1)
) inst_ar_fifo (
    .wr_clk(aclk), .rst(!aresetn), .wr_en(ar_wr), .din({s_axi.araddr[ADDR_BITS-1:0], s_axi.arlen}),
    .full(ar_full), .wr_rst_busy(ar_wr_busy),
    .rd_clk(hclk), .rd_en(m_axi.arvalid && m_axi.arready), .dout(ar_dout), .empty(ar_empty), .rd_rst_busy(ar_rd_busy),
    .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
    .overflow(), .prog_full(), .wr_data_count(), .almost_full(), .wr_ack(), .underflow(), .prog_empty(),
    .rd_data_count(), .almost_empty(), .data_valid(), .sbiterr(), .dbiterr()
);

assign m_axi.arvalid  = !ar_empty && !ar_rd_busy;
assign m_axi.araddr   = {{(64-ADDR_BITS){1'b0}}, ar_dout[AR_BITS-1:8]};
assign m_axi.arlen    = {ar_dout[6:0], 1'b1};          // 2 x (len + 1) - 1; reader bursts are <= 8 beats of 128 B
assign m_axi.arburst  = 2'b01;
assign m_axi.arcache  = 4'b0011;
assign m_axi.arid     = 0;
assign m_axi.arlock   = 1'b0;
assign m_axi.arprot   = 3'b010;
assign m_axi.arqos    = 4'b0;
assign m_axi.arregion = 4'b0;
assign m_axi.arsize   = 3'b110;

// ---------------------------------------------------------------- R: HCLK -> ACLK, even / odd beats in two FIFO groups
// B16 (10/26): drd16w's PR pass missed 300 MHz (-0.62 ns, 12.5k endpoints) on these FIFOs' writes. With SLR1 row 4's
// LUTRAM sites taken, each 515-bit FIFO's 37 LUTRAMs were scattered over two or three clock regions, and its write
// pointer, write enable and data had to reach all of them. Each half is now R_SUB narrower FIFOs written in lockstep, each
// with its own write-enable and data registers (kept apart from their equivalents in synthesis), so one write pointer
// drives at most 10 LUTRAMs, which can sit together. They stay aligned: every FIFO of a half sees the same writes in the
// same cycles, none ever fills (programmable full, below), and the ACLK side pops all of them only when none is empty.
// rready is registered. From rready to a FIFO write: rready -> r_q -> p_data -> write, at most 3 beats more after a
// programmable-full flag rises (and 2 per half), against 10 free entries above PROG_FULL_THRESH 22 of 32.
localparam integer R_SUB    = 4;
localparam integer SUB_BITS = 140;      // 10 LUTRAMs of 14 bits; the last FIFO takes the remaining 95 bits (7 LUTRAMs)

logic                   r_q_vld, r_q_odd, r_odd, rready_q;
logic [R_BITS-1:0]      r_q_data;
logic [2*R_SUB-1:0]     pf, wr_busy, rd_busy, empty;
logic [R_BITS-1:0]      dout [2];

wire r_fire = m_axi.rvalid && m_axi.rready;
assign m_axi.rready = rready_q;

always_ff @(posedge hclk) r_q_data <= {m_axi.rresp, m_axi.rlast, m_axi.rdata};   // no enable: loaded every cycle
always_ff @(posedge hclk) begin
    if (!hresetn) begin r_q_vld <= 1'b0; r_q_odd <= 1'b0; r_odd <= 1'b0; rready_q <= 1'b0; end
    else begin
        r_q_vld  <= r_fire;
        r_q_odd  <= r_odd;
        if (r_fire) r_odd <= ~r_odd;
        rready_q <= !(|pf) && !(|wr_busy);
    end
end

wire pop = s_axi.rvalid && s_axi.rready;
for (genvar h = 0; h < 2; h++) begin : g_half
    for (genvar k = 0; k < R_SUB; k++) begin : g_sub
        localparam integer LO = k * SUB_BITS;
        localparam integer W  = (k == R_SUB - 1) ? R_BITS - LO : SUB_BITS;
        (* keep = "true" *)       logic [W-1:0] p_data;   // no enable: loaded every cycle
        (* dont_touch = "true" *) logic         p_wr;
        always_ff @(posedge hclk) p_data <= r_q_data[LO +: W];
        always_ff @(posedge hclk) p_wr   <= hresetn && r_q_vld && (r_q_odd == h);

        xpm_fifo_async #(
            .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(32), .WRITE_DATA_WIDTH(W), .READ_DATA_WIDTH(W),
            .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .CDC_SYNC_STAGES(2), .ECC_MODE("no_ecc"), .RELATED_CLOCKS(0),
            .USE_ADV_FEATURES("0002"), .PROG_FULL_THRESH(22), .WAKEUP_TIME(0), .DOUT_RESET_VALUE("0"), .FULL_RESET_VALUE(1)
        ) inst_r_fifo (
            .wr_clk(hclk), .rst(!hresetn), .wr_en(p_wr), .din(p_data),
            .full(), .prog_full(pf[h*R_SUB+k]), .wr_rst_busy(wr_busy[h*R_SUB+k]),
            .rd_clk(aclk), .rd_en(pop), .dout(dout[h][LO +: W]), .empty(empty[h*R_SUB+k]), .rd_rst_busy(rd_busy[h*R_SUB+k]),
            .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
            .overflow(), .wr_data_count(), .almost_full(), .wr_ack(), .underflow(), .prog_empty(),
            .rd_data_count(), .almost_empty(), .data_valid(), .sbiterr(), .dbiterr()
        );
    end
end

assign s_axi.rvalid = !(|empty) && !(|rd_busy);
assign s_axi.rdata  = {dout[1][511:0], dout[0][511:0]};
assign s_axi.rlast  = dout[1][512];
assign s_axi.rresp  = dout[0][514:513] | dout[1][514:513];
assign s_axi.rid    = 0;

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
assign s_axi.awready  = 1'b0;
assign s_axi.wready   = 1'b0;
assign s_axi.bvalid   = 1'b0;
assign s_axi.bresp    = 2'b0;
assign s_axi.bid      = 0;

endmodule
