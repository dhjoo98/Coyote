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
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <utility>
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
    unsigned n_streams_req, n_runs, reps, first;
    uint64_t region, len;
    double aclk_mhz;
    bool advance, windows, phys;
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
        ("phys,p", boost::program_options::value<bool>(&phys)->default_value(false), "stage 2: issue physical card reads (TLB bypass); needs the direct-HBM driver and a stage-2 shell")
        ("runs,r", boost::program_options::value<unsigned>(&n_runs)->default_value(5), "repetitions")
        ("aclk", boost::program_options::value<double>(&aclk_mhz)->default_value(150.0), "ACLK in MHz (timer clock)");
    boost::program_options::variables_map vm;
    boost::program_options::store(boost::program_options::parse_command_line(argc, argv, opts), vm);
    boost::program_options::notify(vm);
    if (vm.count("help")) { std::cout << opts << std::endl; return 0; }

    coyote::cThread t(DEFAULT_VFPGA_ID, getpid());
    const unsigned n_build = static_cast<unsigned>(t.getCSR(R_N_STREAMS));
    if (first >= n_build) { std::cerr << "first stream " << first << " >= build streams " << n_build << std::endl; return 1; }
    unsigned S = (n_streams_req == 0) ? n_build - first : n_streams_req;
    if (first + S > n_build) S = n_build - first;
    if (reps == 0) reps = static_cast<unsigned>(region / len);
    const uint64_t beats_per_stream = static_cast<uint64_t>(reps) * ((len + 63) / 64);
    std::cout << "build streams " << n_build << ", driving " << S << " (from " << first << "), region " << (region >> 20)
              << " MiB, request " << (len >> 10) << " KiB x " << reps << " per stream, " << (advance ? "sequential" : "same address")
              << ", placement " << (windows ? "window i+1" : "first-free") << std::endl;

    // one region per driven stream, migrated to the card
    std::vector<char*> regions(S);
    for (unsigned k = 0; k < S; k++) {
        const unsigned i = first + k;
        coyote::CoyoteAlloc a;
        a.alloc = coyote::CoyoteAllocType::HPF;
        a.size = static_cast<uint32_t>(region);
        a.mem_block = windows ? static_cast<int32_t>(i + 1) : -1;
        regions[k] = static_cast<char*>(t.getMem(std::move(a)));
        if (!regions[k]) { std::cerr << "allocation failed for stream " << i << std::endl; return 1; }
        std::memset(regions[k], 0x5a + i, region);
        coyote::syncSg sg = {.addr = regions[k], .len = region};
        t.invoke(coyote::CoyoteOper::LOCAL_OFFLOAD, sg);     // blocking: the driver migrates the pages to the card
    }

    // stage 2: the vFPGA reads physical window offsets; each region must be physically contiguous on the card
    std::vector<uint64_t> bases(S, 0);
    if (phys) {
        for (unsigned k = 0; k < S; k++) {
            bool huge = false;
            std::vector<uint64_t> pg = t.getCardPaddr(regions[k], huge);
            const uint64_t pgsz = huge ? (2ull << 20) : 4096ull;
            if (pg.empty()) { std::cerr << "stream " << first + k << ": no card pages" << std::endl; return 4; }
            for (size_t j = 1; j < pg.size(); j++) {
                if (pg[j] != pg[0] + j * pgsz) {
                    std::cerr << "stream " << first + k << ": region not physically contiguous at page " << j
                              << " (" << std::hex << pg[j] << " vs " << pg[0] + j * pgsz << std::dec << "); use a smaller --region" << std::endl;
                    return 4;
                }
            }
            bases[k] = pg[0];
            std::cout << "stream " << first + k << ": card paddr 0x" << std::hex << pg[0] << std::dec << " (window " << (pg[0] >> 30) << "), "
                      << pg.size() << (huge ? " huge" : " regular") << " pages" << std::endl;
        }
    }

    uint64_t mask = 0;
    for (unsigned k = 0; k < S; k++) mask |= 1ull << (first + k);

    for (unsigned run = 0; run < n_runs; run++) {
        for (unsigned k = 0; k < S; k++) {               // per-stream base: SEL then VADDR
            t.setCSR(first + k, R_SEL);
            t.setCSR(phys ? bases[k] : reinterpret_cast<uint64_t>(regions[k]), R_VADDR);
        }
        t.setCSR(0, R_STRIDE);
        t.setCSR(len, R_LEN);
        t.setCSR(reps, R_N_REPS);
        t.setCSR(beats_per_stream, R_N_BEATS);
        t.setCSR(static_cast<uint64_t>(t.getCtid()), R_PID);
        t.setCSR(mask, R_MASK);
        t.setCSR(1ull | (advance ? 2ull : 0ull) | (phys ? 4ull : 0ull), R_CTRL);
        auto t0 = std::chrono::steady_clock::now();
        while (!(t.getCSR(R_STATUS) & 1ull)) {
            if (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() > 30.0) {
                std::cerr << "timeout; per-stream state:" << std::endl;
                for (unsigned k = 0; k < S; k++) {
                    t.setCSR(first + k, R_SEL);
                    std::cerr << "  stream " << first + k << " issued " << t.getCSR(R_ISSUED_SEL) << " beats " << t.getCSR(R_BEATS_SEL)
                              << " of " << beats_per_stream << std::endl;
                }
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
    }
    return 0;
}
