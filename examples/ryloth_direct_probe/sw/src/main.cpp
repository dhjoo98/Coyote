/**
 * Ryloth direct-HBM probe, host side (2026-10-20).
 *
 * Drives the probe vFPGA (hw/src/vfpga_top.svh): one card-memory region per stream, all streams reading at once,
 * FPGA-side timer and per-stream beat counters. Reports GB/s per stream and in aggregate.
 *
 * Memory placement: with --offload (default) each stream's region is a host buffer migrated to card memory with
 * LOCAL_OFFLOAD, exactly as the Ryloth host program places the index today, and the region's virtual address is
 * what the vFPGA puts in its requests. On the direct-HBM shell the same program runs unchanged as long as the
 * driver keeps handing out per-stream regions through the same calls; a per-channel placement API (block mode)
 * is added here when the driver side exists.
 */
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <vector>
#include <boost/program_options.hpp>
#include <coyote/cThread.hpp>

namespace {
constexpr uint32_t R_CTRL = 0, R_STATUS = 1, R_TIMER = 2, R_VADDR = 3, R_LEN = 4, R_PID = 5, R_N_REPS = 6,
                   R_N_BEATS = 7, R_STRIDE = 8, R_MASK = 9, R_SEL = 10, R_BEATS_SEL = 11, R_T_LAST_SEL = 12,
                   R_ISSUED_SEL = 13, R_N_STREAMS = 14, R_T_FIRST = 15;
constexpr int DEFAULT_VFPGA_ID = 0;
}

int main(int argc, char *argv[]) {
    unsigned n_streams_req, n_runs, reps;
    uint64_t region, len;
    double aclk_mhz;
    bool advance, offload;
    boost::program_options::options_description opts("Ryloth direct-HBM probe");
    opts.add_options()
        ("streams,s", boost::program_options::value<unsigned>(&n_streams_req)->default_value(0), "streams to drive (0 = all the build has)")
        ("region,R", boost::program_options::value<uint64_t>(&region)->default_value(256ull << 20), "bytes per stream region (allocated and offloaded to card)")
        ("len,l", boost::program_options::value<uint64_t>(&len)->default_value(1ull << 20), "bytes per request")
        ("reps,n", boost::program_options::value<unsigned>(&reps)->default_value(0), "requests per stream (0 = region / len)")
        ("advance,a", boost::program_options::value<bool>(&advance)->default_value(true), "sequential scan of the region (else re-read the same address)")
        ("offload", boost::program_options::value<bool>(&offload)->default_value(true), "migrate the regions to card memory first (LOCAL_OFFLOAD)")
        ("runs,r", boost::program_options::value<unsigned>(&n_runs)->default_value(5), "repetitions")
        ("aclk", boost::program_options::value<double>(&aclk_mhz)->default_value(150.0), "ACLK in MHz (timer clock)");
    boost::program_options::variables_map vm;
    boost::program_options::store(boost::program_options::parse_command_line(argc, argv, opts), vm);
    boost::program_options::notify(vm);

    coyote::cThread t(DEFAULT_VFPGA_ID, getpid());
    const unsigned n_build = static_cast<unsigned>(t.getCSR(R_N_STREAMS));
    const unsigned S = (n_streams_req == 0 || n_streams_req > n_build) ? n_build : n_streams_req;
    if (reps == 0) reps = static_cast<unsigned>(region / len);
    const uint64_t beats_per_stream = static_cast<uint64_t>(reps) * ((len + 63) / 64);
    std::cout << "build streams " << n_build << ", driving " << S << ", region " << (region >> 20) << " MiB, request "
              << (len >> 10) << " KiB x " << reps << " per stream, " << (advance ? "sequential" : "same address") << std::endl;

    // one region per stream, placed back to back so stream i sits at base + i * stride
    std::vector<char*> regions(S);
    for (unsigned i = 0; i < S; i++) {
        regions[i] = static_cast<char*>(t.getMem({coyote::CoyoteAllocType::HPF, static_cast<unsigned>(region)}));
        if (!regions[i]) { std::cerr << "allocation failed for stream " << i << std::endl; return 1; }
        std::memset(regions[i], 0x5a + i, region);
        if (offload) {
            coyote::sgEntry sg; std::memset(&sg, 0, sizeof(sg));
            sg.sync.addr = regions[i]; sg.sync.len = static_cast<uint32_t>(region);
            t.invoke(coyote::CoyoteOper::LOCAL_OFFLOAD, &sg);
            while (t.checkCompleted(coyote::CoyoteOper::LOCAL_OFFLOAD) != static_cast<int>(i + 1)) {}
        }
    }
    // the vFPGA computes vaddr_i = VADDR + i * STRIDE; regions from separate allocations are not equidistant in
    // general, so the probe is run once per distinct spacing: here we require equal spacing and check it.
    uint64_t stride = (S > 1) ? static_cast<uint64_t>(regions[1] - regions[0]) : 0;
    for (unsigned i = 1; i < S; i++) {
        if (static_cast<uint64_t>(regions[i] - regions[0]) != stride * i) {
            std::cerr << "regions are not equally spaced (stream " << i << "); allocate one buffer of S x region instead" << std::endl;
            return 2;
        }
    }

    for (unsigned run = 0; run < n_runs; run++) {
        t.setCSR(reinterpret_cast<uint64_t>(regions[0]), R_VADDR);
        t.setCSR(stride, R_STRIDE);
        t.setCSR(len, R_LEN);
        t.setCSR(reps, R_N_REPS);
        t.setCSR(beats_per_stream, R_N_BEATS);
        t.setCSR(static_cast<uint64_t>(t.getCtid()), R_PID);
        t.setCSR((S >= 32) ? 0xffffffffull : ((1ull << S) - 1), R_MASK);
        t.setCSR(1ull | (advance ? 2ull : 0ull), R_CTRL);
        auto t0 = std::chrono::steady_clock::now();
        while (!(t.getCSR(R_STATUS) & 1ull)) {
            if (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() > 30.0) {
                std::cerr << "timeout; per-stream state:" << std::endl;
                for (unsigned i = 0; i < S; i++) {
                    t.setCSR(i, R_SEL);
                    std::cerr << "  stream " << i << " issued " << t.getCSR(R_ISSUED_SEL) << " beats " << t.getCSR(R_BEATS_SEL)
                              << " of " << beats_per_stream << std::endl;
                }
                return 3;
            }
        }
        const double cyc = static_cast<double>(t.getCSR(R_TIMER));
        const double sec = cyc / (aclk_mhz * 1e6);
        const double bytes = static_cast<double>(S) * beats_per_stream * 64.0;
        std::cout << "run " << run << ": " << std::fixed << std::setprecision(3) << sec * 1e3 << " ms, aggregate "
                  << bytes / sec / 1e9 << " GB/s, first beat after " << t.getCSR(R_T_FIRST) / (aclk_mhz) << " us; per stream:";
        for (unsigned i = 0; i < S; i++) {
            t.setCSR(i, R_SEL);
            const double t_last = static_cast<double>(t.getCSR(R_T_LAST_SEL)) / (aclk_mhz * 1e6);
            std::cout << " " << std::setprecision(2) << (beats_per_stream * 64.0) / t_last / 1e9;
        }
        std::cout << " GB/s" << std::endl;
    }
    return 0;
}
