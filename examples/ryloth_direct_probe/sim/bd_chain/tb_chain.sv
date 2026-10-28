// Ryloth B16 (10/26): block-design test of Coyote's memory path into a shared HBM port (chain.bd: Coyote's path cell
// with RAMA, cc_sh 225 -> 300, drd_share, register slice). S_AXI (ACLK 150): Coyote-like master as hbm_wide's output
// (AXI4, 256 bits, 1-bit ID, bursts of 1-64 beats inside 4 KiB); D_AXI (HCLK 300): direct-port-like reader (AXI3 16-beat
// reads); M_AXI (HCLK): HBM-like memory (AXI3, 6-bit IDs, out of order across IDs, random stalls). Checks: every write
// completes (B), every read returns the written data, the direct side's data, memory contents; no hang.
`timescale 1ns / 1ps
module tb_chain;
localparam int DW = 256;
logic aclk = 0, cclk = 0, hclk = 0, aresetn = 0, cresetn = 0, hresetn = 0;
always #3.3333 aclk = ~aclk;
always #2.2222 cclk = ~cclk;
initial begin #0.4; forever #1.6667 hclk = ~hclk; end

// S_AXI (Coyote side)
logic [63:0] s_araddr, s_awaddr; logic [7:0] s_arlen, s_awlen; logic s_arvalid, s_arready, s_awvalid, s_awready;
logic [DW-1:0] s_wdata; logic s_wlast, s_wvalid, s_wready; logic [0:0] s_bid; logic [1:0] s_bresp; logic s_bvalid, s_bready;
logic [DW-1:0] s_rdata; logic [0:0] s_rid; logic s_rlast; logic [1:0] s_rresp; logic s_rvalid, s_rready;
// D_AXI (direct side)
logic [33:0] d_araddr; logic [3:0] d_arlen; logic [5:0] d_arid; logic d_arvalid, d_arready;
logic [DW-1:0] d_rdata; logic [5:0] d_rid; logic d_rlast; logic [1:0] d_rresp; logic d_rvalid, d_rready;
// M_AXI (HBM side)
logic [33:0] m_araddr, m_awaddr; logic [3:0] m_arlen, m_awlen; logic [5:0] m_arid, m_awid, m_wid; logic m_arvalid, m_arready, m_awvalid, m_awready;
logic [DW-1:0] m_wdata; logic [31:0] m_wstrb; logic m_wlast, m_wvalid, m_wready; logic [5:0] m_bid; logic [1:0] m_bresp; logic m_bvalid, m_bready;
logic [DW-1:0] m_rdata; logic [5:0] m_rid; logic m_rlast; logic [1:0] m_rresp; logic m_rvalid, m_rready;
logic [1:0] m_arburst, m_awburst; logic [2:0] m_arsize, m_awsize;

chain_wrapper dut (
  .aclk(aclk), .aresetn(aresetn), .cclk(cclk), .cresetn(cresetn), .hclk(hclk), .hresetn(hresetn),
  .S_AXI_araddr(s_araddr), .S_AXI_arburst(2'b01), .S_AXI_arcache(4'b0), .S_AXI_arid(1'b0), .S_AXI_arlen(s_arlen), .S_AXI_arlock(1'b0),
  .S_AXI_arprot(3'b0), .S_AXI_arqos(4'b0), .S_AXI_arready(s_arready), .S_AXI_arregion(4'b0), .S_AXI_arsize(3'd5), .S_AXI_arvalid(s_arvalid),
  .S_AXI_awaddr(s_awaddr), .S_AXI_awburst(2'b01), .S_AXI_awcache(4'b0), .S_AXI_awid(1'b0), .S_AXI_awlen(s_awlen), .S_AXI_awlock(1'b0),
  .S_AXI_awprot(3'b0), .S_AXI_awqos(4'b0), .S_AXI_awready(s_awready), .S_AXI_awregion(4'b0), .S_AXI_awsize(3'd5), .S_AXI_awvalid(s_awvalid),
  .S_AXI_bid(s_bid), .S_AXI_bready(s_bready), .S_AXI_bresp(s_bresp), .S_AXI_bvalid(s_bvalid),
  .S_AXI_rdata(s_rdata), .S_AXI_rid(s_rid), .S_AXI_rlast(s_rlast), .S_AXI_rready(s_rready), .S_AXI_rresp(s_rresp), .S_AXI_rvalid(s_rvalid),
  .S_AXI_wdata(s_wdata), .S_AXI_wlast(s_wlast), .S_AXI_wready(s_wready), .S_AXI_wstrb({32{1'b1}}), .S_AXI_wvalid(s_wvalid),
  .D_AXI_araddr(d_araddr), .D_AXI_arburst(2'b01), .D_AXI_arid(d_arid), .D_AXI_arlen(d_arlen), .D_AXI_arready(d_arready), .D_AXI_arsize(3'd5), .D_AXI_arvalid(d_arvalid),
  .D_AXI_awaddr(34'b0), .D_AXI_awburst(2'b01), .D_AXI_awid(6'b0), .D_AXI_awlen(4'b0), .D_AXI_awready(), .D_AXI_awsize(3'd5), .D_AXI_awvalid(1'b0),
  .D_AXI_bid(), .D_AXI_bready(1'b1), .D_AXI_bresp(), .D_AXI_bvalid(),
  .D_AXI_rdata(d_rdata), .D_AXI_rid(d_rid), .D_AXI_rlast(d_rlast), .D_AXI_rready(d_rready), .D_AXI_rresp(d_rresp), .D_AXI_rvalid(d_rvalid),
  .D_AXI_wdata({DW{1'b0}}), .D_AXI_wlast(1'b0), .D_AXI_wready(), .D_AXI_wstrb(32'b0), .D_AXI_wvalid(1'b0),
  .M_AXI_araddr(m_araddr), .M_AXI_arburst(m_arburst), .M_AXI_arcache(), .M_AXI_arid(m_arid), .M_AXI_arlen(m_arlen), .M_AXI_arlock(),
  .M_AXI_arprot(), .M_AXI_arqos(), .M_AXI_arready(m_arready), .M_AXI_arsize(m_arsize), .M_AXI_arvalid(m_arvalid),
  .M_AXI_awaddr(m_awaddr), .M_AXI_awburst(m_awburst), .M_AXI_awcache(), .M_AXI_awid(m_awid), .M_AXI_awlen(m_awlen), .M_AXI_awlock(),
  .M_AXI_awprot(), .M_AXI_awqos(), .M_AXI_awready(m_awready), .M_AXI_awsize(m_awsize), .M_AXI_awvalid(m_awvalid),
  .M_AXI_bid(m_bid), .M_AXI_bready(m_bready), .M_AXI_bresp(m_bresp), .M_AXI_bvalid(m_bvalid),
  .M_AXI_rdata(m_rdata), .M_AXI_rid(m_rid), .M_AXI_rlast(m_rlast), .M_AXI_rready(m_rready), .M_AXI_rresp(m_rresp), .M_AXI_rvalid(m_rvalid),
  .M_AXI_wdata(m_wdata), .M_AXI_wid(m_wid), .M_AXI_wlast(m_wlast), .M_AXI_wready(m_wready), .M_AXI_wstrb(m_wstrb), .M_AXI_wvalid(m_wvalid));

int errors = 0;
function automatic logic [DW-1:0] pattern(logic [33:0] a);
  logic [31:0] h; h = a[33:5] * 32'h9E3779B1 ^ 32'h5bd1e995; return {8{h}};
endfunction

// ------------------------------------------------------------------ HBM-like memory (HCLK)
logic [DW-1:0] mem [logic [33:5]];
typedef struct { logic [33:0] addr; logic [3:0] len; logic [5:0] id; } burst_t;
burst_t rqs [64][$]; burst_t awq [$]; logic [DW-1:0] wq [$][$]; logic [DW-1:0] wcur [$]; logic [5:0] bq [$];
int r_out = 0, rid_cur = -1, rbeat = 0, m_ids_seen [64], m_wr_bursts = 0, m_rd_bursts = 0;
always @(posedge hclk) begin
  if (!hresetn) begin m_arready <= 0; m_awready <= 0; m_wready <= 0; m_rvalid <= 0; m_bvalid <= 0; rid_cur = -1; end
  else begin
    if (m_arvalid && m_arready) begin burst_t b; b.addr = m_araddr; b.len = m_arlen; b.id = m_arid; rqs[m_arid].push_back(b); r_out++; m_ids_seen[m_arid]++; m_rd_bursts++; end
    m_arready <= (r_out < 32) && ($urandom % 10 < 7);
    if (m_awvalid && m_awready) begin burst_t b; b.addr = m_awaddr; b.len = m_awlen; b.id = m_awid; awq.push_back(b); m_ids_seen[m_awid]++; m_wr_bursts++; end
    if (m_wvalid && m_wready) begin wcur.push_back(m_wdata); if (m_wlast) begin wq.push_back(wcur); wcur = {}; end end
    m_awready <= ($urandom % 10 < 6); m_wready <= ($urandom % 10 < 7);
    while (awq.size() > 0 && wq.size() > 0) begin
      burst_t b; logic [DW-1:0] w [$]; b = awq.pop_front(); w = wq.pop_front();
      if (w.size() != b.len + 1) begin $display("ERROR: W burst of %0d beats for AW len %0d", w.size(), b.len + 1); errors++; end
      for (int k = 0; k < w.size(); k++) mem[(b.addr >> 5) + k] = w[k];
      bq.insert($urandom % (bq.size() + 1), b.id);          // B responses out of order across bursts
    end
    if (m_bvalid && m_bready) m_bvalid <= 0;
    if ((!m_bvalid || m_bready) && bq.size() > 0 && ($urandom % 4 != 0)) begin m_bid <= bq.pop_front(); m_bresp <= 0; m_bvalid <= 1; end
    if (m_rvalid && m_rready) begin
      if (m_rlast) begin void'(rqs[rid_cur].pop_front()); r_out--; rid_cur = -1; rbeat = 0; end else rbeat++;
    end
    if (!m_rvalid || m_rready) begin
      m_rvalid <= 0;
      if ($urandom % 10 < 8) begin
        if (rid_cur < 0) begin int pick[$]; pick.delete(); for (int i = 0; i < 64; i++) if (rqs[i].size() > 0) pick.push_back(i); if (pick.size() > 0) rid_cur = pick[$urandom % pick.size()]; end
        if (rid_cur >= 0) begin
          burst_t rb_; logic [28:0] wa; rb_ = rqs[rid_cur][0]; wa = (rb_.addr >> 5) + rbeat;
          m_rdata <= mem.exists(wa) ? mem[wa] : pattern({wa, 5'b0}); m_rid <= rb_.id; m_rresp <= 0; m_rlast <= (rbeat == rb_.len); m_rvalid <= 1;
        end
      end
    end
  end
end

// ------------------------------------------------------------------ Coyote-like master (ACLK): write blocks, read them back
int c_on = 0;
typedef struct { logic [63:0] addr; int beats; } blk_t;
blk_t aw_jobs [$], w_jobs [$], done_blks [$], rd_jobs [$];
logic [DW-1:0] shadow [logic [33:5]];
int wbeat = 0, wr_issued = 0, wr_done = 0, rd_issued = 0, rd_done = 0, rd_beat = 0, s_beats = 0;
function automatic logic [DW-1:0] wdata_of(logic [63:0] a, int k);
  return {8{a[31:0] ^ (32'h1000 * k) ^ 32'hA5A5_0000}};
endfunction
always @(posedge aclk) begin
  if (!aresetn) begin s_awvalid <= 0; s_wvalid <= 0; s_bready <= 0; s_arvalid <= 0; s_rready <= 0; end
  else begin
    if (c_on != 0 && aw_jobs.size() < 6 && w_jobs.size() < 8 && ($urandom % (c_on == 2 ? 300 : 8) == 0)) begin
      blk_t b; b.addr = 64'h0000_0000_8100_0000 + {($urandom % 2048), 12'b0}; b.beats = 1 + $urandom % 64;   // inside one 4 KiB page
      aw_jobs.push_back(b); w_jobs.push_back(b); wr_issued++;
    end
    if (s_awvalid && s_awready) void'(aw_jobs.pop_front());
    if (!s_awvalid || s_awready) begin
      if (aw_jobs.size() > 0 && !(s_awvalid && aw_jobs.size() == 0)) begin s_awaddr <= aw_jobs[0].addr; s_awlen <= aw_jobs[0].beats - 1; s_awvalid <= 1; end else s_awvalid <= 0;
    end
    if (s_wvalid && s_wready) begin
      if (s_wlast) begin blk_t b; b = w_jobs.pop_front(); for (int k = 0; k < b.beats; k++) shadow[(b.addr[33:0] >> 5) + k] = wdata_of(b.addr, k); done_blks.push_back(b); wbeat = 0; end
      else wbeat++;
    end
    if (!s_wvalid || s_wready) begin
      if (w_jobs.size() > 0 && ($urandom % 4 != 0)) begin s_wdata <= wdata_of(w_jobs[0].addr, wbeat); s_wlast <= (wbeat == w_jobs[0].beats - 1); s_wvalid <= 1; end
      else s_wvalid <= 0;
    end
    s_bready <= ($urandom % 4 != 0);
    if (s_bvalid && s_bready) begin wr_done++; if (s_bresp != 0) begin errors++; $display("ERROR: bresp %0d", s_bresp); end end
    // reads: of written blocks once their writes have all completed (wr_done == wr_issued at issue time), else of fresh area
    if (s_arvalid && s_arready) s_arvalid <= 0;
    if (c_on != 0 && (!s_arvalid || s_arready) && rd_jobs.size() < 8 && ($urandom % (c_on == 2 ? 300 : 10) == 0)) begin
      blk_t b;
      if (done_blks.size() > 0 && wr_done == wr_issued && aw_jobs.size() == 0 && w_jobs.size() == 0) b = done_blks[$urandom % done_blks.size()];
      else begin b.addr = 64'h0000_0001_0000_0000 + {($urandom % 2048), 12'b0}; b.beats = 1 + $urandom % 64; end
      s_araddr <= b.addr; s_arlen <= b.beats - 1; s_arvalid <= 1; rd_jobs.push_back(b); rd_issued++;
    end
    s_rready <= ($urandom % 5 != 0);
    if (s_rvalid && s_rready) begin
      blk_t b; logic [28:0] wa; logic [DW-1:0] exp; b = rd_jobs[0]; wa = (b.addr[33:0] >> 5) + rd_beat;
      exp = shadow.exists(wa) ? shadow[wa] : pattern({wa, 5'b0});
      if (s_rdata !== exp) begin errors++; if (errors < 6) $display("ERROR: Coyote read %0h beat %0d", b.addr, rd_beat); end
      if (s_rlast !== (rd_beat == b.beats - 1)) begin errors++; if (errors < 6) $display("ERROR: Coyote rlast at beat %0d of %0d", rd_beat, b.beats); end
      s_beats++;
      if (s_rlast) begin void'(rd_jobs.pop_front()); rd_beat = 0; rd_done++; end else rd_beat++;
    end
  end
end

// ------------------------------------------------------------------ direct-port-like reader (HCLK)
int d_on = 0, d_inflight = 0, d_issued = 0, d_done = 0, d_beats = 0;
typedef struct { logic [33:0] addr; } dexp_t;
dexp_t d_exp [2][$]; int d_rb [2];
always @(posedge hclk) begin
  if (!hresetn) begin d_arvalid <= 0; d_rready <= 0; d_rb[0] = 0; d_rb[1] = 0; end
  else begin
    if (d_arvalid && d_arready) begin d_arvalid <= 0; d_inflight++; end
    if (d_on != 0 && (!d_arvalid || d_arready) && d_inflight + (d_arvalid ? 1 : 0) < 16 && ($urandom % (d_on == 1 ? 2 : 1) == 0)) begin
      dexp_t e; logic [5:0] id; id = $urandom % 2; e.addr = 34'h200000000 + {$urandom % 65536, 9'b0};
      d_araddr <= e.addr; d_arlen <= 15; d_arid <= id; d_arvalid <= 1; d_exp[id].push_back(e); d_issued++;
    end
    d_rready <= ($urandom % 6 != 0);
    if (d_rvalid && d_rready) begin
      dexp_t e; logic [28:0] wa; e = d_exp[d_rid][0]; wa = (e.addr >> 5) + d_rb[d_rid];
      if (d_rdata !== pattern({wa, 5'b0})) begin errors++; if (errors < 6) $display("ERROR: direct read data"); end
      d_beats++;
      if (d_rlast) begin void'(d_exp[d_rid].pop_front()); d_rb[d_rid] = 0; d_done++; d_inflight--; end else d_rb[d_rid]++;
    end
  end
end

int switches = 0; logic owner_q;
always @(posedge hclk) begin owner_q <= dut.chain_i.share.inst.owner; if (hresetn && owner_q !== dut.chain_i.share.inst.owner) switches++; end

task automatic drain(input int limit, input string tag);
  int t; t = 0;
  while ((rd_done < rd_issued || wr_done < wr_issued || d_done < d_issued || aw_jobs.size() > 0 || w_jobs.size() > 0) && t < limit) begin @(posedge aclk); t++; end
  if (t >= limit) begin errors++; $display("ERROR: %s: drain timeout: writes %0d/%0d, Coyote reads %0d/%0d, direct reads %0d/%0d (HBM side: %0d write and %0d read bursts)",
                                       tag, wr_done, wr_issued, rd_done, rd_issued, d_done, d_issued, m_wr_bursts, m_rd_bursts); end
endtask

initial begin
  repeat (40) @(posedge aclk); aresetn = 1; cresetn = 1; hresetn = 1; repeat (100) @(posedge aclk);
  c_on = 1; repeat (15000) @(posedge aclk); c_on = 0; drain(40000, "P1");
  $display("P1 (Coyote only, the board's case): writes %0d/%0d, reads %0d/%0d (%0d beats), switches %0d", wr_done, wr_issued, rd_done, rd_issued, s_beats, switches);
  d_on = 1; repeat (5000) @(posedge aclk); d_on = 0; drain(40000, "P2");
  $display("P2 (direct only): direct reads %0d, switches %0d", d_done, switches);
  c_on = 1; d_on = 1; repeat (20000) @(posedge aclk); c_on = 0; d_on = 0; drain(40000, "P3");
  $display("P3 (both): writes %0d, Coyote reads %0d, direct reads %0d, switches %0d", wr_done, rd_done, d_done, switches);
  foreach (shadow[a]) if (!mem.exists(a) || mem[a] !== shadow[a]) begin errors++; if (errors < 10) $display("ERROR: written word %0h not in memory", a); end
  begin int n_ids; n_ids = 0; for (int i = 0; i < 64; i++) if (m_ids_seen[i] > 0) n_ids++;
  $display("T: writes %0d/%0d, Coyote reads %0d/%0d, direct reads %0d/%0d, HBM-side bursts %0d write / %0d read with %0d distinct IDs, switches %0d, errors %0d",
           wr_done, wr_issued, rd_done, rd_issued, d_done, d_issued, m_wr_bursts, m_rd_bursts, n_ids, switches, errors);
  $display("RESULT: %s", (errors == 0 && wr_done > 100 && rd_done > 50 && d_done > 100 && switches > 2) ? "PASS" : "FAIL"); end
  $finish;
end
initial begin #20ms; $display("ERROR: global timeout"); $display("RESULT: FAIL"); $finish; end
endmodule
