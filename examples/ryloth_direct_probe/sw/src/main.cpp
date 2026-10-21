/**
 * Ryloth direct-HBM probe, host side (2026-10-20).
 *
 * Drives the probe vFPGA (hw/src/vfpga_top.svh): one card-memory region per stream, all streams reading at once,
 * FPGA-side timer and per-stream beat counters. Reports GB/s per stream and in aggregate.
 *
 * Memory placement: each stream's region is a huge-page host buffer migrated to card memory with LOCAL_OFFLOAD
 * (as the Ryloth host program places the index today). With --windows (default) region i is allocated with
 * mem_block = i + 1, i.e. in card window i+1, which the direct-HBM shell (HBM_DIRECT=1) serves to card stream i
 * without crossing the HBM switch (HBM port 0 is the shell's own DMA, port i+1 is card stream i). With
 * --windows=0 the driver places the regions first-free, which on the old shell is the same probe as today.
 */
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <thread>
#include <array>
#include <utility>
#include <vector>
#include <boost/program_options.hpp>
#include <coyote/cThread.hpp>
#include <coyote/cRcnfg.hpp>

namespace {
constexpr uint32_t R_CTRL = 0, R_STATUS = 1, R_TIMER = 2, R_VADDR = 3, R_LEN = 4, R_PID = 5, R_N_REPS = 6,
                   R_N_BEATS = 7, R_STRIDE = 8, R_MASK = 9, R_SEL = 10, R_BEATS_SEL = 11, R_T_LAST_SEL = 12,
                   R_ISSUED_SEL = 13, R_N_STREAMS = 14, R_T_FIRST = 15, R_LANE = 16, R_CSUM_SEL = 17, R_N_DIRECT = 18,
                   R_MAX_OUT = 19;
constexpr int DEFAULT_VFPGA_ID = 0;
// deterministic fill: word k of stream i's region
bool g_started = false;   // set once the first probe run has been started (for the exception message)

inline uint64_t splitmix64(uint64_t x) {
    x += 0x9e3779b97f4a7c15ull; x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull; x = (x ^ (x >> 27)) * 0x94d049bb133111ebull;
    return x ^ (x >> 31);
}
}

static int run(int argc, char *argv[]) {
    unsigned n_streams_req, n_runs, reps, first, max_out, group;
    std::string partial;
    uint64_t region, len;
    double aclk_mhz;
    bool advance, windows, phys, datacheck;
    boost::program_options::options_description opts("Ryloth direct-HBM probe");
    opts.add_options()
        ("help,h", "print this help")
        ("streams,s", boost::program_options::value<unsigned>(&n_streams_req)->default_value(0), "streams to drive (0 = all the build has)")
        ("first,f", boost::program_options::value<unsigned>(&first)->default_value(0), "first stream to drive (streams first..first+streams-1)")
        ("region,R", boost::program_options::value<uint64_t>(&region)->default_value(256ull << 20), "bytes per stream region (allocated and offloaded to card)")
        ("len,l", boost::program_options::value<uint64_t>(&len)->default_value(1ull << 20), "bytes per request")
        ("reps,n", boost::program_options::value<unsigned>(&reps)->default_value(0), "requests per stream (0 = region / len)")
        ("advance,a", boost::program_options::value<bool>(&advance)->default_value(true), "sequential scan of the region (else re-read the same address)")
        ("windows,w", boost::program_options::value<bool>(&windows)->default_value(true), "place region i in card window i+1 (mem_block); 0 = first-free")
        ("datacheck,d", boost::program_options::value<bool>(&datacheck)->default_value(true), "verify lane sums (probe v2 bitstreams only; use 0 with the probe15 v1 partial, whose 16-register map aliases register 16 onto CTRL)")
        ("phys,p", boost::program_options::value<bool>(&phys)->default_value(false), "stage 2: issue physical card reads (TLB bypass); needs the direct-HBM driver and a stage-2 shell")
        ("runs,r", boost::program_options::value<unsigned>(&n_runs)->default_value(5), "repetitions")
        ("aclk", boost::program_options::value<double>(&aclk_mhz)->default_value(150.0), "ACLK in MHz (timer clock)")
        ("max_out,o", boost::program_options::value<unsigned>(&max_out)->default_value(8), "bursts in flight per direct read port, 1..32 (probe v4+; 8 keeps the shell's read return free of back-pressure, 32 reproduces the 10/20 step-5 stall)")
        ("partial", boost::program_options::value<std::string>(&partial)->default_value(""), "load this user partial bitstream (vfpga_c0_0.bin) through Coyote app reconfiguration before the run (the shell must be idle)")
        ("group,g", boost::program_options::value<unsigned>(&group)->default_value(1), "with --windows 1: streams per card window, stream i goes to window i/group + 1 (1 = its own window; 3 = three ports per pseudo-channel pair, the step-5 layout, independent of what ran before)");
    boost::program_options::variables_map vm;
    boost::program_options::store(boost::program_options::parse_command_line(argc, argv, opts), vm);
    boost::program_options::notify(vm);
    if (vm.count("help")) { std::cout << opts << std::endl; return 0; }

    if (max_out < 1 || max_out > 32) { std::cerr << "--max_out must be 1..32" << std::endl; return 2; }
    if (group < 1 || group > 16) { std::cerr << "--group must be 1..16" << std::endl; return 2; }
    coyote::cThread t(DEFAULT_VFPGA_ID, getpid());

    // The probe has no abort: a run that timed out keeps it busy and every later start is ignored. Refuse to start on
    // top of one (its timer still advances). Checked BEFORE a --partial load, so a forgotten JTAG is harmless.
    {
        const uint64_t t1 = t.getCSR(R_TIMER);
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        if (t.getCSR(R_TIMER) != t1 && !(t.getCSR(R_STATUS) & 1ull)) {
            std::cerr << "the probe is still busy with an earlier run (one that timed out). It has no abort: reprogram the "
                         "full image over JTAG and warm reboot, then run again." << std::endl;
            return 6;
        }
    }
    if (!partial.empty()) {
        std::cout << "loading user partial " << partial << " (app reconfiguration of vFPGA " << DEFAULT_VFPGA_ID << ")" << std::endl;
        coyote::cRcnfg rc(0);
        rc.reconfigureApp(partial, DEFAULT_VFPGA_ID);
        std::cout << "partial loaded" << std::endl;
    }
    const unsigned n_build = static_cast<unsigned>(t.getCSR(R_N_STREAMS));
    // probe v3: the last n_direct streams are direct read ports (physical card addresses, no MMU); older partials read 0
    const unsigned n_direct = static_cast<unsigned>(t.getCSR(R_N_DIRECT)) & 0xffu;
    const unsigned first_direct = (n_direct <= n_build) ? n_build - n_direct : n_build;
    if (n_direct) std::cout << "direct read ports: streams " << first_direct << " .. " << n_build - 1 << std::endl;
    // probe v4: register 19 limits the bursts in flight per direct port; older partials ignore the write (readback 0)
    t.setCSR(max_out, R_MAX_OUT);
    const bool has_max_out = (t.getCSR(R_MAX_OUT) & 0xffu) == max_out;
    if (n_direct) std::cout << "bursts in flight per direct port: " << (has_max_out ? std::to_string(max_out) : std::string("32 (probe v3 partial, register 19 absent)")) << std::endl;
    if (first >= n_build) { std::cerr << "first stream " << first << " >= build streams " << n_build << std::endl; return 1; }
    unsigned S = (n_streams_req == 0) ? n_build - first : n_streams_req;
    if (first + S > n_build) S = n_build - first;
    // Limits (review 10/20): direct read ports read whole 64 B beats (a length that is not a multiple of 64 never
    // completes); a region must fit one card window's huge-page pool (driver 33d016bc: 1 GiB block minus its 16 MiB
    // regular pool); the requests must stay inside the region.
    const uint64_t kMaxRegion = 1008ull << 20;
    if (len == 0 || len % 64 != 0) { std::cerr << "--len must be a positive multiple of 64 B" << std::endl; return 2; }
    if (region == 0 || region % 4096 != 0 || region > kMaxRegion) {
        std::cerr << "--region must be a multiple of 4 KiB and at most 1008 MiB (one card window's huge-page pool)" << std::endl; return 2;
    }
    if (reps == 0) reps = static_cast<unsigned>(region / len);
    if (reps == 0 || (advance ? static_cast<uint64_t>(reps) * len : len) > region) {
        std::cerr << "requests exceed the region: " << reps << " x " << len << " B in " << region << " B" << std::endl; return 2;
    }
    const uint64_t beats_per_stream = static_cast<uint64_t>(reps) * ((len + 63) / 64);
    std::cout << "build streams " << n_build << ", driving " << S << " (from " << first << "), region " << (region >> 20)
              << " MiB, request " << (len >> 10) << " KiB x " << reps << " per stream, " << (advance ? "sequential" : "same address")
              << ", placement " << (windows ? (group == 1 ? std::string("window i+1") : "window i/" + std::to_string(group) + "+1") : std::string("first-free")) << std::endl;

    // one region per driven stream, migrated to the card (needs region / 2 MiB free hugepages per stream)
    std::vector<char*> regions(S);
    for (unsigned k = 0; k < S; k++) {
        const unsigned i = first + k;
        coyote::CoyoteAlloc a;
        a.alloc = coyote::CoyoteAllocType::HPF;
        a.size = static_cast<uint32_t>(region);
        a.mem_block = windows ? static_cast<int32_t>(i / group + 1) : -1;
        regions[k] = static_cast<char*>(t.getMem(std::move(a)));
        if (!regions[k]) { std::cerr << "allocation failed for stream " << i << std::endl; return 1; }
        uint64_t *w = reinterpret_cast<uint64_t*>(regions[k]);
        for (uint64_t x = 0; x < region / 8; x++) w[x] = splitmix64((static_cast<uint64_t>(i) << 40) ^ x);
        // Blocking: the driver migrates the pages to the card. It migrates the WHOLE mapping that contains the first
        // page (offload_user_pages -> migrate_to_card of all n_pages), so one call from the region's start moves all of
        // it; the length only has to pass the library's MAX_TRANSFER_SIZE (128 MiB) check. Never offload from an address
        // inside a buffer: the driver looks up mappings by their start page and its loop would not advance (box report
        // 10/20 20:50; upstream Coyote behavior).
        coyote::syncSg sg = {.addr = regions[k], .len = std::min<uint64_t>(region, coyote::MAX_TRANSFER_SIZE)};
        t.invoke(coyote::CoyoteOper::LOCAL_OFFLOAD, sg);
    }

    // Card placement of every region (IOCTL_GET_CARD_PADDR): with --windows the region of stream i must sit in card
    // window i+1, the pseudo-channel next to its HBM port. Direct read ports and stage 2 (--phys) read physical card
    // addresses, so their regions must also be physically contiguous.
    std::vector<uint64_t> bases(S, 0);
    std::vector<bool> use_phys(S);
    for (unsigned k = 0; k < S; k++) use_phys[k] = phys || (first + k >= first_direct);
    for (unsigned k = 0; k < S; k++) {
        const unsigned i = first + k;
        bool huge = false;
        // the driver keeps one card address per 4 KiB page, also for huge-page buffers
        std::vector<uint64_t> pg = t.getCardPaddr(regions[k], huge, (region + 4095) / 4096);
        const uint64_t pgsz = 4096ull;
        if (pg.empty() || pg.size() * pgsz < region) { std::cerr << "stream " << i << ": only " << pg.size() << " pages mapped" << std::endl; return 4; }
        if (windows && (pg[0] >> 30) != i / group + 1) {
            std::cerr << "stream " << i << ": region placed in card window " << (pg[0] >> 30) << ", expected " << i / group + 1
                      << " (host library before b6966163 or driver before 3b34e8b1?)" << std::endl;
            return 4;
        }
        if (use_phys[k]) {
            for (size_t j = 1; j < pg.size(); j++) {
                if (pg[j] != pg[0] + j * pgsz) {
                    std::cerr << "stream " << i << ": region not physically contiguous at page " << j
                              << " (" << std::hex << pg[j] << " vs " << pg[0] + j * pgsz << std::dec << "); use a smaller --region" << std::endl;
                    return 4;
                }
            }
            bases[k] = pg[0];
        }
        std::cout << "stream " << i << (i >= first_direct ? " (direct)" : " (Coyote)") << ": card paddr 0x" << std::hex << pg[0] << std::dec
                  << " (window " << (pg[0] >> 30) << "), " << pg.size() << " x 4 KiB pages" << (huge ? " (huge-page buffer)" : "")
                  << (use_phys[k] ? ", contiguous" : "") << std::endl;
    }

    // expected per-stream, per-lane sums of 64-bit words (the vFPGA's data check), for one run
    std::vector<std::array<uint64_t, 8>> expect(S);
    for (unsigned k = 0; k < S; k++) {
        expect[k].fill(0);
        const uint64_t *w = reinterpret_cast<const uint64_t*>(regions[k]);
        for (unsigned r = 0; r < reps; r++) {
            const uint64_t off = advance ? static_cast<uint64_t>(r) * len : 0;
            const uint64_t nbytes = ((len + 63) / 64) * 64;      // the stream delivers whole beats
            for (uint64_t b = off; b < off + nbytes && b < region; b += 8) expect[k][(b / 8) % 8] += w[b / 8];
        }
    }

    uint64_t mask = 0;
    for (unsigned k = 0; k < S; k++) mask |= 1ull << (first + k);

    unsigned total_bad = 0;
    for (unsigned run = 0; run < n_runs; run++) {
        for (unsigned k = 0; k < S; k++) {               // per-stream base: SEL then VADDR
            t.setCSR(first + k, R_SEL);
            t.setCSR(use_phys[k] ? bases[k] : reinterpret_cast<uint64_t>(regions[k]), R_VADDR);
        }
        t.setCSR(0, R_STRIDE);
        t.setCSR(len, R_LEN);
        t.setCSR(reps, R_N_REPS);
        t.setCSR(beats_per_stream, R_N_BEATS);
        t.setCSR(static_cast<uint64_t>(t.getCtid()), R_PID);
        t.setCSR(mask, R_MASK);
        g_started = true;
        t.setCSR(1ull | (advance ? 2ull : 0ull) | (phys ? 4ull : 0ull), R_CTRL);
        auto t0 = std::chrono::steady_clock::now();
        while (!(t.getCSR(R_STATUS) & 1ull)) {
            if (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() > 30.0) {
                // two snapshots 3 s apart separate a stall (nothing moves) from slow progress (box report 10/20 21:00)
                std::vector<uint64_t> b1(S), b2(S);
                std::cerr << "timeout; per-stream state:" << std::endl;
                for (unsigned k = 0; k < S; k++) {
                    t.setCSR(first + k, R_SEL);
                    b1[k] = t.getCSR(R_BEATS_SEL);
                    std::cerr << "  stream " << first + k << " issued " << t.getCSR(R_ISSUED_SEL) << " beats " << b1[k]
                              << " of " << beats_per_stream << std::endl;
                }
                std::this_thread::sleep_for(std::chrono::seconds(3));
                bool moved = false;
                std::cerr << "3 s later:" << std::endl;
                for (unsigned k = 0; k < S; k++) {
                    t.setCSR(first + k, R_SEL);
                    b2[k] = t.getCSR(R_BEATS_SEL);
                    if (b2[k] != b1[k]) moved = true;
                    std::cerr << "  stream " << first + k << " beats " << b2[k] << (b2[k] != b1[k] ? " (moving)" : " (no change)") << std::endl;
                }
                std::cerr << (moved ? "verdict: progressing slowly" : "verdict: STALLED (no stream moved in 3 s)") << std::endl;
                std::cerr << "The probe has no abort and stays busy now: reprogram the full image over JTAG and warm reboot "
                             "before the next run." << std::endl;
                return 3;
            }
        }
        const double cyc = static_cast<double>(t.getCSR(R_TIMER));
        const double sec = cyc / (aclk_mhz * 1e6);
        const double bytes = static_cast<double>(S) * beats_per_stream * 64.0;
        std::cout << "run " << run << ": " << std::fixed << std::setprecision(3) << sec * 1e3 << " ms, aggregate "
                  << bytes / sec / 1e9 << " GB/s, first beat after " << t.getCSR(R_T_FIRST) / aclk_mhz << " us; per stream:";
        for (unsigned k = 0; k < S; k++) {
            t.setCSR(first + k, R_SEL);
            const double t_last = static_cast<double>(t.getCSR(R_T_LAST_SEL)) / (aclk_mhz * 1e6);
            std::cout << " " << std::setprecision(2) << (beats_per_stream * 64.0) / t_last / 1e9;
        }
        std::cout << " GB/s" << std::endl;
        if (!datacheck) continue;
        unsigned bad = 0;
        for (unsigned k = 0; k < S; k++) {
            t.setCSR(first + k, R_SEL);
            for (unsigned j = 0; j < 8; j++) {
                t.setCSR(j, R_LANE);
                const uint64_t got = t.getCSR(R_CSUM_SEL);
                if (got != expect[k][j]) {
                    if (bad < 8) std::cerr << "  DATA MISMATCH stream " << first + k << " lane " << j << ": got 0x" << std::hex << got
                                           << " expected 0x" << expect[k][j] << std::dec << std::endl;
                    bad++;
                }
            }
        }
        std::cout << "  data check: " << (bad ? "FAIL" : "all streams match") << " (" << S * 8 << " lane sums, " << bad << " wrong)" << std::endl;
        total_bad += bad;
    }
    return total_bad ? 5 : 0;
}

int main(int argc, char *argv[]) {
    // Library errors (allocation, ioctl, transfer limits) throw; report them with a defined exit code instead of an
    // abort with a core dump (box report 10/20 20:50).
    try {
        return run(argc, argv);
    } catch (const std::exception &e) {
        std::cerr << "host library error " << (g_started ? "after a probe run was started (reprogram over JTAG and warm reboot "
                     "before the next run)" : "before any probe run was started (the board is untouched)") << ": " << e.what() << std::endl;
        return 7;
    }
}
