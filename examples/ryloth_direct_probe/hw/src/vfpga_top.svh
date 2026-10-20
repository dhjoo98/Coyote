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
 *   for each stream: write SEL then VADDR; then LEN, N_REPS, N_BEATS, PID, STREAM_MASK, then CTRL (bit 0 = start,
 *   bit 1 = advance, bit 2 = physical card addresses for a stage-2 shell).
 *   Stream i issues N_REPS LOCAL_READ requests of LEN bytes from its own base (VADDR written with SEL = i; one
 *   entry per stream) (+ k*LEN per request k when advance is set, i.e. a sequential scan of its region) with
 *   dest = i, strm = STRM_CARD. Requests of the
 *   active streams are issued round-robin through the single send queue. Every stream accepts data as fast as
 *   it arrives. DONE is set when every active stream has issued all requests and received N_BEATS beats.
 *   TIMER counts cycles from start to DONE; per-stream BEATS / T_LAST / ISSUED are read back through SEL.
 *
 * v3 (direct read ports, 2026-10-20): streams 0 .. N_CARD_AXI-1 are Coyote card streams as above; streams
 * N_CARD_AXI .. N_CARD_AXI+N_DIRECT_RD-1 are direct read ports (axi_drd[k]), each driven by a drd_reader. For those,
 * VADDR is a card physical address and every request is one drd_reader command of LEN bytes (no MMU, no sq_rd).
 * N_DIRECT is read back at register 18.
 */

localparam integer NC = N_CARD_AXI;
localparam integer ND = N_DIRECT_RD;
localparam integer NS = NC + ND;
localparam integer SEL_BITS = (NS > 1) ? $clog2(NS) : 1;
localparam integer RR_BITS = (NC > 1) ? $clog2(NC) : 1;

// ---------------------------------------------------------------- CSRs
logic [2:0]             ctrl;            // [0] start pulse, [1] advance mode, [2] physical card addresses (stage-2 TLB bypass)
logic [63:0]            csr_vaddr;
logic                   csr_vaddr_we;
logic [63:0]            csr_stride;      // unused: per-stream table below
logic [31:0]            csr_sel_raw;
logic [2:0]             csr_lane;
logic [63:0]            st_csum_sel;
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
    .ctrl(ctrl), .csr_vaddr(csr_vaddr), .csr_vaddr_we(csr_vaddr_we), .csr_stride(csr_stride), .csr_len(csr_len),
    .csr_n_reps(csr_n_reps), .csr_n_beats(csr_n_beats), .csr_pid(csr_pid), .csr_mask(csr_mask), .csr_sel_raw(csr_sel_raw),
    .st_done(st_done), .st_cq_cnt(st_cq_cnt), .st_timer(st_timer), .st_t_first(st_t_first),
    .st_beats_sel(st_beats_sel), .st_t_last_sel(st_t_last_sel), .st_issued_sel(st_issued_sel),
    .st_n_streams(32'(NS)), .csr_lane(csr_lane), .st_csum_sel(st_csum_sel), .st_n_direct(32'(ND))
);

// ---------------------------------------------------------------- state
logic                   running;
logic                   advance;
logic                   phys;            // requests carry req.rsrvd[0] = 1: the shell's tlb_fsm bypasses the TLB (stage 2)
logic [NS-1:0]          active;
logic [NS-1:0]          req_done;
logic [NS-1:0]          data_done;
logic [63:0]            cur_vaddr [NS];
logic [31:0]            issued    [NS];
logic [63:0]            beats     [NS];
logic [63:0]            t_last    [NS];
logic [RR_BITS-1:0]     rr;              // round-robin over the Coyote card streams only
logic                   seen_first;
logic [63:0]            vaddr_tab [NS];     // per-stream region base, written through SEL + VADDR
assign csr_sel = csr_sel_raw[SEL_BITS-1:0];
logic [NS-1:0]          beat_fire;
logic [511:0]           beat_data [NS];
logic [ND > 0 ? ND-1 : 0:0] drd_fire;     // a direct stream's command accepted this cycle

wire start = ctrl[0] && !running;
wire all_done = &(~active | (req_done & data_done));

// request handshake for the Coyote card stream currently pointed at by rr
wire rr_eligible = running && active[rr] && !req_done[rr];
wire issue = rr_eligible && sq_rd.ready;

// Vivado synthesis resolves interface members of sq_rd only inside procedural blocks (07_perf_fpga does the same);
// a continuous assign to sq_rd.valid failed with "cannot resolve hierarchical name for the item 'valid'".
always_comb begin
    sq_rd.valid       = rr_eligible;
    sq_rd.data        = '0;
    sq_rd.data.vaddr  = cur_vaddr[rr][VADDR_BITS-1:0];
    sq_rd.data.len    = csr_len[LEN_BITS-1:0];
    sq_rd.data.strm   = STRM_CARD;
    sq_rd.data.dest   = rr;
    sq_rd.data.pid    = csr_pid;
    sq_rd.data.opcode = LOCAL_READ;
    sq_rd.data.last   = (issued[rr] == csr_n_reps - 1);
    sq_rd.data.rsrvd  = phys;        // zero-extended: rsrvd[0] = physical card address (ignored by a stage-1 shell)
end

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        running <= 1'b0; advance <= 1'b0; phys <= 1'b0; active <= '0; req_done <= '0; data_done <= '0;
        rr <= '0; st_timer <= '0; st_cq_cnt <= '0; st_done <= 1'b0; st_t_first <= '0; seen_first <= 1'b0;
        for (int i = 0; i < NS; i++) begin
            cur_vaddr[i] <= '0; issued[i] <= '0; beats[i] <= '0; t_last[i] <= '0; vaddr_tab[i] <= '0;
        end
    end else begin
        if (csr_vaddr_we && !running) vaddr_tab[csr_sel] <= csr_vaddr;
        if (start) begin
            running <= 1'b1; advance <= ctrl[1]; phys <= ctrl[2]; st_done <= 1'b0; st_timer <= '0; st_cq_cnt <= '0;
            st_t_first <= '0; seen_first <= 1'b0; rr <= '0;
            for (int i = 0; i < NS; i++) begin
                active[i]    <= csr_mask[i];
                req_done[i]  <= ~csr_mask[i] || (csr_n_reps == 0);
                data_done[i] <= ~csr_mask[i] || (csr_n_beats == 0);
                cur_vaddr[i] <= vaddr_tab[i];
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
            rr <= (rr == RR_BITS'(NC - 1)) ? '0 : rr + 1;

            // direct read ports: one drd_reader command per request
            for (int k = 0; k < ND; k++) begin
                if (drd_fire[k]) begin
                    issued[NC+k] <= issued[NC+k] + 1;
                    if (advance) cur_vaddr[NC+k] <= cur_vaddr[NC+k] + 64'(csr_len);
                    if (issued[NC+k] == csr_n_reps - 1) req_done[NC+k] <= 1'b1;
                end
            end

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
for (genvar i = 0; i < NC; i++) begin : gen_card_recv
    assign axis_card_recv[i].tready = 1'b1;
    assign beat_fire[i] = axis_card_recv[i].tvalid && axis_card_recv[i].tready;
    assign beat_data[i] = axis_card_recv[i].tdata;
end

// direct read ports: a drd_reader per port, data drained at line rate
for (genvar k = 0; k < ND; k++) begin : gen_drd
    logic cmd_valid, cmd_ready, tvalid, tlast, busy;
    logic [511:0] tdata;
    assign cmd_valid = running && active[NC+k] && !req_done[NC+k];
    assign drd_fire[k] = cmd_valid && cmd_ready;
    drd_reader #(.ADDR_BITS(DRD_ADDR_BITS), .MAX_OUT(32), .BURST_BEATS(16)) inst_drd (
        .aclk(aclk), .aresetn(aresetn),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_addr(cur_vaddr[NC+k][DRD_ADDR_BITS-1:0]), .cmd_len(csr_len),
        .cmd_last(issued[NC+k] == csr_n_reps - 1),
        .m_axi(axi_drd[k]),
        .m_tdata(tdata), .m_tvalid(tvalid), .m_tlast(tlast), .m_tready(1'b1), .busy(busy)
    );
    assign beat_fire[NC+k] = tvalid;
    assign beat_data[NC+k] = tdata;
end
if (ND == 0) begin : gen_no_drd
    assign drd_fire = '0;
end

// data check: per stream, eight 64-bit lane accumulators (sum mod 2^64 of word j of every beat). Keeps all 512 data
// bits of every card stream alive (so the full buses route into the region) and lets the host verify every byte read.
logic [63:0] csum_mux [NS];
for (genvar i = 0; i < NS; i++) begin : g_csum
    logic [7:0][63:0] acc;
    always_ff @(posedge aclk) begin
        if (!aresetn || start) acc <= '0;
        else if (beat_fire[i]) begin
            for (int j = 0; j < 8; j++) acc[j] <= acc[j] + beat_data[i][64*j +: 64];
        end
    end
    assign csum_mux[i] = acc[csr_lane];
end
always_ff @(posedge aclk) st_csum_sel <= csum_mux[csr_sel];   // registered: off the AXI-Lite read path

// per-stream readback
assign st_beats_sel  = beats[csr_sel];
assign st_t_last_sel = t_last[csr_sel];
assign st_issued_sel = issued[csr_sel];

// ---------------------------------------------------------------- tie-offs
for (genvar i = 0; i < NC; i++) begin : gen_card_send_tieoff
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
