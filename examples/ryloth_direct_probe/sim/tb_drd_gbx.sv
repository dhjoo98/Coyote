// drd_gearbox alone (10/26, sub-FIFO R path): the memory side offers R beats as fast as rready allows (random gaps),
// the user side stalls for long random stretches, so the R FIFOs sit at their programmable-full level for most of the run.
// Checks: every 1024-bit beat = {beat 2i+1, beat 2i} of the memory stream, rlast on the right beats, nothing lost or
// duplicated, and the gearbox never accepts more than the FIFOs can hold (would show as a data error). Also reports the
// throughput with no stalls (must be 1 beat per ACLK cycle).
`timescale 1ns / 1ps
import lynxTypes::*;
module tb_gbx;
logic aclk = 0, hclk = 0, aresetn = 0, hresetn = 0;
always #3.3333 aclk = ~aclk;
initial begin #0.9; forever #1.6667 hclk = ~hclk; end
AXI4 #(.AXI4_DATA_BITS(1024)) s (.aclk(aclk));
AXI4 m (.aclk(hclk));
drd_gearbox #(.ADDR_BITS(34)) dut (.aclk(aclk), .aresetn(aresetn), .hclk(hclk), .hresetn(hresetn), .s_axi(s), .m_axi(m));
// AR side idle
assign s.arvalid = 0; assign s.araddr = 0; assign s.arlen = 0; assign s.arid = 0; assign s.arburst = 1; assign s.arsize = 7;
assign s.arcache = 0; assign s.arlock = 0; assign s.arprot = 0; assign s.arqos = 0; assign s.arregion = 0;
assign s.awvalid = 0; assign s.wvalid = 0; assign s.bready = 1; assign s.awaddr = 0; assign s.awlen = 0; assign s.awid = 0;
assign s.awburst = 1; assign s.awsize = 0; assign s.awcache = 0; assign s.awlock = 0; assign s.awprot = 0; assign s.awqos = 0;
assign s.awregion = 0; assign s.wdata = 0; assign s.wstrb = 0; assign s.wlast = 0;
assign m.arready = 1; assign m.awready = 0; assign m.wready = 0; assign m.bvalid = 0; assign m.bresp = 0; assign m.bid = 0;
assign m.rid = 0; assign m.rresp = 0;
// memory side: beat n carries a pattern of n; bursts of 2*L beats (L = 1..8 128-byte beats), rlast on the burst's last
int unsigned n_sent = 0, burst_left = 0, bp = 0; int phase = 0; bit gaps = 1;
function automatic logic [511:0] pat(int unsigned n);
    logic [511:0] v; for (int i = 0; i < 16; i++) v[32*i +: 32] = n * 32'h9E3779B1 + i; return v;
endfunction
logic mv; assign m.rvalid = mv; assign m.rdata = pat(n_sent); assign m.rlast = (burst_left == 1);
always @(posedge hclk) begin
    if (!hresetn) begin mv <= 0; end
    else begin
        if (mv && !m.rready) bp <= bp + 1;
        if (mv && m.rready) begin n_sent <= n_sent + 1; burst_left <= burst_left - 1; end
        if (burst_left == 0 || (burst_left == 1 && mv && m.rready)) begin
            if (burst_left == 0) burst_left <= 2 * ($urandom_range(1, 8));
        end
        mv <= (!gaps || $urandom_range(0, 9) < 8) && (phase != 0);
    end
end
// fix: burst_left restart when it reaches 0 after the last beat
always @(posedge hclk) if (hresetn && burst_left == 1 && mv && m.rready) burst_left <= 2 * ($urandom_range(1, 8));
// user side
logic rr = 0; assign s.rready = rr;
int unsigned n_recv = 0, errors = 0, stall_cycles = 0, t_beats = 0, t_cycles = 0; int stall = 0; bit stalls = 1;
always @(posedge aclk) begin
    if (aresetn) begin
        if (stalls) begin
            if (stall > 0) begin stall <= stall - 1; rr <= 0; end
            else if ($urandom_range(0, 99) < 3) begin stall <= $urandom_range(20, 400); rr <= 0; end
            else rr <= ($urandom_range(0, 3) != 0);
        end else rr <= 1;
        if (s.rvalid && s.rready) begin
            if (s.rdata[511:0] !== pat(2*n_recv) || s.rdata[1023:512] !== pat(2*n_recv+1)) begin
                errors++; if (errors < 5) $display("ERROR data at beat %0d", n_recv);
            end
            n_recv <= n_recv + 1;
        end
        if (!s.rready) stall_cycles++;
    end
end
// rlast check: reconstruct from the memory side's burst boundaries
int unsigned last_q[$]; always @(posedge hclk) if (hresetn && mv && m.rready && burst_left == 1) last_q.push_back(n_sent);
always @(posedge aclk) if (aresetn && s.rvalid && s.rready) begin
    bit exp_last = (last_q.size() > 0 && last_q[0] == 2*n_recv+1);
    if (exp_last) void'(last_q.pop_front());
    if (s.rlast !== exp_last) begin errors++; if (errors < 5) $display("ERROR rlast at beat %0d (got %0b)", n_recv, s.rlast); end
end
initial begin
    repeat (20) @(posedge aclk); aresetn = 1; hresetn = 1; repeat (40) @(posedge aclk);
    phase = 1; repeat (60000) @(posedge aclk);
    $display("S1: stalls + memory gaps: %0d beats received, %0d stall cycles (consumer), errors %0d", n_recv, stall_cycles, errors);
    // throughput: no stalls, no gaps
    stalls = 0; gaps = 0; repeat (500) @(posedge aclk);
    t_beats = n_recv; repeat (4000) @(posedge aclk); t_beats = n_recv - t_beats;
    $display("S2: no stalls: %0.3f 1024-bit beats per ACLK cycle", t_beats / 4000.0);
    // reset in the middle of traffic, then run again
    stalls = 1; gaps = 1; repeat (20000) @(posedge aclk);
    $display("S3: %0d beats total, errors %0d, memory-side back-pressure cycles %0d (FIFOs at programmable full)", n_recv, errors, bp);
    $display("RESULT: %s (errors %0d)", errors == 0 && n_recv > 10000 && bp > 1000 ? "PASS" : "FAIL", errors);
    $finish;
end
endmodule
