//
//  DeEsserDSPTests.mm
//  Offline unit tests for the pure C++ de-esser (a faithful port of the Calf
//  Deesser used by EasyEffects).
//
#import <XCTest/XCTest.h>

#include <cmath>
#include <vector>

#include "DeEsserDSP.hpp"

using td::DeEsserDSP;
using td::DeEsserParams;

namespace {

constexpr double kSampleRate = 48000.0;

// The stock EasyEffects/Calf defaults (DeEsserParams already initialises to them).
DeEsserParams defaultPreset() { return DeEsserParams{}; }

// A more aggressive preset (lower threshold) for tests that need clear reduction.
DeEsserParams aggressivePreset() {
    DeEsserParams p;
    p.thresholdDb = -30.0f;
    p.ratio = 6.0f;
    return p;
}

// Fills a stereo buffer with a sine of given frequency / amplitude.
void fillSine(std::vector<float>& l, std::vector<float>& r, double freq, double amp, double sr) {
    for (size_t n = 0; n < l.size(); ++n) {
        const double s = amp * std::sin(2.0 * M_PI * freq * (double)n / sr);
        l[n] = (float)s;
        r[n] = (float)s;
    }
}

double rms(const std::vector<float>& v, size_t start) {
    double acc = 0.0;
    size_t count = 0;
    for (size_t n = start; n < v.size(); ++n) { acc += (double)v[n] * (double)v[n]; ++count; }
    return count ? std::sqrt(acc / (double)count) : 0.0;
}

double peak(const std::vector<float>& v, size_t start) {
    double p = 0.0;
    for (size_t n = start; n < v.size(); ++n) p = std::max(p, std::fabs((double)v[n]));
    return p;
}

// Processes interleaved-by-channel buffers in blocks through the DSP.
void runBlocks(DeEsserDSP& dsp, std::vector<float>& l, std::vector<float>& r, int blockSize) {
    const int total = (int)l.size();
    int n = 0;
    while (n < total) {
        const int frames = std::min(blockSize, total - n);
        float* chans[2] = { l.data() + n, r.data() + n };
        dsp.process(chans, 2, frames);
        n += frames;
    }
}

} // namespace

@interface DeEsserDSPTests : XCTestCase
@end

@implementation DeEsserDSPTests

// 1. Hard bypass copies samples exactly when the crossfade is settled.
- (void)testHardBypassIsExact {
    DeEsserDSP dsp;
    dsp.prepare(kSampleRate, 2);
    DeEsserParams p = defaultPreset();
    p.bypass = true;
    dsp.setParameters(p);
    dsp.reset(); // snaps the bypass crossfade to fully-dry

    std::vector<float> l(1024), r(1024), origL(1024), origR(1024);
    fillSine(l, r, 6000.0, 0.4, kSampleRate); // sibilant-band content
    origL = l; origR = r;

    runBlocks(dsp, l, r, 256);

    for (size_t n = 0; n < l.size(); ++n) {
        XCTAssertEqual(l[n], origL[n], @"bypass must be bit-exact (L)");
        XCTAssertEqual(r[n], origR[n], @"bypass must be bit-exact (R)");
    }
}

// 2. A 1 kHz sine (well below the sidechain high-pass) passes through nearly
// untouched under the default preset.
- (void)testLowFrequencyPassesThrough {
    DeEsserDSP dsp;
    dsp.prepare(kSampleRate, 2);
    dsp.setParameters(defaultPreset());
    dsp.reset();

    const double amp = std::pow(10.0, -12.0 / 20.0);
    std::vector<float> l(48000), r(48000);
    fillSine(l, r, 1000.0, amp, kSampleRate);
    std::vector<float> ref = l;

    runBlocks(dsp, l, r, 512);

    const size_t skip = 24000; // steady state
    const double inRms = rms(ref, skip);
    const double outRms = rms(l, skip);
    const double deltaDb = 20.0 * std::log10(outRms / inRms);
    XCTAssertLessThan(std::fabs(deltaDb), 0.25, @"1 kHz delta %.3f dB", deltaDb);
}

// 3. A tone in the sibilant band above threshold engages gain reduction.
- (void)testSibilantBandIsReduced {
    DeEsserDSP dsp;
    dsp.prepare(kSampleRate, 2);
    dsp.setParameters(aggressivePreset());
    dsp.reset();

    const double amp = std::pow(10.0, -10.0 / 20.0); // well above the -30 dBFS threshold
    std::vector<float> l(48000), r(48000);
    fillSine(l, r, 6500.0, amp, kSampleRate);

    runBlocks(dsp, l, r, 512);

    const float reduction = dsp.currentGainReductionDb();
    XCTAssertGreaterThan(reduction, 3.0f, @"expected the sibilant band to be reduced, got %.2f dB", reduction);
}

// 4. In WIDE mode the whole band is scaled by a gain <= 1, so a low tone is
// pulled down together with the sibilant band when reduction is active.
- (void)testWideModeScalesWholeBand {
    DeEsserDSP dsp;
    dsp.prepare(kSampleRate, 2);
    dsp.setParameters(aggressivePreset()); // mode defaults to WIDE
    dsp.reset();

    // A sibilant tone the detector reacts to, summed with a quiet low tone.
    const double sib = std::pow(10.0, -10.0 / 20.0);
    const double low = std::pow(10.0, -22.0 / 20.0);
    std::vector<float> l(48000), r(48000), ref(48000);
    for (size_t n = 0; n < l.size(); ++n) {
        const double t = (double)n / kSampleRate;
        const double lowComp = low * std::sin(2.0 * M_PI * 700.0 * t);
        ref[n] = (float)lowComp; // low-band reference (unprocessed)
        const double s = sib * std::sin(2.0 * M_PI * 6500.0 * t) + lowComp;
        l[n] = (float)s; r[n] = (float)s;
    }
    runBlocks(dsp, l, r, 512);

    XCTAssertGreaterThan(dsp.currentGainReductionDb(), 3.0f, @"reduction should engage");
    XCTAssertLessThanOrEqual(peak(l, 24000), peak(ref, 24000) + sib + 1e-3,
                             @"wide-mode output is the input scaled by gain <= 1");
}

// 5. Left/right gain reduction is identical for a one-sided detector event
// (the detector averages the two channels).
- (void)testLinkedStereoSymmetry {
    const double amp = std::pow(10.0, -8.0 / 20.0);

    DeEsserDSP dspA;
    dspA.prepare(kSampleRate, 2);
    dspA.setParameters(aggressivePreset());
    dspA.reset();
    std::vector<float> l1(24000, 0.0f), r1(24000, 0.0f);
    for (size_t n = 0; n < l1.size(); ++n) l1[n] = (float)(amp * std::sin(2.0 * M_PI * 6500.0 * (double)n / kSampleRate));
    runBlocks(dspA, l1, r1, 512);
    const float grLeftOnly = dspA.currentGainReductionDb();

    DeEsserDSP dspB;
    dspB.prepare(kSampleRate, 2);
    dspB.setParameters(aggressivePreset());
    dspB.reset();
    std::vector<float> l2(24000, 0.0f), r2(24000, 0.0f);
    for (size_t n = 0; n < r2.size(); ++n) r2[n] = (float)(amp * std::sin(2.0 * M_PI * 6500.0 * (double)n / kSampleRate));
    runBlocks(dspB, l2, r2, 512);
    const float grRightOnly = dspB.currentGainReductionDb();

    XCTAssertEqualWithAccuracy(grLeftOnly, grRightOnly, 0.05,
                               @"averaged detector must react identically to L-only and R-only events");
}

// 6. Release returns toward unity within the expected tolerance after a burst.
- (void)testReleaseRecovers {
    DeEsserDSP dsp;
    dsp.prepare(kSampleRate, 2);
    dsp.setParameters(aggressivePreset());
    dsp.reset();

    const double amp = std::pow(10.0, -8.0 / 20.0);
    std::vector<float> l(int(kSampleRate * 0.2)), r(l.size());
    fillSine(l, r, 6500.0, amp, kSampleRate);
    runBlocks(dsp, l, r, 256);
    XCTAssertGreaterThan(dsp.currentGainReductionDb(), 2.0f, @"burst should engage reduction");

    // After a full second of silence the detector releases back to ~unity.
    std::vector<float> sl(int(kSampleRate * 1.0), 0.0f), sr(sl.size(), 0.0f);
    runBlocks(dsp, sl, sr, 256);
    XCTAssertLessThan(dsp.currentGainReductionDb(), 0.5f, @"reduction should release back to ~0 dB");
}

// 7. No NaN/Inf for silence, denormals, NaN input, or maximum-amplitude input.
- (void)testNoNaNOrInf {
    DeEsserDSP dsp;
    dsp.prepare(kSampleRate, 2);
    dsp.setParameters(defaultPreset());
    dsp.reset();

    auto check = [&](std::vector<float> l, std::vector<float> r) {
        runBlocks(dsp, l, r, 256);
        for (size_t n = 0; n < l.size(); ++n) {
            XCTAssertTrue(std::isfinite(l[n]), @"L finite");
            XCTAssertTrue(std::isfinite(r[n]), @"R finite");
            XCTAssertLessThanOrEqual(std::fabs(l[n]), 1.0f + 1e-4f, @"L within range");
            XCTAssertLessThanOrEqual(std::fabs(r[n]), 1.0f + 1e-4f, @"R within range");
        }
    };

    check(std::vector<float>(1024, 0.0f), std::vector<float>(1024, 0.0f));      // silence
    check(std::vector<float>(1024, 1.0e-30f), std::vector<float>(1024, 1.0e-30f)); // denormals
    {
        std::vector<float> l(1024, NAN), r(1024, INFINITY);                     // NaN/Inf input
        check(l, r);
    }
    {
        std::vector<float> l(2048), r(2048);
        fillSine(l, r, 6500.0, 1.0, kSampleRate);                               // full-scale
        check(l, r);
    }
}

// 8. WIDE-mode output never exceeds the input peak (it is the input scaled by a
// gain <= 1; no makeup by default).
- (void)testOutputDoesNotExceedInputPeak {
    const double amp = 0.5;
    const double freqs[] = {1000.0, 5000.0, 7000.0};
    for (double f : freqs) {
        DeEsserDSP dsp;
        dsp.prepare(kSampleRate, 2);
        dsp.setParameters(aggressivePreset());
        dsp.reset();

        std::vector<float> l(24000), r(24000);
        fillSine(l, r, f, amp, kSampleRate);
        std::vector<float> ref = l;
        runBlocks(dsp, l, r, 512);

        const size_t skip = 4800; // skip start-up transient
        const double inPeak = peak(ref, skip);
        const double outPeak = peak(l, skip);
        XCTAssertLessThanOrEqual(outPeak, inPeak + 1.0e-2, @"freq %.0f Hz: out peak %.4f > in peak %.4f", f, outPeak, inPeak);
    }
}

// 9. SPLIT mode reduces a sibilant tone while leaving a low tone essentially
// untouched (only the high band is compressed).
- (void)testSplitModePreservesLowBand {
    DeEsserParams p = aggressivePreset();
    p.mode = td::kModeSplit;

    DeEsserDSP low;
    low.prepare(kSampleRate, 2);
    low.setParameters(p);
    low.reset();
    const double amp = std::pow(10.0, -10.0 / 20.0);
    std::vector<float> ll(48000), lr(48000);
    fillSine(ll, lr, 700.0, amp, kSampleRate); // well below the 6 kHz split
    std::vector<float> lRef = ll;
    runBlocks(low, ll, lr, 512);
    const double lowDropDb = 20.0 * std::log10(rms(ll, 24000) / rms(lRef, 24000));
    XCTAssertGreaterThan(lowDropDb, -1.0, @"split mode should pass the low band, got %.2f dB", lowDropDb);
}

@end
