/**
 * Ryloth direct read ports: xsim testbench of the user-to-shell read chain.
 *   drd_reader -> axi_rd_decoupler -> axi_rd_reg_array (2, user side) -> axi_rd_reg_array (2, memory side) -> memory model
 * The memory model stands for hbm_wide + the HBM ports: it checks every burst (INCR, 64 B beats, at most 16 beats, no
 * 1 KiB crossing, at most 64 outstanding), answers in order after a latency, and returns data derived from the address.
 * T1 random commands with random back-pressure everywhere: every beat and every tlast checked.
 * T2 one 1 MiB command, no back-pressure, 120-cycle latency: beats per cycle.
 * T3 decoupled while a command is pending: nothing leaves; released: the command completes.
 */
`timescale 1ns / 1ps
import lynxTypes::*;
`include "axi_macros.svh"

module tb_drd;

logic aclk = 1'b0, aresetn = 1'b0;
always #3.333 aclk = ~aclk;

AXI4 a0 (.aclk(aclk));
AXI4 a1 (.aclk(aclk));
AXI4 a2 (.aclk(aclk));
AXI4 a3 (.aclk(aclk));

logic          decouple = 1'b0;
logic [7:0]    max_out = 8'd32;
logic          cmd_valid = 1'b0, cmd_ready, cmd_last = 1'b0;
logic [33:0]   cmd_addr = '0;
logic [31:0]   cmd_len = '0;
logic [511:0]  tdata;
logic          tvalid, tlast, tready, busy;

drd_reader #(.ADDR_BITS(34), .MAX_OUT(32), .BURST_BEATS(16), .FIFO_BEATS(512)) dut (
    .aclk(aclk), .aresetn(aresetn), .max_out(max_out), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_addr(cmd_addr), .cmd_len(cmd_len),
    .cmd_last(cmd_last), .m_axi(a0), .m_tdata(tdata), .m_tvalid(tvalid), .m_tlast(tlast), .m_tready(tready), .busy(busy));
axi_rd_decoupler #(.ADDR_BITS(34)) inst_dcpl (.aclk(aclk), .aresetn(aresetn), .decouple(decouple), .s_axi(a0), .m_axi(a1));
axi_rd_reg_array #(.N_STAGES(2), .ADDR_BITS(34)) inst_s1 (.aclk(aclk), .aresetn(aresetn), .s_axi(a1), .m_axi(a2));
axi_rd_reg_array #(.N_STAGES(2), .ADDR_BITS(34)) inst_s0 (.aclk(aclk), .aresetn(aresetn), .s_axi(a2), .m_axi(a3));

function automatic logic [511:0] word(input logic [33:0] beat);
    logic [511:0] w;
    for (int j = 0; j < 8; j++) w[64*j +: 64] = {beat[31:0], 8'(j), 24'h5a5a5a} ^ (64'h9e3779b97f4a7c15 * (beat + 1));
    return w;
endfunction

// ---------------------------------------------------------------- memory model (slave on a3)
int  p_ar = 100, p_r = 100, p_t = 100;     // percent of cycles with arready / rvalid / tready allowed
int  lat = 20;
int  errors = 0, n_ar = 0, max_seen = 0, bp_cycles = 0;
logic [33:0] q_beat [$];                   // per outstanding burst: first beat (in 64 B units)
int          q_len  [$];
longint      q_due  [$];
longint      now = 0;
int          r_idx = 0;                    // beat index within the head burst
logic        ar_rdy, r_vld;

always @(posedge aclk) now <= now + 1;

always_comb begin
    a3.arready = ar_rdy && (q_beat.size() < 64);
    a3.rvalid  = r_vld && (q_beat.size() > 0) && (q_due[0] <= now);
    a3.rdata   = (q_beat.size() > 0) ? word(q_beat[0] + r_idx) : '0;
    a3.rlast   = (q_beat.size() > 0) && (r_idx == q_len[0] - 1);
    a3.rresp   = 2'b00;
    a3.rid     = '0;
    a3.awready = 1'b0; a3.wready = 1'b0; a3.bvalid = 1'b0; a3.bresp = '0; a3.bid = '0;
end

always @(posedge aclk) begin
    ar_rdy <= ($urandom_range(99) < p_ar);
    r_vld  <= ($urandom_range(99) < p_r);
    if (a3.arvalid && a3.arready) begin
        logic [33:0] b; int n;
        b = a3.araddr[33:6]; n = a3.arlen + 1;
        n_ar++;
        if (a3.araddr[5:0] != 0)               begin errors++; $display("ERROR AR unaligned %h", a3.araddr); end
        if (a3.arsize != 3'b110 || a3.arburst != 2'b01) begin errors++; $display("ERROR AR size/burst"); end
        if (a3.arlen > 15)                     begin errors++; $display("ERROR AR len %0d", a3.arlen); end
        if ((b >> 4) != ((b + n - 1) >> 4))    begin errors++; $display("ERROR AR crosses 1 KiB at beat %h", b); end
        q_beat.push_back(b); q_len.push_back(n); q_due.push_back(now + lat + $urandom_range(lat / 4));
        if (q_beat.size() > max_seen) max_seen = q_beat.size();
    end
    if (a3.rvalid && a3.rready) begin
        if (a3.rlast) begin void'(q_beat.pop_front()); void'(q_len.pop_front()); void'(q_due.pop_front()); r_idx <= 0; end
        else r_idx <= r_idx + 1;
    end
    if (a3.awvalid || a3.wvalid) begin errors++; $display("ERROR write channel active"); end
    if (a3.rvalid && !a3.rready) bp_cycles++;
end

// ---------------------------------------------------------------- consumer
logic [33:0] exp_beat [$];
logic        exp_last [$];
longint      n_beats = 0, t_first = -1, t_last_beat = 0;

always @(posedge aclk) tready <= ($urandom_range(99) < p_t);

always @(posedge aclk) begin
    if (tvalid && tready) begin
        if (exp_beat.size() == 0) begin errors++; $display("ERROR unexpected beat"); end
        else begin
            if (tdata !== word(exp_beat[0])) begin errors++; if (errors < 10) $display("ERROR data at beat %h", exp_beat[0]); end
            if (tlast !== exp_last[0])       begin errors++; if (errors < 10) $display("ERROR tlast at beat %h: %b", exp_beat[0], tlast); end
            void'(exp_beat.pop_front()); void'(exp_last.pop_front());
        end
        n_beats++;
        if (t_first < 0) t_first = now;
        t_last_beat = now;
    end
end

task automatic send(input logic [33:0] addr, input int bytes, input logic last);
    for (int k = 0; k < bytes / 64; k++) begin
        exp_beat.push_back(addr[33:6] + k);
        exp_last.push_back(last && (k == bytes / 64 - 1));
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
    repeat (10) @(posedge aclk);
    aresetn = 1'b1;
    repeat (5) @(posedge aclk);

    // T1: random commands, random back-pressure everywhere
    p_ar = 60; p_r = 70; p_t = 60; lat = 30;
    for (int i = 0; i < 400; i++) begin
        logic [33:0] a; int len;
        a   = {28'($urandom), 6'b0};
        len = 64 * $urandom_range(1, (i % 7 == 0) ? 600 : 40);
        send(a, len, $urandom_range(1));
    end
    drain(400000);
    $display("T1: 400 random commands, %0d bursts, max outstanding %0d, errors %0d", n_ar, max_seen, errors);

    // T2: one 1 MiB command, no back-pressure, latency 120 cycles
    p_ar = 100; p_r = 100; p_t = 100; lat = 120;
    repeat (20) @(posedge aclk);
    n_beats = 0; t_first = -1; max_seen = 0;
    begin
        longint t0; t0 = now;
        send(34'h1_2340_0000, 1 << 20, 1'b1);
        drain(100000);
        $display("T2: 1 MiB, %0d beats in %0d cycles from command (%0d after the first beat): %.3f beats/cycle after the first, max outstanding %0d",
                 n_beats, t_last_beat - t0, t_last_beat - t_first, real'(n_beats) / real'(t_last_beat - t_first + 1), max_seen);
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

    // T4: max_out = 8 (the deadlock rule), no back-pressure, latency 48 cycles (the board's 0.32 us): still line rate?
    max_out = 8'd8; p_ar = 100; p_r = 100; p_t = 100; lat = 48;
    repeat (20) @(posedge aclk);
    n_beats = 0; t_first = -1; max_seen = 0;
    send(34'h2_0000_0000, 1 << 20, 1'b1);
    drain(100000);
    $display("T4: max_out 8, latency 48: %.3f beats/cycle after the first beat, max outstanding %0d (must be <= 8)",
             real'(n_beats) / real'(t_last_beat - t_first + 1), max_seen);
    if (max_seen > 8) begin errors++; $display("ERROR more than 8 bursts outstanding with max_out 8"); end

    // T5: consumer stalls for 3000 cycles mid-command: the reader must never back-pressure the memory (credits), and
    // must not lose or duplicate a beat
    max_out = 8'd32; bp_cycles = 0; p_t = 100;
    begin
        int bp0; bp0 = bp_cycles;
        fork send(34'h2_4000_0000, 1 << 20, 1'b1); join_none
        repeat (400) @(posedge aclk);
        p_t = 0;                                   // consumer stops
        repeat (3000) @(posedge aclk);
        if (a3.rvalid && !a3.rready) begin errors++; $display("ERROR memory back-pressured while the consumer stalled"); end
        p_t = 100;
        drain(100000);
        $display("T5: consumer stalled 3000 cycles: memory-side back-pressure cycles %0d (must be 0), errors %0d", bp_cycles - bp0, errors);
        if (bp_cycles - bp0 != 0) begin errors++; $display("ERROR back-pressure reached the memory side"); end
    end

    $display("RESULT: %s (errors %0d)", (errors == 0) ? "PASS" : "FAIL", errors);
    $finish;
end

endmodule
