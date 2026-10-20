/**
 * Ryloth direct-HBM probe: AXI-Lite control registers.
 * Register file and read mux are new; the AXI-Lite handshake logic is the one from Coyote's
 * examples/07_perf_fpga/perf_fpga_axi_ctrl_parser.sv, kept verbatim.
 *
 * Map (64-bit registers, byte offset = index * 8):
 *   0  CTRL       w  [0] start (self-clearing pulse), [1] advance (vaddr += len per request within a stream), [2] phys (stage-2 TLB bypass)
 *   1  STATUS     r  [0] done, [63:32] completions seen on cq_rd
 *   2  TIMER      r  cycles from start to done (ACLK)
 *   3  VADDR      w  base address of stream SEL's region (write SEL first; one entry per stream)
 *   4  LEN        w  bytes per request
 *   5  PID        w  Coyote thread id
 *   6  N_REPS     w  requests per stream
 *   7  N_BEATS    w  expected 64 B beats per stream (= N_REPS * ceil(LEN / 64))
 *   8  STRIDE     w  unused since the per-stream VADDR table (kept so the map does not move)
 *   9  MASK       w  active streams (bit i = stream i)
 *   10 SEL        w  stream index for the per-stream readbacks below
 *   11 BEATS_SEL  r  beats received by stream SEL
 *   12 T_LAST_SEL r  timer value at the last beat of stream SEL
 *   13 ISSUED_SEL r  requests issued for stream SEL
 *   14 N_STREAMS  r  N_CARD_AXI of this build
 *   15 T_FIRST    r  timer value at the first beat on any stream (request latency)
 *   16 LANE       w  64-bit word lane (0..7) for CSUM_SEL
 *   17 CSUM_SEL   r  sum (mod 2^64) of 64-bit word LANE of every beat received by stream SEL (data check)
 */

import lynxTypes::*;

module probe_ctrl_parser (
  input  logic                        aclk,
  input  logic                        aresetn,

  AXI4L.s                             axi_ctrl,

  output logic [2:0]                  ctrl,
  output logic [63:0]                 csr_vaddr,
  output logic                        csr_vaddr_we,   // one-cycle strobe after a VADDR write (host writes SEL first)
  output logic [63:0]                 csr_stride,
  output logic [31:0]                 csr_len,
  output logic [31:0]                 csr_n_reps,
  output logic [63:0]                 csr_n_beats,
  output logic [PID_BITS-1:0]         csr_pid,
  output logic [31:0]                 csr_mask,
  output logic [31:0]                 csr_sel_raw,
  output logic [2:0]                  csr_lane,

  input  logic                        st_done,
  input  logic [31:0]                 st_cq_cnt,
  input  logic [63:0]                 st_timer,
  input  logic [63:0]                 st_t_first,
  input  logic [63:0]                 st_beats_sel,
  input  logic [63:0]                 st_t_last_sel,
  input  logic [31:0]                 st_issued_sel,
  input  logic [31:0]                 st_n_streams,
  input  logic [63:0]                 st_csum_sel
);

localparam integer N_REGS = 32;
localparam integer ADDR_MSB = $clog2(N_REGS);
localparam integer ADDR_LSB = $clog2(AXIL_DATA_BITS/8);
localparam integer AXI_ADDR_BITS = ADDR_LSB + ADDR_MSB;

localparam integer R_CTRL = 0, R_STATUS = 1, R_TIMER = 2, R_VADDR = 3, R_LEN = 4, R_PID = 5, R_N_REPS = 6,
                   R_N_BEATS = 7, R_STRIDE = 8, R_MASK = 9, R_SEL = 10, R_BEATS_SEL = 11, R_T_LAST_SEL = 12,
                   R_ISSUED_SEL = 13, R_N_STREAMS = 14, R_T_FIRST = 15, R_LANE = 16, R_CSUM_SEL = 17;

logic [AXI_ADDR_BITS-1:0] axi_awaddr;
logic axi_awready;
logic [AXI_ADDR_BITS-1:0] axi_araddr;
logic axi_arready;
logic [1:0] axi_bresp;
logic axi_bvalid;
logic axi_wready;
logic [AXIL_DATA_BITS-1:0] axi_rdata;
logic [1:0] axi_rresp;
logic axi_rvalid;
logic aw_en;

logic [N_REGS-1:0][AXIL_DATA_BITS-1:0] ctrl_reg;
logic ctrl_reg_rden;
logic ctrl_reg_wren;

assign ctrl_reg_wren = axi_wready && axi_ctrl.wvalid && axi_awready && axi_ctrl.awvalid;

// ---------------------------------------------------------------- write path (byte-strobed, CTRL self-clears)
always_ff @(posedge aclk) begin
  if (aresetn == 1'b0) begin
    ctrl_reg <= 0;
    csr_vaddr_we <= 1'b0;
  end
  else begin
    ctrl_reg[R_CTRL] <= 0;
    csr_vaddr_we <= ctrl_reg_wren && (axi_awaddr[ADDR_LSB+:ADDR_MSB] == R_VADDR);
    if (ctrl_reg_wren) begin
      case (axi_awaddr[ADDR_LSB+:ADDR_MSB])
        R_CTRL, R_VADDR, R_LEN, R_PID, R_N_REPS, R_N_BEATS, R_STRIDE, R_MASK, R_SEL, R_LANE:
          for (int i = 0; i < (AXIL_DATA_BITS/8); i++) begin
            if (axi_ctrl.wstrb[i]) begin
              ctrl_reg[axi_awaddr[ADDR_LSB+:ADDR_MSB]][(i*8)+:8] <= axi_ctrl.wdata[(i*8)+:8];
            end
          end
        default: ;
      endcase
    end
  end
end

// ---------------------------------------------------------------- read path
assign ctrl_reg_rden = axi_arready & axi_ctrl.arvalid & ~axi_rvalid;

always_ff @(posedge aclk) begin
  if (aresetn == 1'b0) begin
    axi_rdata <= 0;
  end
  else begin
    if (ctrl_reg_rden) begin
      axi_rdata <= 0;
      case (axi_araddr[ADDR_LSB+:ADDR_MSB])
        R_STATUS:     begin axi_rdata[0] <= st_done; axi_rdata[63:32] <= st_cq_cnt; end
        R_TIMER:      axi_rdata <= st_timer;
        R_VADDR:      axi_rdata <= ctrl_reg[R_VADDR];
        R_LEN:        axi_rdata <= ctrl_reg[R_LEN];
        R_PID:        axi_rdata <= ctrl_reg[R_PID];
        R_N_REPS:     axi_rdata <= ctrl_reg[R_N_REPS];
        R_N_BEATS:    axi_rdata <= ctrl_reg[R_N_BEATS];
        R_STRIDE:     axi_rdata <= ctrl_reg[R_STRIDE];
        R_MASK:       axi_rdata <= ctrl_reg[R_MASK];
        R_SEL:        axi_rdata <= ctrl_reg[R_SEL];
        R_BEATS_SEL:  axi_rdata <= st_beats_sel;
        R_T_LAST_SEL: axi_rdata <= st_t_last_sel;
        R_ISSUED_SEL: axi_rdata[31:0] <= st_issued_sel;
        R_N_STREAMS:  axi_rdata[31:0] <= st_n_streams;
        R_T_FIRST:    axi_rdata <= st_t_first;
        R_LANE:       axi_rdata <= ctrl_reg[R_LANE];
        R_CSUM_SEL:   axi_rdata <= st_csum_sel;
        default: ;
      endcase
    end
  end
end

// ---------------------------------------------------------------- outputs
always_comb begin
  ctrl        = ctrl_reg[R_CTRL][2:0];
  csr_vaddr   = ctrl_reg[R_VADDR];
  csr_stride  = ctrl_reg[R_STRIDE];
  csr_len     = ctrl_reg[R_LEN][31:0];
  csr_n_reps  = ctrl_reg[R_N_REPS][31:0];
  csr_n_beats = ctrl_reg[R_N_BEATS];
  csr_pid     = ctrl_reg[R_PID][PID_BITS-1:0];
  csr_mask    = ctrl_reg[R_MASK][31:0];
  csr_sel_raw = ctrl_reg[R_SEL][31:0];
  csr_lane    = ctrl_reg[R_LANE][2:0];
end

// ---------------------------------------------------------------- AXI-Lite handshake (verbatim from 07_perf_fpga)
assign axi_ctrl.awready = axi_awready;
assign axi_ctrl.arready = axi_arready;
assign axi_ctrl.bresp = axi_bresp;
assign axi_ctrl.bvalid = axi_bvalid;
assign axi_ctrl.wready = axi_wready;
assign axi_ctrl.rdata = axi_rdata;
assign axi_ctrl.rresp = axi_rresp;
assign axi_ctrl.rvalid = axi_rvalid;

always_ff @(posedge aclk) begin
  if ( aresetn == 1'b0 )
    begin
      axi_awready <= 1'b0;
      axi_awaddr <= 0;
      aw_en <= 1'b1;
    end
  else
    begin
      if (~axi_awready && axi_ctrl.awvalid && axi_ctrl.wvalid && aw_en)
        begin
          axi_awready <= 1'b1;
          aw_en <= 1'b0;
          axi_awaddr <= axi_ctrl.awaddr;
        end
      else if (axi_ctrl.bready && axi_bvalid)
        begin
          aw_en <= 1'b1;
          axi_awready <= 1'b0;
        end
      else
        begin
          axi_awready <= 1'b0;
        end
    end
end

always_ff @(posedge aclk) begin
  if ( aresetn == 1'b0 )
    begin
      axi_arready <= 1'b0;
      axi_araddr  <= 0;
    end
  else
    begin
      if (~axi_arready && axi_ctrl.arvalid)
        begin
          axi_arready <= 1'b1;
          axi_araddr  <= axi_ctrl.araddr;
        end
      else
        begin
          axi_arready <= 1'b0;
        end
    end
end

always_ff @(posedge aclk) begin
  if ( aresetn == 1'b0 )
    begin
      axi_bvalid  <= 0;
      axi_bresp   <= 2'b0;
    end
  else
    begin
      if (axi_awready && axi_ctrl.awvalid && ~axi_bvalid && axi_wready && axi_ctrl.wvalid)
        begin
          axi_bvalid <= 1'b1;
          axi_bresp  <= 2'b0;
        end
      else
        begin
          if (axi_ctrl.bready && axi_bvalid)
            begin
              axi_bvalid <= 1'b0;
            end
        end
    end
end

always_ff @(posedge aclk) begin
  if ( aresetn == 1'b0 )
    begin
      axi_wready <= 1'b0;
    end
  else
    begin
      if (~axi_wready && axi_ctrl.wvalid && axi_ctrl.awvalid && aw_en )
        begin
          axi_wready <= 1'b1;
        end
      else
        begin
          axi_wready <= 1'b0;
        end
    end
end

always_ff @(posedge aclk) begin
  if ( aresetn == 1'b0 )
    begin
      axi_rvalid <= 0;
      axi_rresp  <= 0;
    end
  else
    begin
      if (axi_arready && axi_ctrl.arvalid && ~axi_rvalid)
        begin
          axi_rvalid <= 1'b1;
          axi_rresp  <= 2'b0;
        end
      else if (axi_rvalid && axi_ctrl.rready)
        begin
          axi_rvalid <= 1'b0;
        end
    end
end

endmodule
