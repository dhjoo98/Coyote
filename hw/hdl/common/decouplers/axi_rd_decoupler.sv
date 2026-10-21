/**
 * Ryloth direct read ports (2026-10-20): PR decoupler for one read-only AXI port.
 * While decoupled (partial reconfiguration), no read request leaves the user region and no response is presented to
 * it, as Coyote's axi_decoupler does for full AXI ports. Only araddr/arlen/arvalid and the R channel come from the
 * user side; the remaining AR fields are fixed here and the write half is tied off, so the master side is a complete
 * read-only AXI4 port.
 */

`timescale 1ns / 1ps

import lynxTypes::*;

module axi_rd_decoupler #(
    parameter integer ADDR_BITS = 34
) (
    input  logic            aclk,
    input  logic            aresetn,
    input  logic            decouple,
    AXI4.s                  s_axi,
    AXI4.m                  m_axi
);

// decouple is registered here: the region's decouple signal travels far, and its combinational use in the gates
// below missed timing at 225 MHz (drd14r_225, 10/21). Reset value 1 (decoupled) is safe.
logic dcpl;
`ifdef EN_PR
always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) dcpl <= 1'b1;
    else dcpl <= decouple;
end
`else
assign dcpl = 1'b0;
`endif

assign m_axi.araddr   = {{(64-ADDR_BITS){1'b0}}, s_axi.araddr[ADDR_BITS-1:0]};
assign m_axi.arlen    = s_axi.arlen;
assign m_axi.arvalid  = dcpl ? 1'b0 : s_axi.arvalid;
assign s_axi.arready  = dcpl ? 1'b0 : m_axi.arready;
assign m_axi.arburst  = 2'b01;
assign m_axi.arcache  = 4'b0011;
assign m_axi.arid     = 0;
assign m_axi.arlock   = 1'b0;
assign m_axi.arprot   = 3'b010;
assign m_axi.arqos    = 4'b0;
assign m_axi.arregion = 4'b0;
assign m_axi.arsize   = 3'b110;

assign s_axi.rdata    = m_axi.rdata;
assign s_axi.rresp    = m_axi.rresp;
assign s_axi.rlast    = m_axi.rlast;
assign s_axi.rid      = 0;
assign s_axi.rvalid   = dcpl ? 1'b0 : m_axi.rvalid;
assign m_axi.rready   = dcpl ? 1'b0 : s_axi.rready;

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
