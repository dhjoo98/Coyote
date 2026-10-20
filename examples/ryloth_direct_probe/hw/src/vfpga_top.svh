/**
 * Ryloth direct-HBM bandwidth probe (2026-10-20).
 *
 * FPGA-initiated card reads on every card stream at once, with a beat counter and a last-beat timestamp
 * per stream, so a shell build with this vFPGA measures the delivered card-memory bandwidth per stream and in
 * aggregate with no host in the loop (same principle as Coyote example 07_perf_fpga, extended from one host
 * stream to N_CARD_AXI card streams). The vFPGA boundary is the stock Coyote one: this app is also the user
 * side of the partial-reconfiguration flow for the direct-HBM shell.
 *
 * Protocol (AXI-Lite CSRs, see probe_ctrl_parser.sv):
 *   write VADDR, STRIDE, LEN, N_REPS, N_BEATS, PID, STREAM_MASK, then CTRL (bit 0 = start, bit 1 = advance).
 *   Stream i issues N_REPS LOCAL_READ requests of LEN bytes from VADDR + i*STRIDE (+ k*LEN per request k when
 *   advance is set, i.e. a sequential scan of its region) with dest = i, strm = STRM_CARD. Requests of the
 *   active streams are issued round-robin through the single send queue. Every stream accepts data as fast as
 *   it arrives. DONE is set when every active stream has issued all requests and received N_BEATS beats.
 *   TIMER counts cycles from start to DONE; per-stream BEATS / T_LAST / ISSUED are read back through SEL.
 */

localparam integer NS = N_CARD_AXI;
localparam integer SEL_BITS = (NS > 1) ? $clog2(NS) : 1;

// ---------------------------------------------------------------- CSRs
logic [1:0]             ctrl;            // [0] start pulse, [1] advance mode
logic [63:0]            csr_vaddr;
logic [63:0]            csr_stride;
logic [31:0]            csr_len;
logic [31:0]            csr_n_reps;
logic [63:0]            csr_n_beats;
logic [PID_BITS-1:0]    csr_pid;
logic [31:0]            csr_mask;
logic [SEL_BITS-1:0]    csr_sel;

logic                   st_done;
logic [31:0]            st_cq_cnt;
logic [63:0]            st_timer;
logic [63:0]            st_t_first;
logic [63:0]            st_beats_sel;
logic [63:0]            st_t_last_sel;
logic [31:0]            st_issued_sel;

probe_ctrl_parser inst_ctrl (
    .aclk(aclk), .aresetn(aresetn), .axi_ctrl(axi_ctrl),
    .ctrl(ctrl), .csr_vaddr(csr_vaddr), .csr_stride(csr_stride), .csr_len(csr_len), .csr_n_reps(csr_n_reps),
    .csr_n_beats(csr_n_beats), .csr_pid(csr_pid), .csr_mask(csr_mask), .csr_sel(csr_sel),
    .st_done(st_done), .st_cq_cnt(st_cq_cnt), .st_timer(st_timer), .st_t_first(st_t_first),
    .st_beats_sel(st_beats_sel), .st_t_last_sel(st_t_last_sel), .st_issued_sel(st_issued_sel),
    .st_n_streams(32'(NS))
);

// ---------------------------------------------------------------- state
logic                   running;
logic                   advance;
logic [NS-1:0]          active;
logic [NS-1:0]          req_done;
logic [NS-1:0]          data_done;
logic [63:0]            cur_vaddr [NS];
logic [31:0]            issued    [NS];
logic [63:0]            beats     [NS];
logic [63:0]            t_last    [NS];
logic [SEL_BITS-1:0]    rr;
logic                   seen_first;
logic [NS-1:0]          beat_fire;

wire start = ctrl[0] && !running;
wire all_done = &(~active | (req_done & data_done));

// request handshake for the stream currently pointed at by rr
wire rr_eligible = running && active[rr] && !req_done[rr];
assign sq_rd.valid = rr_eligible;
wire issue = sq_rd.valid && sq_rd.ready;

always_comb begin
    sq_rd.data        = '0;
    sq_rd.data.vaddr  = cur_vaddr[rr][VADDR_BITS-1:0];
    sq_rd.data.len    = csr_len[LEN_BITS-1:0];
    sq_rd.data.strm   = STRM_CARD;
    sq_rd.data.dest   = rr;
    sq_rd.data.pid    = csr_pid;
    sq_rd.data.opcode = LOCAL_READ;
    sq_rd.data.last   = (issued[rr] == csr_n_reps - 1);
end

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        running <= 1'b0; advance <= 1'b0; active <= '0; req_done <= '0; data_done <= '0;
        rr <= '0; st_timer <= '0; st_cq_cnt <= '0; st_done <= 1'b0; st_t_first <= '0; seen_first <= 1'b0;
        for (int i = 0; i < NS; i++) begin
            cur_vaddr[i] <= '0; issued[i] <= '0; beats[i] <= '0; t_last[i] <= '0;
        end
    end else begin
        if (start) begin
            running <= 1'b1; advance <= ctrl[1]; st_done <= 1'b0; st_timer <= '0; st_cq_cnt <= '0;
            st_t_first <= '0; seen_first <= 1'b0; rr <= '0;
            for (int i = 0; i < NS; i++) begin
                active[i]    <= csr_mask[i];
                req_done[i]  <= ~csr_mask[i] || (csr_n_reps == 0);
                data_done[i] <= ~csr_mask[i] || (csr_n_beats == 0);
                cur_vaddr[i] <= csr_vaddr + 64'(i) * csr_stride;
                issued[i]    <= '0; beats[i] <= '0; t_last[i] <= '0;
            end
        end else if (running) begin
            st_timer <= st_timer + 1;
            if (cq_rd.valid) st_cq_cnt <= st_cq_cnt + 1;

            // issue side
            if (issue) begin
                issued[rr] <= issued[rr] + 1;
                if (advance) cur_vaddr[rr] <= cur_vaddr[rr] + 64'(csr_len);
                if (issued[rr] == csr_n_reps - 1) req_done[rr] <= 1'b1;
            end
            // round-robin pointer moves every cycle so a stalled or finished stream never blocks the others
            rr <= (rr == SEL_BITS'(NS - 1)) ? '0 : rr + 1;

            // data side (beat_fire is a packed vector, so a variable index is legal here)
            if (|beat_fire && !seen_first) begin seen_first <= 1'b1; st_t_first <= st_timer; end
            for (int i = 0; i < NS; i++) begin
                if (beat_fire[i]) begin
                    beats[i]  <= beats[i] + 1;
                    t_last[i] <= st_timer;
                    if (beats[i] == csr_n_beats - 1) data_done[i] <= 1'b1;
                end
            end

            if (all_done) begin running <= 1'b0; st_done <= 1'b1; end
        end
    end
end

// every active stream drains at line rate; inactive streams also drain so nothing can wedge the shell.
// Interface arrays may only be indexed by constants, hence the generate loop and the packed beat_fire vector.
for (genvar i = 0; i < NS; i++) begin : gen_card_recv
    assign axis_card_recv[i].tready = 1'b1;
    assign beat_fire[i] = axis_card_recv[i].tvalid && axis_card_recv[i].tready;
end

// per-stream readback
assign st_beats_sel  = beats[csr_sel];
assign st_t_last_sel = t_last[csr_sel];
assign st_issued_sel = issued[csr_sel];

// ---------------------------------------------------------------- tie-offs
for (genvar i = 0; i < NS; i++) begin : gen_card_send_tieoff
    assign axis_card_send[i].tvalid = 1'b0;
    assign axis_card_send[i].tdata  = '0;
    assign axis_card_send[i].tkeep  = '0;
    assign axis_card_send[i].tlast  = 1'b0;
end

assign axis_host_recv[0].tready = 1'b1;
assign axis_host_send[0].tvalid = 1'b0;
assign axis_host_send[0].tdata  = '0;
assign axis_host_send[0].tkeep  = '0;
assign axis_host_send[0].tlast  = 1'b0;

always_comb begin
    cq_rd.ready = 1'b1;
    sq_wr.tie_off_m();
    cq_wr.tie_off_s();
    notify.tie_off_m();
end
