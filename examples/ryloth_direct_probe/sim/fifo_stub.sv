// Behavioral stand-in for the Xilinx IP axis_data_fifo_cch_req_128 (simulation only)
module axis_data_fifo_cch_req_128 (
  input  logic s_axis_aresetn, input logic s_axis_aclk,
  input  logic s_axis_tvalid, output logic s_axis_tready, input logic [127:0] s_axis_tdata,
  output logic m_axis_tvalid, input logic m_axis_tready, output logic [127:0] m_axis_tdata);
  logic [127:0] q[$];
  assign s_axis_tready = (q.size() < 16);
  assign m_axis_tvalid = (q.size() > 0);
  assign m_axis_tdata  = (q.size() > 0) ? q[0] : '0;
  always @(posedge s_axis_aclk) begin
    if (!s_axis_aresetn) q.delete();
    else begin
      if (m_axis_tvalid && m_axis_tready) void'(q.pop_front());
      if (s_axis_tvalid && s_axis_tready) q.push_back(s_axis_tdata);
    end
  end
endmodule
