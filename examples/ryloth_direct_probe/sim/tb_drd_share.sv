// tb_drd_share (Ryloth B16, 2026-10-26): drd_share between a Coyote-like master (writes + reads, 64 IDs, W may lead
// AW) and a direct-port-like master (read bursts of 16), into an HBM-like slave (out of order across IDs, random
// stalls, at most 32 reads in flight). Checks: every read beat's data, every transaction completes, m-side valid and
// payload stable until ready, and the phases C only / D only / both / D streaming with sparse C.
`timescale 1ns / 1ps
module tb_drd_share;
localparam int AW = 34, DW = 256, IW = 6;
logic aclk = 0, aresetn = 0;
always #1.666 aclk = ~aclk;

// ------------------------------------------------------------------ signals
`define AXI_SIGS(p) \
  logic [AW-1:0] p``_araddr; logic [1:0] p``_arburst; logic [IW-1:0] p``_arid; logic [3:0] p``_arlen; logic [2:0] p``_arsize; logic p``_arvalid, p``_arready; \
  logic [AW-1:0] p``_awaddr; logic [1:0] p``_awburst; logic [IW-1:0] p``_awid; logic [3:0] p``_awlen; logic [2:0] p``_awsize; logic p``_awvalid, p``_awready; \
  logic [DW-1:0] p``_wdata; logic [DW/8-1:0] p``_wstrb; logic p``_wlast, p``_wvalid, p``_wready; \
  logic [IW-1:0] p``_bid; logic [1:0] p``_bresp; logic p``_bvalid, p``_bready; \
  logic [DW-1:0] p``_rdata; logic [IW-1:0] p``_rid; logic p``_rlast; logic [1:0] p``_rresp; logic p``_rvalid, p``_rready;
`AXI_SIGS(c)
`AXI_SIGS(d)
`AXI_SIGS(m)

drd_share #(.GRANT(8)) dut (
  .aclk(aclk), .aresetn(aresetn),
  .s_axi_c_araddr(c_araddr), .s_axi_c_arburst(c_arburst), .s_axi_c_arid(c_arid), .s_axi_c_arlen(c_arlen), .s_axi_c_arsize(c_arsize), .s_axi_c_arvalid(c_arvalid), .s_axi_c_arready(c_arready),
  .s_axi_c_awaddr(c_awaddr), .s_axi_c_awburst(c_awburst), .s_axi_c_awid(c_awid), .s_axi_c_awlen(c_awlen), .s_axi_c_awsize(c_awsize), .s_axi_c_awvalid(c_awvalid), .s_axi_c_awready(c_awready),
  .s_axi_c_wdata(c_wdata), .s_axi_c_wstrb(c_wstrb), .s_axi_c_wlast(c_wlast), .s_axi_c_wvalid(c_wvalid), .s_axi_c_wready(c_wready),
  .s_axi_c_bid(c_bid), .s_axi_c_bresp(c_bresp), .s_axi_c_bvalid(c_bvalid), .s_axi_c_bready(c_bready),
  .s_axi_c_rdata(c_rdata), .s_axi_c_rid(c_rid), .s_axi_c_rlast(c_rlast), .s_axi_c_rresp(c_rresp), .s_axi_c_rvalid(c_rvalid), .s_axi_c_rready(c_rready),
  .s_axi_d_araddr(d_araddr), .s_axi_d_arburst(d_arburst), .s_axi_d_arid(d_arid), .s_axi_d_arlen(d_arlen), .s_axi_d_arsize(d_arsize), .s_axi_d_arvalid(d_arvalid), .s_axi_d_arready(d_arready),
  .s_axi_d_awaddr(d_awaddr), .s_axi_d_awburst(d_awburst), .s_axi_d_awid(d_awid), .s_axi_d_awlen(d_awlen), .s_axi_d_awsize(d_awsize), .s_axi_d_awvalid(d_awvalid), .s_axi_d_awready(d_awready),
  .s_axi_d_wdata(d_wdata), .s_axi_d_wstrb(d_wstrb), .s_axi_d_wlast(d_wlast), .s_axi_d_wvalid(d_wvalid), .s_axi_d_wready(d_wready),
  .s_axi_d_bid(d_bid), .s_axi_d_bresp(d_bresp), .s_axi_d_bvalid(d_bvalid), .s_axi_d_bready(d_bready),
  .s_axi_d_rdata(d_rdata), .s_axi_d_rid(d_rid), .s_axi_d_rlast(d_rlast), .s_axi_d_rresp(d_rresp), .s_axi_d_rvalid(d_rvalid), .s_axi_d_rready(d_rready),
  .m_axi_araddr(m_araddr), .m_axi_arburst(m_arburst), .m_axi_arid(m_arid), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
  .m_axi_awaddr(m_awaddr), .m_axi_awburst(m_awburst), .m_axi_awid(m_awid), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
  .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast), .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
  .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
  .m_axi_rdata(m_rdata), .m_axi_rid(m_rid), .m_axi_rlast(m_rlast), .m_axi_rresp(m_rresp), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready));

// the direct side never writes
assign d_awvalid = 0; assign d_wvalid = 0; assign d_bready = 1;
assign d_awaddr = 0; assign d_awburst = 1; assign d_awid = 0; assign d_awlen = 0; assign d_awsize = 5; assign d_wdata = 0; assign d_wstrb = 0; assign d_wlast = 0;

int errors = 0, viol = 0, switches = 0;
function automatic logic [DW-1:0] pattern(logic [AW-1:0] a);
  logic [31:0] h; h = a[AW-1:5] * 32'h9E3779B1 ^ 32'h5bd1e995; return {8{h}};
endfunction

// ------------------------------------------------------------------ HBM-like slave
logic [DW-1:0] mem [logic [AW-1:5]];
typedef struct { logic [AW-1:0] addr; logic [3:0] len; logic [IW-1:0] id; } burst_t;
burst_t rqs [64][$];                   // per-ID read queues (order within an ID)
burst_t awq [$];
logic [DW-1:0] wq [$][$];              // completed W bursts, in order
logic [DW-1:0] wcur [$];
logic [IW-1:0] bq [$];
int r_out = 0;
int rid_cur = -1, rbeat = 0;
always @(posedge aclk) begin
  if (!aresetn) begin
    m_arready <= 0; m_awready <= 0; m_wready <= 0; m_rvalid <= 0; m_bvalid <= 0; rid_cur = -1;
  end else begin
    // AR
    if (m_arvalid && m_arready) begin burst_t b; b.addr = m_araddr; b.len = m_arlen; b.id = m_arid; rqs[m_arid].push_back(b); r_out++; end
    m_arready <= (r_out < 32) && ($urandom % 10 < 7);
    // AW / W
    if (m_awvalid && m_awready) begin burst_t b; b.addr = m_awaddr; b.len = m_awlen; b.id = m_awid; awq.push_back(b); end
    if (m_wvalid && m_wready) begin wcur.push_back(m_wdata); if (m_wlast) begin wq.push_back(wcur); wcur = {}; end end
    m_awready <= ($urandom % 10 < 6); m_wready <= ($urandom % 10 < 7);
    while (awq.size() > 0 && wq.size() > 0) begin
      burst_t b; logic [DW-1:0] w [$]; b = awq.pop_front(); w = wq.pop_front();
      if (w.size() != b.len + 1) begin $display("ERROR: W burst of %0d beats for AW len %0d", w.size(), b.len + 1); errors++; end
      for (int k = 0; k < w.size(); k++) mem[(b.addr >> 5) + k] = w[k];
      bq.push_back(b.id);
    end
    // B
    if (m_bvalid && m_bready) m_bvalid <= 0;
    if ((!m_bvalid || m_bready) && bq.size() > 0 && ($urandom % 4 != 0)) begin m_bid <= bq.pop_front(); m_bresp <= 0; m_bvalid <= 1; end
    // R: whole bursts, the next ID chosen at random among those waiting (out of order across IDs)
    if (m_rvalid && m_rready) begin
      if (m_rlast) begin void'(rqs[rid_cur].pop_front()); r_out--; rid_cur = -1; rbeat = 0; end else rbeat++;
    end
    if (!m_rvalid || m_rready) begin
      m_rvalid <= 0;
      if ($urandom % 10 < 8) begin
        if (rid_cur < 0) begin int pick[$]; pick.delete(); for (int i = 0; i < 64; i++) if (rqs[i].size() > 0) pick.push_back(i); if (pick.size() > 0) rid_cur = pick[$urandom % pick.size()]; end
        if (rid_cur >= 0) begin
          burst_t rb_; logic [AW-5-1:0] wa; rb_ = rqs[rid_cur][0]; wa = (rb_.addr >> 5) + rbeat;
          m_rdata <= mem.exists(wa) ? mem[wa] : pattern({wa, 5'b0}); m_rid <= rb_.id; m_rresp <= 0; m_rlast <= (rbeat == rb_.len); m_rvalid <= 1;
        end
      end
    end
  end
end

// ------------------------------------------------------------------ m-side stability (valid and payload held until ready)
logic pend_ar, pend_aw, pend_w; logic [AW+IW+3:0] ar_p, aw_p; logic [DW:0] w_p;
always @(posedge aclk) if (aresetn) begin
  if (pend_ar && (!m_arvalid || {m_araddr, m_arid, m_arlen} !== ar_p)) begin viol++; if (viol < 5) $display("VIOLATION: AR withdrawn or changed at %0t", $time); end
  if (pend_aw && (!m_awvalid || {m_awaddr, m_awid, m_awlen} !== aw_p)) begin viol++; if (viol < 5) $display("VIOLATION: AW withdrawn or changed at %0t", $time); end
  if (pend_w  && (!m_wvalid  || {m_wdata, m_wlast} !== w_p)) begin viol++; if (viol < 5) $display("VIOLATION: W withdrawn or changed at %0t", $time); end
  pend_ar <= m_arvalid && !m_arready; ar_p <= {m_araddr, m_arid, m_arlen};
  pend_aw <= m_awvalid && !m_awready; aw_p <= {m_awaddr, m_awid, m_awlen};
  pend_w  <= m_wvalid  && !m_wready;  w_p  <= {m_wdata, m_wlast};
end else begin pend_ar <= 0; pend_aw <= 0; pend_w <= 0; end
logic owner_q; always @(posedge aclk) begin owner_q <= dut.owner; if (aresetn && owner_q !== dut.owner) switches++; end

// ------------------------------------------------------------------ masters
int c_on = 0, d_on = 0;                // 0 off, 1 on (bursty), 2 sparse
int c_rd_issued = 0, c_rd_done = 0, c_wr_issued = 0, c_wr_done = 0, d_rd_issued = 0, d_rd_done = 0, d_beats = 0, c_beats = 0;
// Coyote: write jobs (AW and W channels independent, W may run ahead), reads of completed blocks or of untouched area
typedef struct { logic [AW-1:0] addr; logic [3:0] len; logic [IW-1:0] id; logic [DW-1:0] data [16]; } wjob_t;
wjob_t awjobs [$], wjobs [$];
logic [AW-1:0] done_blocks [$];
typedef struct { logic [AW-1:0] addr; logic [3:0] len; } rexp_t;
rexp_t c_exp [64][$]; rexp_t d_exp [64][$];
int c_rb [64]; int d_rb [64];
logic [DW-1:0] shadow [logic [AW-1:5]];
int wbeat = 0;
always @(posedge aclk) begin
  if (!aresetn) begin c_arvalid <= 0; c_awvalid <= 0; c_wvalid <= 0; c_bready <= 0; c_rready <= 0; for (int i = 0; i < 64; i++) c_rb[i] = 0; end
  else begin
    // new write job
    if (c_on != 0 && awjobs.size() < 4 && wjobs.size() < 6 && ($urandom % (c_on == 2 ? 400 : 6) == 0)) begin
      wjob_t j; j.addr = {($urandom % 4096), 5'b0} * 16; j.len = $urandom % 16; j.id = $urandom % 64;
      for (int k = 0; k < 16; k++) j.data[k] = {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom};
      awjobs.push_back(j); wjobs.push_back(j); c_wr_issued++;
    end
    // AW
    if (c_awvalid && c_awready) void'(awjobs.pop_front());
    if (!c_awvalid || c_awready) begin
      if (awjobs.size() > 0 && ($urandom % 3 != 0)) begin
        c_awaddr <= awjobs[0].addr; c_awlen <= awjobs[0].len; c_awid <= awjobs[0].id; c_awburst <= 1; c_awsize <= 5; c_awvalid <= 1;
      end else c_awvalid <= 0;
    end
    // W (independent of AW, so it may lead its AW)
    if (c_wvalid && c_wready) begin
      if (c_wlast) begin wjob_t j; j = wjobs.pop_front(); for (int k = 0; k <= j.len; k++) shadow[(j.addr >> 5) + k] = j.data[k]; wbeat = 0; end else wbeat++;
    end
    if (!c_wvalid || c_wready) begin
      if (wjobs.size() > 0 && ($urandom % 4 != 0)) begin
        c_wdata <= wjobs[0].data[wbeat]; c_wstrb <= '1; c_wlast <= (wbeat == wjobs[0].len); c_wvalid <= 1;
      end else c_wvalid <= 0;
    end
    // B
    c_bready <= ($urandom % 4 != 0);
    if (c_bvalid && c_bready) c_wr_done++;
    // reads
    if (c_arvalid && c_arready) c_arvalid <= 0;
    if (c_on != 0 && (!c_arvalid || c_arready) && ($urandom % (c_on == 2 ? 300 : 5) == 0)) begin
      rexp_t e; logic [IW-1:0] id; id = $urandom % 64; e.len = $urandom % 16;
      e.addr = {($urandom % 4096) + 8192, 5'b0} * 16;
      c_araddr <= e.addr; c_arlen <= e.len; c_arid <= id; c_arburst <= 1; c_arsize <= 5; c_arvalid <= 1; c_exp[id].push_back(e); c_rd_issued++;
    end
    c_rready <= ($urandom % 5 != 0);
    if (c_rvalid && c_rready) begin
      rexp_t e; logic [AW-5-1:0] wa; e = c_exp[c_rid][0]; wa = (e.addr >> 5) + c_rb[c_rid];
      if (c_rdata !== (shadow.exists(wa) ? shadow[wa] : pattern({wa, 5'b0}))) begin errors++; if (errors < 5) $display("ERROR: Coyote read data id %0d beat %0d", c_rid, c_rb[c_rid]); end
      if (c_rlast !== (c_rb[c_rid] == e.len)) begin errors++; if (errors < 4) $display("ERROR: Coyote rlast at %0t: rid %0d beat %0d exp len %0d addr %0h, slave rid %0d owner %0d, exp queue %0d", $time, c_rid, c_rb[c_rid], e.len, e.addr, m_rid, dut.owner, c_exp[c_rid].size()); end
      c_beats++;
      if (c_rlast) begin void'(c_exp[c_rid].pop_front()); c_rb[c_rid] = 0; c_rd_done++; end else c_rb[c_rid]++;
    end
  end
end
// direct: reads of 16 beats at 0x2_0000_0000.., IDs 0-1, at most 16 in flight
int d_inflight = 0;
always @(posedge aclk) begin
  if (!aresetn) begin d_arvalid <= 0; d_rready <= 0; for (int i = 0; i < 64; i++) d_rb[i] = 0; end
  else begin
    if (d_arvalid && d_arready) begin d_arvalid <= 0; d_inflight++; end
    if (d_on != 0 && (!d_arvalid || d_arready) && d_inflight + (d_arvalid ? 1 : 0) < 16 && ($urandom % (d_on == 1 ? 2 : 1) == 0)) begin
      rexp_t e; logic [IW-1:0] id; id = $urandom % 2; e.len = 15; e.addr = 34'h200000000 + ({$urandom % 65536, 9'b0});
      d_araddr <= e.addr; d_arlen <= e.len; d_arid <= id; d_arburst <= 1; d_arsize <= 5; d_arvalid <= 1; d_exp[id].push_back(e); d_rd_issued++;
    end
    d_rready <= (d_on == 3) ? 1'b1 : ($urandom % 6 != 0);
    if (d_rvalid && d_rready) begin
      rexp_t e; logic [AW-5-1:0] wa; e = d_exp[d_rid][0]; wa = (e.addr >> 5) + d_rb[d_rid];
      if (d_rdata !== pattern({wa, 5'b0})) begin errors++; if (errors < 5) $display("ERROR: direct read data id %0d beat %0d", d_rid, d_rb[d_rid]); end
      d_beats++;
      if (d_rlast) begin void'(d_exp[d_rid].pop_front()); d_rb[d_rid] = 0; d_rd_done++; d_inflight--; end else d_rb[d_rid]++;
    end
  end
end

task automatic drain(input int limit);
  int t; t = 0;
  while ((c_rd_done < c_rd_issued || c_wr_done < c_wr_issued || d_rd_done < d_rd_issued || awjobs.size() > 0 || wjobs.size() > 0) && t < limit) begin @(posedge aclk); t++; end
  if (t >= limit) begin errors++; $display("ERROR: drain timeout: C reads %0d/%0d writes %0d/%0d, direct reads %0d/%0d", c_rd_done, c_rd_issued, c_wr_done, c_wr_issued, d_rd_done, d_rd_issued); end
endtask

initial begin
  repeat (20) @(posedge aclk); aresetn = 1;
  c_on = 1; d_on = 0; repeat (20000) @(posedge aclk); c_on = 0; drain(60000);
  $display("P1 (Coyote only): writes %0d, reads %0d, switches %0d", c_wr_done, c_rd_done, switches);
  d_on = 1; repeat (20000) @(posedge aclk); d_on = 0; drain(60000);
  $display("P2 (direct only): reads %0d, switches %0d", d_rd_done, switches);
  c_on = 1; d_on = 1; repeat (60000) @(posedge aclk); c_on = 0; d_on = 0; drain(60000);
  $display("P3 (both, bursty): C writes %0d reads %0d, direct reads %0d, switches %0d", c_wr_done, c_rd_done, d_rd_done, switches);
  begin int b0, t0; b0 = d_beats; d_on = 3; c_on = 2; t0 = 0; repeat (40000) @(posedge aclk); d_on = 0; c_on = 0; drain(60000);
    $display("P4 (direct streaming, sparse Coyote): direct beats %0d in 40000 cycles (%.3f per cycle), switches %0d", d_beats - b0, (d_beats - b0) / 40000.0, switches); end
  foreach (shadow[a]) if (!mem.exists(a) || mem[a] !== shadow[a]) begin errors++; if (errors < 8) $display("ERROR: written word %0h not in memory", a); end
  $display("T: C writes %0d/%0d, C reads %0d/%0d (%0d beats), direct reads %0d/%0d (%0d beats), errors %0d, m-side violations %0d, switches %0d",
           c_wr_done, c_wr_issued, c_rd_done, c_rd_issued, c_beats, d_rd_done, d_rd_issued, d_beats, errors, viol, switches);
  $display("RESULT: %s", (errors == 0 && viol == 0 && switches > 2 && c_rd_done > 100 && d_rd_done > 100) ? "PASS" : "FAIL");
  $finish;
end
initial begin #20ms; $display("ERROR: global timeout"); $display("RESULT: FAIL"); $finish; end
endmodule
