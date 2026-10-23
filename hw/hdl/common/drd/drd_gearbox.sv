/**
 * Ryloth direct read ports, scaling step B (2026-10-22 night): read-only AXI gearbox between a 1024-bit direct port at
 * ACLK (user side, s_axi) and a 512-bit port at HCLK = 2 x ACLK (memory side, m_axi). Both sides move the same bytes per
 * second (128 B x ACLK = 64 B x HCLK), so the HBM side runs at twice the user clock while the user region stays at ACLK.
 *
 * AR (ACLK -> HCLK): one async FIFO entry per request; the length doubles (a 128-byte beat is two 64-byte beats), the
 * address is unchanged (requests are 128-byte aligned by the reader).
 * R (HCLK -> ACLK): two consecutive 512-bit beats of a burst are packed into one 1024-bit beat (the first beat is the
 * lower address, i.e. bits [511:0]) and written as one entry of an async FIFO; rlast is the second beat's. Bursts are
 * whole 128-byte beats, so the pairing never straddles a burst.
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
localparam integer R_BITS  = 1024 + 3;   // {rresp, rlast, data}

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

// ---------------------------------------------------------------- R: HCLK -> ACLK, two 512-bit beats per entry
logic                   r_full, r_empty, r_wr_busy, r_rd_busy;
logic [R_BITS-1:0]      r_dout;
logic                   half_valid;
logic [511:0]           half_data;
logic [1:0]             half_resp;

wire r_fire = m_axi.rvalid && m_axi.rready;
wire r_wr   = r_fire && half_valid;
assign m_axi.rready = !r_full && !r_wr_busy;

always_ff @(posedge hclk) begin
    if (!hresetn) half_valid <= 1'b0;
    else if (r_fire) half_valid <= !half_valid;
end
always_ff @(posedge hclk) begin
    if (r_fire && !half_valid) begin half_data <= m_axi.rdata; half_resp <= m_axi.rresp; end
end

xpm_fifo_async #(
    .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(32), .WRITE_DATA_WIDTH(R_BITS), .READ_DATA_WIDTH(R_BITS),
    .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .CDC_SYNC_STAGES(2), .ECC_MODE("no_ecc"), .RELATED_CLOCKS(0),
    .USE_ADV_FEATURES("0000"), .WAKEUP_TIME(0), .DOUT_RESET_VALUE("0"), .FULL_RESET_VALUE(1)
) inst_r_fifo (
    .wr_clk(hclk), .rst(!hresetn), .wr_en(r_wr), .din({half_resp | m_axi.rresp, m_axi.rlast, m_axi.rdata, half_data}),
    .full(r_full), .wr_rst_busy(r_wr_busy),
    .rd_clk(aclk), .rd_en(s_axi.rvalid && s_axi.rready), .dout(r_dout), .empty(r_empty), .rd_rst_busy(r_rd_busy),
    .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
    .overflow(), .prog_full(), .wr_data_count(), .almost_full(), .wr_ack(), .underflow(), .prog_empty(),
    .rd_data_count(), .almost_empty(), .data_valid(), .sbiterr(), .dbiterr()
);

assign s_axi.rvalid = !r_empty && !r_rd_busy;
assign s_axi.rdata  = r_dout[1023:0];
assign s_axi.rlast  = r_dout[1024];
assign s_axi.rresp  = r_dout[1026:1025];
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
