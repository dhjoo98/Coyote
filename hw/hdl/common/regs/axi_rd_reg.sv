/**
 * Ryloth direct read ports (2026-10-20): one register stage on the AXI read channels only.
 * AR and R each go through a two-entry skid buffer (registered valid, data and ready), so a stage can sit on either
 * side of an SLR crossing. The write channels are not carried: the slave side accepts no writes and the master side
 * issues none, so nothing of the write half is built. One ID (rid = 0), in-order responses.
 */

`timescale 1ns / 1ps

import lynxTypes::*;

`include "axi_macros.svh"

module axi_rd_skid #(
    parameter integer W = 32
) (
    input  logic            aclk,
    input  logic            aresetn,
    input  logic            s_valid,
    output logic            s_ready,
    input  logic [W-1:0]    s_data,
    output logic            m_valid,
    input  logic            m_ready,
    output logic [W-1:0]    m_data
);

logic [W-1:0] buf_data;
logic         buf_valid;

// s_ready comes from a flop (no combinational path from m_ready); one entry absorbs the beat that arrives while the
// output stalls.
assign s_ready = !buf_valid;

// Data registers load regardless of reset: with them under the reset branch, synthesis puts the global reset (one
// flop, fan-out above 100k) into the clock enable of every data bit, which missed timing at 225 MHz (drd14r_225,
// 10/21). Only the valid flags are reset.
always_ff @(posedge aclk) begin
    if (m_ready || !m_valid) m_data <= buf_valid ? buf_data : s_data;
    else if (s_valid && s_ready) buf_data <= s_data;
end

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        m_valid   <= 1'b0;
        buf_valid <= 1'b0;
    end
    else begin
        if (m_ready || !m_valid) begin
            if (buf_valid) begin
                m_valid   <= 1'b1;
                buf_valid <= 1'b0;
            end
            else begin
                m_valid <= s_valid;
            end
        end
        else if (s_valid && s_ready) begin
            buf_valid <= 1'b1;
        end
    end
end

endmodule

module axi_rd_reg #(
    parameter integer ADDR_BITS = 34
) (
    input  logic            aclk,
    input  logic            aresetn,
    AXI4.s                  s_axi,
    AXI4.m                  m_axi
);

localparam integer AR_BITS = ADDR_BITS + 8;
localparam integer R_BITS  = AXI_DATA_BITS + 3;

logic [AR_BITS-1:0] ar_s, ar_m;
logic [R_BITS-1:0]  r_s, r_m;

assign ar_s = {s_axi.araddr[ADDR_BITS-1:0], s_axi.arlen};
assign r_s  = {m_axi.rdata, m_axi.rresp, m_axi.rlast};

axi_rd_skid #(.W(AR_BITS)) inst_ar (
    .aclk(aclk), .aresetn(aresetn),
    .s_valid(s_axi.arvalid), .s_ready(s_axi.arready), .s_data(ar_s),
    .m_valid(m_axi.arvalid), .m_ready(m_axi.arready), .m_data(ar_m)
);

axi_rd_skid #(.W(R_BITS)) inst_r (
    .aclk(aclk), .aresetn(aresetn),
    .s_valid(m_axi.rvalid), .s_ready(m_axi.rready), .s_data(r_s),
    .m_valid(s_axi.rvalid), .m_ready(s_axi.rready), .m_data(r_m)
);

// AR fields that are fixed for direct reads
assign m_axi.araddr   = {{(64-ADDR_BITS){1'b0}}, ar_m[AR_BITS-1:8]};
assign m_axi.arlen    = ar_m[7:0];
assign m_axi.arburst  = 2'b01;
assign m_axi.arcache  = 4'b0011;
assign m_axi.arid     = 0;
assign m_axi.arlock   = 1'b0;
assign m_axi.arprot   = 3'b010;
assign m_axi.arqos    = 4'b0;
assign m_axi.arregion = 4'b0;
assign m_axi.arsize   = 3'b110;

assign s_axi.rdata = r_m[R_BITS-1:3];
assign s_axi.rresp = r_m[2:1];
assign s_axi.rlast = r_m[0];
assign s_axi.rid   = 0;

// no write half
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

module axi_rd_reg_array #(
    parameter integer N_STAGES = 2,
    parameter integer ADDR_BITS = 34
) (
    input  logic            aclk,
    input  logic            aresetn,
    AXI4.s                  s_axi,
    AXI4.m                  m_axi
);

if (N_STAGES == 0) begin
    `AXI_ASSIGN(s_axi, m_axi)
end
else begin
    AXI4 axi_s [N_STAGES+1] ();
    `AXI_ASSIGN(s_axi, axi_s[0])
    `AXI_ASSIGN(axi_s[N_STAGES], m_axi)
    for (genvar i = 0; i < N_STAGES; i++) begin
        axi_rd_reg #(.ADDR_BITS(ADDR_BITS)) inst_reg (.aclk(aclk), .aresetn(aresetn), .s_axi(axi_s[i]), .m_axi(axi_s[i+1]));
    end
end

endmodule
