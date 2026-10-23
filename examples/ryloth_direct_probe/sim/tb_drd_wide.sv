/**
 * Ryloth direct read ports, scaling step B (2026-10-22 night): xsim testbench of the wide read chain, two clocks.
 *   drd_reader (1024 bits, ACLK) -> axi_rd_decoupler (ACLK) -> drd_gearbox -> axi_rd_reg_array (2, HCLK, 512 bits)
 *   -> axi_rd_reg_array (3, HCLK) -> memory model (HCLK)
 * ACLK 150 MHz, HCLK 300 MHz (2 x ACLK, unrelated phase). The memory model stands for hbm_wide_rd + the HBM ports at HCLK:
 * it checks every burst (INCR, 64 B beats, at most 16 beats, no 1 KiB crossing, arsize 6), answers in order after a
 * latency and returns data derived from the 64-byte beat address; the consumer checks every 128-byte beat
 * ({word(2b+1), word(2b)}), tlast and tdest.
 * T1 random commands, random back-pressure everywhere. T2 1 MiB, no back-pressure: 128-byte beats per ACLK cycle.
 * T3 decoupled. T4 max_out 8, latency 96 HCLK cycles (the board's ~0.32 us): line rate. T5 consumer stall: no
 * back-pressure at the memory. T6 dest bit and the null last beat.
 */
`timescale 1ns / 1ps
import lynxTypes::*;
`include "axi_macros.svh"

module tb_drd_wide;

logic aclk = 1'b0, hclk = 1'b0, aresetn = 1'b0, hresetn = 1'b0;
always #3.3333 aclk = ~aclk;          // 150 MHz
initial begin #0.7; forever #1.6667 hclk = ~hclk; end   // 300 MHz, offset phase

AXI4 #(.AXI4_DATA_BITS(1024)) a0 (.aclk(aclk));
AXI4 #(.AXI4_DATA_BITS(1024)) a1 (.aclk(aclk));
AXI4 a2 (.aclk(hclk));
AXI4 a3 (.aclk(hclk));
AXI4 a4 (.aclk(hclk));

logic          decouple = 1'b0;
logic [7:0]    max_out = 8'd0;      // 0 = DEFAULT_OUT = 16
logic          cmd_valid = 1'b0, cmd_ready, cmd_last = 1'b0;
logic [33:0]   cmd_addr = '0;
logic [31:0]   cmd_len = '0;
logic [1023:0] tdata;
logic          tvalid, tlast, tready, busy;
logic          cmd_dest = 1'b0, tdest, tkeep_all;
int            n_null = 0;

drd_reader #(.ADDR_BITS(34), .DATA_BITS(1024), .MAX_OUT(32), .BURST_BEATS(8), .FIFO_BEATS(256), .DEFAULT_OUT(16)) dut (
    .aclk(aclk), .aresetn(aresetn), .max_out(max_out), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_addr(cmd_addr), .cmd_len(cmd_len),
    .cmd_last(cmd_last), .cmd_dest(cmd_dest), .m_axi(a0), .m_tdata(tdata), .m_tvalid(tvalid), .m_tlast(tlast), .m_tdest(tdest),
    .m_tkeep_all(tkeep_all), .m_tready(tready), .busy(busy));
axi_rd_decoupler #(.ADDR_BITS(34)) inst_dcpl (.aclk(aclk), .aresetn(aresetn), .decouple(decouple), .s_axi(a0), .m_axi(a1));
drd_gearbox #(.ADDR_BITS(34)) inst_gbx (.aclk(aclk), .aresetn(aresetn), .hclk(hclk), .hresetn(hresetn), .s_axi(a1), .m_axi(a2));
axi_rd_reg_array #(.N_STAGES(2), .ADDR_BITS(34), .SKID2(1)) inst_s1 (.aclk(hclk), .aresetn(hresetn), .s_axi(a2), .m_axi(a3));
axi_rd_reg_array #(.N_STAGES(3), .ADDR_BITS(34), .SKID2(1)) inst_s0 (.aclk(hclk), .aresetn(hresetn), .s_axi(a3), .m_axi(a4));

function automatic logic [511:0] word(input logic [33:0] beat);   // beat = address in 64 B units
    logic [511:0] w;
    for (int j = 0; j < 8; j++) w[64*j +: 64] = {beat[31:0], 8'(j), 24'h5a5a5a} ^ (64'h9e3779b97f4a7c15 * (beat + 1));
    return w;
endfunction

// ---------------------------------------------------------------- memory model (slave on a4, HCLK)
int  p_ar = 100, p_r = 100, p_t = 100;
int  lat = 40;
int  errors = 0, n_ar = 0, max_seen = 0, bp_cycles = 0;
logic [33:0] q_beat [$];
int          q_len  [$];
longint      q_due  [$];
longint      hnow = 0, now = 0;
int          r_idx = 0;
logic        ar_rdy, r_vld;

always @(posedge hclk) hnow <= hnow + 1;
always @(posedge aclk) now <= now + 1;

always_comb begin
    a4.arready = ar_rdy && (q_beat.size() < 64);
    a4.rvalid  = r_vld && (q_beat.size() > 0) && (q_due[0] <= hnow);
    a4.rdata   = (q_beat.size() > 0) ? word(q_beat[0] + r_idx) : '0;
    a4.rlast   = (q_beat.size() > 0) && (r_idx == q_len[0] - 1);
    a4.rresp   = 2'b00;
    a4.rid     = '0;
    a4.awready = 1'b0; a4.wready = 1'b0; a4.bvalid = 1'b0; a4.bresp = '0; a4.bid = '0;
end

always @(posedge hclk) begin
    ar_rdy <= ($urandom_range(99) < p_ar);
    r_vld  <= ($urandom_range(99) < p_r);
    if (a4.arvalid && a4.arready) begin
        logic [33:0] b; int n;
        b = a4.araddr[33:6]; n = a4.arlen + 1;
        n_ar++;
        if (a4.araddr[6:0] != 0)               begin errors++; $display("ERROR AR not 128 B aligned %h", a4.araddr); end
        if (a4.arsize != 3'b110 || a4.arburst != 2'b01) begin errors++; $display("ERROR AR size/burst"); end
        if (a4.arlen > 15 || n % 2 != 0)        begin errors++; $display("ERROR AR len %0d", a4.arlen); end
        if ((b >> 4) != ((b + n - 1) >> 4))    begin errors++; $display("ERROR AR crosses 1 KiB at beat %h", b); end
        q_beat.push_back(b); q_len.push_back(n); q_due.push_back(hnow + lat + $urandom_range(lat / 4));
        if (q_beat.size() > max_seen) max_seen = q_beat.size();
    end
    if (a4.rvalid && a4.rready) begin
        if (a4.rlast) begin void'(q_beat.pop_front()); void'(q_len.pop_front()); void'(q_due.pop_front()); r_idx <= 0; end
        else r_idx <= r_idx + 1;
    end
    if (a4.awvalid || a4.wvalid) begin errors++; $display("ERROR write channel active"); end
    if (a4.rvalid && !a4.rready) bp_cycles++;
end

// ---------------------------------------------------------------- consumer (ACLK, 128-byte beats)
logic [33:0] exp_beat [$];     // in 128 B units
logic        exp_last [$];
logic        exp_dest [$];
longint      n_beats = 0, t_first = -1, t_last_beat = 0;

always @(posedge aclk) tready <= ($urandom_range(99) < p_t);

always @(posedge aclk) begin
    if (tvalid && tready && !tkeep_all) begin
        n_null++;
        if (!tlast) begin errors++; $display("ERROR null beat without tlast"); end
        if (exp_beat.size() != 0) begin errors++; $display("ERROR null beat before %0d expected beats", exp_beat.size()); end
    end
    else if (tvalid && tready) begin
        if (exp_beat.size() == 0) begin errors++; $display("ERROR unexpected beat"); end
        else begin
            if (tdata !== {word(2 * exp_beat[0] + 1), word(2 * exp_beat[0])}) begin errors++; if (errors < 10) $display("ERROR data at beat %h", exp_beat[0]); end
            if (tlast !== exp_last[0]) begin errors++; if (errors < 10) $display("ERROR tlast at beat %h: %b", exp_beat[0], tlast); end
            if (tdest !== exp_dest[0]) begin errors++; if (errors < 10) $display("ERROR tdest at beat %h: %b", exp_beat[0], tdest); end
            void'(exp_beat.pop_front()); void'(exp_last.pop_front()); void'(exp_dest.pop_front());
        end
        n_beats++;
        if (t_first < 0) t_first = now;
        t_last_beat = now;
    end
end

task automatic send(input logic [33:0] addr, input int bytes, input logic last);
    for (int k = 0; k < bytes / 128; k++) begin
        exp_beat.push_back(addr[33:7] + k);
        exp_last.push_back(last && (k == bytes / 128 - 1));
        exp_dest.push_back(cmd_dest);
    end
    @(negedge aclk);
    cmd_valid = 1'b1; cmd_addr = addr; cmd_len = bytes; cmd_last = last;
    do @(posedge aclk); while (!cmd_ready);
    @(negedge aclk); cmd_valid = 1'b0;
endtask

task automatic drain(input int limit);
    int c = 0;
    while ((exp_beat.size() > 0 || busy) && c < limit) begin @(posedge aclk); c++; end
    if (exp_beat.size() != 0) begin errors++; $display("ERROR %0d beats missing", exp_beat.size()); end
endtask

initial begin
    repeat (20) @(posedge aclk);
    aresetn = 1'b1;
    @(posedge hclk); hresetn = 1'b1;
    repeat (40) @(posedge aclk);       // XPM FIFOs leave reset (wr_rst_busy / rd_rst_busy)

    // T1: random commands, random back-pressure everywhere
    p_ar = 60; p_r = 70; p_t = 60; lat = 60; max_out = 8'd0;
    for (int i = 0; i < 300; i++) begin
        logic [33:0] a; int len;
        a   = {27'($urandom), 7'b0};
        len = 128 * $urandom_range(1, (i % 7 == 0) ? 300 : 20);
        send(a, len, $urandom_range(1));
    end
    drain(400000);
    $display("T1: 300 random commands, %0d HBM-side bursts, max outstanding %0d, errors %0d", n_ar, max_seen, errors);

    // T2: one 1 MiB command, no back-pressure, latency 240 HCLK cycles
    p_ar = 100; p_r = 100; p_t = 100; lat = 240;
    repeat (20) @(posedge aclk);
    n_beats = 0; t_first = -1; max_seen = 0;
    begin
        longint t0; t0 = now;
        send(34'h1_2340_0000, 1 << 20, 1'b1);
        drain(100000);
        $display("T2: 1 MiB, %0d 128-byte beats in %0d ACLK cycles from command: %.3f beats/cycle after the first (1.000 = 19.2 GB/s at 150 MHz), max outstanding %0d",
                 n_beats, t_last_beat - t0, real'(n_beats) / real'(t_last_beat - t_first + 1), max_seen);
    end

    // T3: decoupled while a command is pending
    begin
        int ar0, dec_ar; ar0 = n_ar;
        decouple = 1'b1;
        fork send(34'h0_0010_0000, 4096, 1'b1); join_none
        repeat (300) @(posedge aclk);
        dec_ar = n_ar - ar0;
        if (dec_ar != 0) begin errors++; $display("ERROR %0d bursts left while decoupled", dec_ar); end
        decouple = 1'b0;
        drain(20000);
        $display("T3: decoupled 300 cycles: %0d bursts left the region; released: %0d bursts, completed, errors %0d", dec_ar, n_ar - ar0, errors);
    end

    // T4: default max_out (16), latency 96 HCLK cycles (~0.32 us): line rate within the deadlock rule (<= 16 x 16
    // beats per stack = the 256-entry merge FIFO); T4b: max_out 8 for comparison
    for (int m = 0; m < 2; m++) begin
        max_out = (m == 0) ? 8'd0 : 8'd8; p_ar = 100; p_r = 100; p_t = 100; lat = 96;
        repeat (20) @(posedge aclk);
        n_beats = 0; t_first = -1; max_seen = 0;
        send(34'h2_0000_0000 + 34'(m) * 34'h10_0000, 1 << 20, 1'b1);
        drain(100000);
        $display("T4%s: max_out %0d, latency 96 HCLK: %.3f beats/cycle after the first beat, max outstanding %0d (must be <= %0d)",
                 (m == 0) ? "" : "b", (m == 0) ? 16 : 8, real'(n_beats) / real'(t_last_beat - t_first + 1), max_seen, (m == 0) ? 16 : 8);
        if (max_seen > ((m == 0) ? 16 : 8)) begin errors++; $display("ERROR too many bursts outstanding"); end
    end
    max_out = 8'd0;

    // T5: consumer stalls 3000 cycles mid-command: no back-pressure may reach the memory model
    bp_cycles = 0; p_t = 100;
    begin
        int bp0; bp0 = bp_cycles;
        fork send(34'h2_4000_0000, 1 << 20, 1'b1); join_none
        repeat (400) @(posedge aclk);
        p_t = 0;
        repeat (3000) @(posedge aclk);
        p_t = 100;
        drain(100000);
        $display("T5: consumer stalled 3000 cycles: memory-side back-pressure cycles %0d (must be 0), errors %0d", bp_cycles - bp0, errors);
        if (bp_cycles - bp0 != 0) begin errors++; $display("ERROR back-pressure reached the memory side"); end
    end

    // T6: dest bit per command; zero-length last command -> one null beat behind all data
    max_out = 8'd0; p_t = 70; p_ar = 80; p_r = 80;
    begin
        int nn0; nn0 = n_null;
        cmd_dest = 1'b1; send(34'h0_4100_0000, 3072 * 10, 1'b0);
        cmd_dest = 1'b0; send(34'h1_8000_0000, 768 * 12, 1'b0);
        send(34'h2_0000_0000, 768 * 3, 1'b0);
        send(34'h0, 0, 1'b0);
        send(34'h0, 0, 1'b1);
        drain(200000);
        repeat (50) @(posedge aclk);
        if (n_null - nn0 != 1) begin errors++; $display("ERROR %0d null beats, expected 1", n_null - nn0); end
        $display("T6: dest on every beat, null last beat behind the data: null beats %0d (expected 1), errors %0d", n_null - nn0, errors);
    end

    $display("RESULT: %s (errors %0d)", (errors == 0) ? "PASS" : "FAIL", errors);
    $finish;
end

endmodule
