`timescale 1ns/1ps
import lynxTypes::*;
// Ryloth direct-HBM stage 2: tlb_fsm fast path for physical STRM_CARD requests.
// The mutex is held by someone else for the whole test (mutex = 2'b01), so any request that takes the
// normal path stalls in ST_MUTEX; physical requests must flow without it.
module tb;
  logic aclk = 0, aresetn = 0;
  always #1 aclk = ~aclk;
  localparam integer TAG_L = VADDR_BITS - TLB_L_ORDER - PG_L_BITS;
  localparam integer TAG_S = VADDR_BITS - TLB_S_ORDER - PG_S_BITS;
  localparam integer LDB = TAG_L + PID_BITS + 2 + (PADDR_BITS-PG_L_BITS) + HPID_BITS;
  localparam integer SDB = TAG_S + PID_BITS + 2 + (PADDR_BITS-PG_S_BITS) + HPID_BITS;
  tlbIntf #(.TLB_INTF_DATA_BITS(LDB)) lTlb ();
  tlbIntf #(.TLB_INTF_DATA_BITS(SDB)) sTlb ();
  metaIntf #(.STYPE(ack_t)) host_done (.*);
  metaIntf #(.STYPE(ack_t)) card_done (.*);
  dmaIntf HDMA (.aclk(aclk));
  dmaIntf DDMA [N_CARD_AXI] (.aclk(aclk));
  metaIntf #(.STYPE(req_t)) sreq (.*);
  metaIntf #(.STYPE(irq_pft_t)) pfault (.*);
  logic [LEN_BITS-1:0] pfault_rng;
  metaIntf #(.STYPE(pf_t)) pfault_ctrl (.*);
  metaIntf #(.STYPE(inv_t)) invldt_ctrl (.*);
  metaIntf #(.STYPE(irq_inv_t)) invldt_irq (.*);
  logic lock, unlock; logic [1:0] mutex = 2'b01;

  tlb_fsm #(.ID_REG(0), .RDWR(0)) dut (.aclk(aclk), .aresetn(aresetn), .lTlb(lTlb), .sTlb(sTlb),
    .m_host_done(host_done), .m_HDMA(HDMA), .m_card_done(card_done), .m_DDMA(DDMA), .s_req(sreq),
    .m_pfault(pfault), .m_pfault_rng(pfault_rng), .s_pfault(pfault_ctrl), .s_invldt(invldt_ctrl), .m_invldt(invldt_irq),
    .lock(lock), .unlock(unlock), .mutex(mutex));

  logic lhit = 1'b0; logic [LDB-1:0] ldata = '0; assign lTlb.hit = lhit; assign lTlb.data = ldata; assign sTlb.hit = 1'b0; assign sTlb.data = '0;
  assign host_done.ready = 1'b1; assign card_done.ready = 1'b1; assign pfault.ready = 1'b1; assign invldt_irq.ready = 1'b1;
  assign pfault_ctrl.valid = 1'b0; assign pfault_ctrl.data = '0; assign invldt_ctrl.valid = 1'b0; assign invldt_ctrl.data = '0;
  assign HDMA.ready = 1'b1; assign HDMA.rsp = '0;

  // card DMA engines: always ready, complete one cycle after acceptance; record every request
  typedef struct { int dest; longint paddr; longint len; bit last; longint t; } rec_t;
  rec_t got[$];
  for (genvar i = 0; i < N_CARD_AXI; i++) begin : g_dma
    assign DDMA[i].ready = 1'b1;
    always @(posedge aclk) begin
      DDMA[i].rsp.done <= DDMA[i].valid && DDMA[i].ready;
      if (DDMA[i].valid && DDMA[i].ready) got.push_back('{i, longint'(DDMA[i].req.paddr), longint'(DDMA[i].req.len), DDMA[i].req.last, $time/2});
    end
  end
  int lock_cycles = 0; bit count_lock = 1;
  always @(posedge aclk) if (aresetn && lock && count_lock) lock_cycles++;

  task automatic send(input longint va, input longint len, input int dest, input bit phys, input bit last);
    req_t d; d = '0;
    d.opcode = LOCAL_READ; d.strm = STRM_CARD; d.dest = dest; d.pid = 1; d.vaddr = va; d.len = len; d.last = last;
    d.actv = 1'b1; d.host = 1'b0; d.rsrvd = phys;
    @(negedge aclk); sreq.data = d; sreq.valid = 1'b1;
    @(posedge aclk); while (!sreq.ready) @(posedge aclk);
  endtask
  task automatic idle(); @(negedge aclk); sreq.valid = 1'b0; endtask

  int errors = 0;
  task automatic expect_req(input int k, input int dest, input longint paddr, input longint len, input bit last);
    if (k >= got.size()) begin $display("FAIL: missing request %0d", k); errors++; return; end
    if (got[k].dest != dest || got[k].paddr != paddr || got[k].len != len || got[k].last != last) begin
      $display("FAIL: req %0d got dest %0d paddr %h len %0d last %0d, expected dest %0d paddr %h len %0d last %0d",
               k, got[k].dest, got[k].paddr, got[k].len, got[k].last, dest, paddr, len, last); errors++;
    end
  endtask

  initial begin
    sreq.valid = 1'b0; sreq.data = '0;
    repeat (10) @(posedge aclk); aresetn = 1; repeat (5) @(posedge aclk);

    // T1: 45 back-to-back physical 4 KiB reads, round-robin over the 15 card streams, each in its own window
    for (int k = 0; k < 45; k++) send((longint'(k % 15 + 1) << 30) | longint'(k / 15) * 4096, 4096, k % 15, 1, 1);
    idle(); repeat (20) @(posedge aclk);
    if (got.size() != 45) begin $display("FAIL T1: %0d requests out of 45", got.size()); errors++; end
    for (int k = 0; k < 45 && k < got.size(); k++) expect_req(k, k % 15, (longint'(k % 15 + 1) << 30) | longint'(k / 15) * 4096, 4096, 1);
    if (got.size() == 45) $display("T1: 45 physical 4 KiB reads, %0.2f cycles per request (first->last DMA issue)",
                                   real'(got[44].t - got[0].t) / 44.0);

    // T2: 8 KiB crossing a 2 MiB boundary -> two chunks split at the boundary, last only on the second
    send((64'd3 << 30) + (64'd2 << 20) - 4096, 8192, 2, 1, 1); idle(); repeat (20) @(posedge aclk);
    expect_req(45, 2, (64'd3 << 30) + (64'd2 << 20) - 4096, 4096, 0);
    expect_req(46, 2, (64'd3 << 30) + (64'd2 << 20), 4096, 1);

    // T3: 3 MiB from a window base -> 2 MiB + 1 MiB
    send(64'd5 << 30, 3 << 20, 4, 1, 1); idle(); repeat (20) @(posedge aclk);
    expect_req(47, 4, 64'd5 << 30, 2 << 20, 0);
    expect_req(48, 4, (64'd5 << 30) + (2 << 20), 1 << 20, 1);
    $display("T1-T3: mutex requested on %0d cycles (must be 0)", lock_cycles);
    if (lock_cycles != 0) errors++;

    // T4: a translated (non-physical) card read must take the normal path: requests the mutex, issues nothing
    count_lock = 1; lock_cycles = 0;
    send(64'h0000_7f00_0000_0000, 4096, 1, 0, 1); idle(); repeat (30) @(posedge aclk);
    $display("T4: translated read requested the mutex on %0d cycles, DMA requests now %0d (must stay 49)", lock_cycles, got.size());
    if (lock_cycles == 0 || got.size() != 49) errors++;

    // T5 (reference timing of the normal path): mutex free, every lookup a large-page hit -> the stuck T4 request
    // completes, then 30 translated 4 KiB reads back to back; cycles per request = the shared walker's cost
    @(negedge aclk); ldata[TAG_L + PID_BITS + STRM_BITS + 1 +: (PADDR_BITS - PG_L_BITS)] = 'h3; lhit = 1'b1; mutex = 2'b00;
    repeat (20) @(posedge aclk);
    if (got.size() != 50) begin $display("FAIL T5: T4 request not released (%0d)", got.size()); errors++; end
    for (int k = 0; k < 30; k++) send(64'h0000_7f00_0000_0000 + longint'(k) * 4096, 4096, k % 15, 0, 1);
    idle(); repeat (40) @(posedge aclk);
    if (got.size() == 80) $display("T5: translated 4 KiB reads on TLB hits, %0.2f cycles per request; paddr of the first %h (expect page 3 = %h)",
                                   real'(got[79].t - got[50].t) / 29.0, got[50].paddr, (64'h3 << PG_L_BITS));
    else begin $display("FAIL T5: %0d requests", got.size()); errors++; end

    if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #20000; $display("RESULT: TIMEOUT"); $finish; end
endmodule
