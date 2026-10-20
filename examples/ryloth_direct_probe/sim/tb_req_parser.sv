`timescale 1ns/1ps
import lynxTypes::*;
// req_parser must carry rsrvd (the physical flag) onto every 4 KiB piece
module tb_parser;
  logic aclk = 0, aresetn = 0; always #1 aclk = ~aclk;
  metaIntf #(.STYPE(req_t)) s_req (.*);
  metaIntf #(.STYPE(req_t)) m_req (.*);
  req_parser dut (.aclk(aclk), .aresetn(aresetn), .s_req(s_req), .m_req(m_req));
  assign m_req.ready = 1'b1;
  int n = 0, bad = 0; longint total = 0;
  always @(posedge aclk) if (m_req.valid && m_req.ready) begin
    n++; total += m_req.data.len;
    if (m_req.data.rsrvd[0] !== 1'b1 || m_req.data.strm != STRM_CARD || m_req.data.dest != 7) bad++;
  end
  initial begin
    req_t d; d = '0; d.opcode = LOCAL_READ; d.strm = STRM_CARD; d.dest = 7; d.pid = 1; d.vaddr = 64'd3 << 30; d.len = 16384;
    d.last = 1; d.actv = 1; d.rsrvd = 1;
    s_req.valid = 0; s_req.data = '0; repeat (5) @(posedge aclk); aresetn = 1; repeat (3) @(posedge aclk);
    @(negedge aclk); s_req.data = d; s_req.valid = 1; @(posedge aclk); while (!s_req.ready) @(posedge aclk); @(negedge aclk) s_req.valid = 0;
    repeat (40) @(posedge aclk);
    $display("req_parser: %0d pieces, %0d bytes, %0d without the flag", n, total, bad);
    if (n == 4 && total == 16384 && bad == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
endmodule
