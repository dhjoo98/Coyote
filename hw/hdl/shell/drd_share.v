/**
 * Ryloth B16 (2026-10-26): drd_share, one HBM AXI port shared by Coyote's memory path and a direct read port.
 *
 * With 16 direct read ports, direct ports 14 and 15 read windows 0 and 1, whose HBM ports (slots 0/16 and 1/17) also
 * carry Coyote's two memory paths (the host-transfer path and the card stream). The direct ports only read; Coyote
 * uses these ports for setup (index placement, migrations) and, in older partials, the card stream. The two are not
 * expected to run at the same time, so the port is TIME-MULTIPLEXED instead of interleaved: Coyote's RAMA already uses
 * all 6 HBM ID bits, so a source bit cannot be added to the IDs.
 *
 * Ownership: one side owns the port. The owner's requests pass through unchanged (IDs, bursts, order). When the other
 * side has a request and the owner has used its grant of GRANT bursts (or is not requesting), the owner stops starting
 * new bursts, its transactions in flight drain (reads: every R last back; writes: every W burst sent and every B back),
 * and ownership changes. All R beats and B responses therefore belong to the current owner. A request already offered
 * to the HBM port is never withdrawn (AXI: valid stays until ready): the hold registers keep its channel open.
 * The direct side is read-only: its write channels are refused (awready/wready 0, no B).
 *
 * Clock: the HBM port clock (HCLK). Coyote's path reaches it through a clock converter, the direct path is on HCLK.
 * Verilog-2001 for the block design's module reference.
 */
`timescale 1ns / 1ps
module drd_share #(
    parameter integer GRANT = 32,      // bursts the owner may start while the other side waits
    parameter integer CNT_BITS = 10    // outstanding-transaction counters
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK", X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi_c:s_axi_d:m_axi, ASSOCIATED_RESET aresetn" *)
    input  wire          aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST", X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire          aresetn,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c ARADDR", X_INTERFACE_PARAMETER = "PROTOCOL AXI3, ADDR_WIDTH 34, DATA_WIDTH 256, ID_WIDTH 6, READ_WRITE_MODE READ_WRITE, HAS_BURST 1, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, MAX_BURST_LENGTH 16, NUM_READ_OUTSTANDING 32, NUM_WRITE_OUTSTANDING 32, SUPPORTS_NARROW_BURST 0" *)
    input  wire [33:0]   s_axi_c_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c ARBURST" *)
    input  wire [1:0]    s_axi_c_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c ARID" *)
    input  wire [5:0]    s_axi_c_arid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c ARLEN" *)
    input  wire [3:0]    s_axi_c_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c ARSIZE" *)
    input  wire [2:0]    s_axi_c_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c ARVALID" *)
    input  wire          s_axi_c_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c ARREADY" *)
    output wire          s_axi_c_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c AWADDR" *)
    input  wire [33:0]   s_axi_c_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c AWBURST" *)
    input  wire [1:0]    s_axi_c_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c AWID" *)
    input  wire [5:0]    s_axi_c_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c AWLEN" *)
    input  wire [3:0]    s_axi_c_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c AWSIZE" *)
    input  wire [2:0]    s_axi_c_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c AWVALID" *)
    input  wire          s_axi_c_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c AWREADY" *)
    output wire          s_axi_c_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c WDATA" *)
    input  wire [255:0]  s_axi_c_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c WSTRB" *)
    input  wire [31:0]   s_axi_c_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c WLAST" *)
    input  wire          s_axi_c_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c WVALID" *)
    input  wire          s_axi_c_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c WREADY" *)
    output wire          s_axi_c_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c BID" *)
    output wire [5:0]    s_axi_c_bid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c BRESP" *)
    output wire [1:0]    s_axi_c_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c BVALID" *)
    output wire          s_axi_c_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c BREADY" *)
    input  wire          s_axi_c_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c RDATA" *)
    output wire [255:0]  s_axi_c_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c RID" *)
    output wire [5:0]    s_axi_c_rid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c RLAST" *)
    output wire          s_axi_c_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c RRESP" *)
    output wire [1:0]    s_axi_c_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c RVALID" *)
    output wire          s_axi_c_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_c RREADY" *)
    input  wire          s_axi_c_rready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d ARADDR", X_INTERFACE_PARAMETER = "PROTOCOL AXI3, ADDR_WIDTH 34, DATA_WIDTH 256, ID_WIDTH 6, READ_WRITE_MODE READ_WRITE, HAS_BURST 1, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, MAX_BURST_LENGTH 16, NUM_READ_OUTSTANDING 32, NUM_WRITE_OUTSTANDING 32, SUPPORTS_NARROW_BURST 0" *)
    input  wire [33:0]   s_axi_d_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d ARBURST" *)
    input  wire [1:0]    s_axi_d_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d ARID" *)
    input  wire [5:0]    s_axi_d_arid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d ARLEN" *)
    input  wire [3:0]    s_axi_d_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d ARSIZE" *)
    input  wire [2:0]    s_axi_d_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d ARVALID" *)
    input  wire          s_axi_d_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d ARREADY" *)
    output wire          s_axi_d_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d AWADDR" *)
    input  wire [33:0]   s_axi_d_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d AWBURST" *)
    input  wire [1:0]    s_axi_d_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d AWID" *)
    input  wire [5:0]    s_axi_d_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d AWLEN" *)
    input  wire [3:0]    s_axi_d_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d AWSIZE" *)
    input  wire [2:0]    s_axi_d_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d AWVALID" *)
    input  wire          s_axi_d_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d AWREADY" *)
    output wire          s_axi_d_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d WDATA" *)
    input  wire [255:0]  s_axi_d_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d WSTRB" *)
    input  wire [31:0]   s_axi_d_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d WLAST" *)
    input  wire          s_axi_d_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d WVALID" *)
    input  wire          s_axi_d_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d WREADY" *)
    output wire          s_axi_d_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d BID" *)
    output wire [5:0]    s_axi_d_bid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d BRESP" *)
    output wire [1:0]    s_axi_d_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d BVALID" *)
    output wire          s_axi_d_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d BREADY" *)
    input  wire          s_axi_d_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d RDATA" *)
    output wire [255:0]  s_axi_d_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d RID" *)
    output wire [5:0]    s_axi_d_rid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d RLAST" *)
    output wire          s_axi_d_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d RRESP" *)
    output wire [1:0]    s_axi_d_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d RVALID" *)
    output wire          s_axi_d_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_d RREADY" *)
    input  wire          s_axi_d_rready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARADDR", X_INTERFACE_PARAMETER = "PROTOCOL AXI3, ADDR_WIDTH 34, DATA_WIDTH 256, ID_WIDTH 6, READ_WRITE_MODE READ_WRITE, HAS_BURST 1, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, MAX_BURST_LENGTH 16, NUM_READ_OUTSTANDING 32, NUM_WRITE_OUTSTANDING 32, SUPPORTS_NARROW_BURST 0" *)
    output wire [33:0]   m_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARBURST" *)
    output wire [1:0]    m_axi_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARID" *)
    output wire [5:0]    m_axi_arid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARLEN" *)
    output wire [3:0]    m_axi_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARSIZE" *)
    output wire [2:0]    m_axi_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARVALID" *)
    output wire          m_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARREADY" *)
    input  wire          m_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWADDR" *)
    output wire [33:0]   m_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWBURST" *)
    output wire [1:0]    m_axi_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWID" *)
    output wire [5:0]    m_axi_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWLEN" *)
    output wire [3:0]    m_axi_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWSIZE" *)
    output wire [2:0]    m_axi_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWVALID" *)
    output wire          m_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWREADY" *)
    input  wire          m_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WDATA" *)
    output wire [255:0]  m_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WSTRB" *)
    output wire [31:0]   m_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WLAST" *)
    output wire          m_axi_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WVALID" *)
    output wire          m_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WREADY" *)
    input  wire          m_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BID" *)
    input  wire [5:0]    m_axi_bid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BRESP" *)
    input  wire [1:0]    m_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BVALID" *)
    input  wire          m_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BREADY" *)
    output wire          m_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RDATA" *)
    input  wire [255:0]  m_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RID" *)
    input  wire [5:0]    m_axi_rid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RLAST" *)
    input  wire          m_axi_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RRESP" *)
    input  wire [1:0]    m_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RVALID" *)
    input  wire          m_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RREADY" *)
    output wire          m_axi_rready
);

localparam OWN_C = 1'b0, OWN_D = 1'b1;

reg                       owner;            // OWN_C: Coyote path, OWN_D: direct path
reg  [CNT_BITS-1:0]       c_ar_out;         // Coyote reads in flight (AR accepted, R last not yet)
reg  [CNT_BITS-1:0]       c_aw_out;         // Coyote writes in flight (AW accepted, B not yet)
reg  signed [CNT_BITS:0]  c_w_aw;           // W bursts completed minus AW accepted (AXI3 allows W before AW)
reg                       c_w_inburst;      // a W burst has started and not reached wlast
reg  [CNT_BITS-1:0]       d_ar_out;         // direct reads in flight
reg  [7:0]                grant;            // bursts the owner may still start while the other side waits
reg                       c_ar_hold, c_aw_hold, c_w_hold, d_ar_hold;   // offered to the HBM port last cycle, not taken

wire c_req      = s_axi_c_arvalid | s_axi_c_awvalid | s_axi_c_wvalid;
wire d_req      = s_axi_d_arvalid;
wire own_req    = (owner == OWN_D) ? d_req : c_req;
wire other_req  = (owner == OWN_D) ? c_req : d_req;
wire yield      = other_req & (grant == 8'd0);
wire c_idle     = (c_ar_out == 0) & (c_aw_out == 0) & (c_w_aw == 0) & ~c_w_inburst & ~c_ar_hold & ~c_aw_hold & ~c_w_hold;
wire d_idle     = (d_ar_out == 0) & ~d_ar_hold;
wire own_idle   = (owner == OWN_D) ? d_idle : c_idle;
wire do_switch  = own_idle & other_req & (yield | ~own_req);

// channel enables: no new burst from the owner while it yields, except what it owes (AW for W already sent, the rest
// of a W burst, W for an AW already sent) and what it has already offered (hold)
wire c_ar_en = (owner == OWN_C) & ~do_switch & (~yield | c_ar_hold);
wire c_aw_en = (owner == OWN_C) & ~do_switch & (~yield | c_aw_hold | (c_w_aw > 0));
wire c_w_en  = (owner == OWN_C) & ~do_switch & (~yield | c_w_hold | c_w_inburst | (c_w_aw < 0));
wire d_ar_en = (owner == OWN_D) & ~do_switch & (~yield | d_ar_hold);

// AR: from the owner
assign m_axi_arvalid = (owner == OWN_D) ? (s_axi_d_arvalid & d_ar_en) : (s_axi_c_arvalid & c_ar_en);
assign m_axi_araddr  = (owner == OWN_D) ? s_axi_d_araddr  : s_axi_c_araddr;
assign m_axi_arburst = (owner == OWN_D) ? s_axi_d_arburst : s_axi_c_arburst;
assign m_axi_arid    = (owner == OWN_D) ? s_axi_d_arid    : s_axi_c_arid;
assign m_axi_arlen   = (owner == OWN_D) ? s_axi_d_arlen   : s_axi_c_arlen;
assign m_axi_arsize  = (owner == OWN_D) ? s_axi_d_arsize  : s_axi_c_arsize;
assign s_axi_c_arready = c_ar_en & m_axi_arready;
assign s_axi_d_arready = d_ar_en & m_axi_arready;

// AW, W, B: Coyote only
assign m_axi_awvalid = s_axi_c_awvalid & c_aw_en;
assign m_axi_awaddr  = s_axi_c_awaddr;
assign m_axi_awburst = s_axi_c_awburst;
assign m_axi_awid    = s_axi_c_awid;
assign m_axi_awlen   = s_axi_c_awlen;
assign m_axi_awsize  = s_axi_c_awsize;
assign s_axi_c_awready = c_aw_en & m_axi_awready;
assign m_axi_wvalid  = s_axi_c_wvalid & c_w_en;
assign m_axi_wdata   = s_axi_c_wdata;
assign m_axi_wstrb   = s_axi_c_wstrb;
assign m_axi_wlast   = s_axi_c_wlast;
assign s_axi_c_wready = c_w_en & m_axi_wready;
assign s_axi_c_bvalid = m_axi_bvalid;
assign s_axi_c_bid    = m_axi_bid;
assign s_axi_c_bresp  = m_axi_bresp;
assign m_axi_bready   = s_axi_c_bready;

// R: to the owner (every beat in flight is the owner's)
assign s_axi_c_rvalid = m_axi_rvalid & (owner == OWN_C);
assign s_axi_d_rvalid = m_axi_rvalid & (owner == OWN_D);
assign s_axi_c_rdata  = m_axi_rdata;  assign s_axi_d_rdata  = m_axi_rdata;
assign s_axi_c_rid    = m_axi_rid;    assign s_axi_d_rid    = m_axi_rid;
assign s_axi_c_rlast  = m_axi_rlast;  assign s_axi_d_rlast  = m_axi_rlast;
assign s_axi_c_rresp  = m_axi_rresp;  assign s_axi_d_rresp  = m_axi_rresp;
assign m_axi_rready   = (owner == OWN_D) ? s_axi_d_rready : s_axi_c_rready;

// the direct side never writes
assign s_axi_d_awready = 1'b0;
assign s_axi_d_wready  = 1'b0;
assign s_axi_d_bvalid  = 1'b0;
assign s_axi_d_bid     = {6{1'b0}};
assign s_axi_d_bresp   = 2'b00;

wire c_ar_hs = s_axi_c_arvalid & s_axi_c_arready;
wire c_aw_hs = s_axi_c_awvalid & s_axi_c_awready;
wire c_w_hs  = s_axi_c_wvalid  & s_axi_c_wready;
wire c_b_hs  = s_axi_c_bvalid  & s_axi_c_bready;
wire c_rl_hs = s_axi_c_rvalid  & s_axi_c_rready & m_axi_rlast;
wire d_ar_hs = s_axi_d_arvalid & s_axi_d_arready;
wire d_rl_hs = s_axi_d_rvalid  & s_axi_d_rready & m_axi_rlast;

always @(posedge aclk) begin
    if (!aresetn) begin
        owner <= OWN_C; grant <= GRANT[7:0];
        c_ar_out <= 0; c_aw_out <= 0; c_w_aw <= 0; c_w_inburst <= 1'b0; d_ar_out <= 0;
        c_ar_hold <= 1'b0; c_aw_hold <= 1'b0; c_w_hold <= 1'b0; d_ar_hold <= 1'b0;
    end else begin
        c_ar_out <= c_ar_out + (c_ar_hs ? 1 : 0) - (c_rl_hs ? 1 : 0);
        c_aw_out <= c_aw_out + (c_aw_hs ? 1 : 0) - (c_b_hs ? 1 : 0);
        c_w_aw   <= c_w_aw + ((c_w_hs & s_axi_c_wlast) ? 1 : 0) - (c_aw_hs ? 1 : 0);
        if (c_w_hs) c_w_inburst <= ~s_axi_c_wlast;
        d_ar_out <= d_ar_out + (d_ar_hs ? 1 : 0) - (d_rl_hs ? 1 : 0);
        c_ar_hold <= m_axi_arvalid & ~m_axi_arready & (owner == OWN_C);
        d_ar_hold <= m_axi_arvalid & ~m_axi_arready & (owner == OWN_D);
        c_aw_hold <= m_axi_awvalid & ~m_axi_awready;
        c_w_hold  <= m_axi_wvalid  & ~m_axi_wready;
        if (do_switch) begin
            owner <= ~owner; grant <= GRANT[7:0];
        end else if ((c_ar_hs | c_aw_hs | d_ar_hs) & other_req & (grant != 8'd0)) begin
            grant <= grant - 8'd1;
        end else if (~other_req) begin
            grant <= GRANT[7:0];
        end
    end
end

endmodule

