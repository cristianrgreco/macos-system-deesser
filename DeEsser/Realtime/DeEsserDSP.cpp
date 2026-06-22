//
//  DeEsserDSP.cpp
//  De-Esser
//
//  Faithful port of calf-studio-gear/calf deesser_audio_module +
//  gain_reduction_audio_module (the de-esser EasyEffects uses).
//
#include "DeEsserDSP.hpp"

#include <algorithm>
#include <cmath>

namespace td {

namespace {
constexpr float kLn10Over20 = 0.11512925464970228f; // ln(10)/20

/// Calf's cubic Hermite interpolation (src/calf/primitives.h), used to round the
/// compressor's soft knee.
inline float hermite_interpolation(float x, float x0, float x1,
                                   float p0, float p1, float m0, float m1) noexcept {
    float width = x1 - x0;
    float t = (x - x0) / width;
    m0 *= width;
    m1 *= width;
    float t2 = t * t;
    float t3 = t2 * t;

    float ct0 = p0;
    float ct1 = m0;
    float ct2 = -3 * p0 - 2 * m0 + 3 * p1 - m1;
    float ct3 = 2 * p0 + m0 - 2 * p1 + m1;

    return ct3 * t3 + ct2 * t2 + ct1 * t + ct0;
}
} // namespace

DeEsserDSP::DeEsserDSP() {
    // Default coefficient sets are designed in prepare(); start primed.
}

float DeEsserDSP::dbToLinear(float db) noexcept {
    return std::exp(db * kLn10Over20);
}

float DeEsserDSP::sanitize(float x) noexcept {
    return std::isfinite(x) ? x : 0.0f;
}

void DeEsserDSP::prepare(double sampleRate, int channelCount) {
    sampleRate_ = sampleRate > 0.0 ? sampleRate : 48000.0;
    channelCount_ = std::clamp(channelCount, 1, kMaxChannels);

    DeEsserParams defaults; // EasyEffects/Calf default preset
    // Populate both slots so either active index is valid before first update.
    setParameters(defaults);
    coeffSets_[1 - activeIndex_.load(std::memory_order_relaxed)] =
        coeffSets_[activeIndex_.load(std::memory_order_relaxed)];

    reset();
}

void DeEsserDSP::reset() {
    for (int c = 0; c < kMaxChannels; ++c) {
        channels_[c].hp.reset();
        channels_[c].lp.reset();
        channels_[c].peak.reset();
    }
    linSlope_ = 0.0f;

    const CoeffSet& cs = coeffSets_[activeIndex_.load(std::memory_order_relaxed)];
    bypassMix_ = cs.bypassTarget;

    gainReductionMeterDb_.store(0.0f, std::memory_order_relaxed);
    inputPeakMeter_.store(0.0f, std::memory_order_relaxed);
}

void DeEsserDSP::setParameters(const DeEsserParams& p) {
    const int inactive = 1 - activeIndex_.load(std::memory_order_acquire);
    CoeffSet& cs = coeffSets_[inactive];

    // --- Filters (Calf deesser_audio_module::params_changed) ---
    // The sidechain is peak(hp(x)); the split low band is lp(x). The high-pass
    // and low-pass are offset by ±17 % around f1 to form the crossover, and the
    // peaking EQ boosts the sibilance band so the detector reacts to it.
    const double q = 0.707;
    cs.hp.set_hp_rbj((double)p.f1FreqHz * (1.0 - 0.17), q, sampleRate_, dbToLinear(p.f1LevelDb));
    cs.lp.set_lp_rbj((double)p.f1FreqHz * (1.0 + 0.17), q, sampleRate_);
    cs.peak.set_peakeq_rbj((double)p.f2FreqHz, std::max(0.1f, p.f2Q), dbToLinear(p.f2LevelDb), sampleRate_);

    // --- Compressor (Calf gain_reduction set_params), as the deesser calls it:
    //   set_params(laxity, laxity * 1.33, threshold, ratio, 2.8, makeup,
    //              detection, 0 /*stereo-link average*/, bypass, 0) ---
    const float attack = std::max(1.0f, p.laxity);
    const float release = attack * 1.33f;
    cs.attackCoeff = std::min(1.0f, 1.0f / (attack * static_cast<float>(sampleRate_) / 4000.0f));
    cs.releaseCoeff = std::min(1.0f, 1.0f / (release * static_cast<float>(sampleRate_) / 4000.0f));
    cs.makeupLin = dbToLinear(p.makeupDb);
    cs.ratio = std::max(1.0f, p.ratio);
    cs.knee = 2.8f; // Calf fixes the deesser knee at 2.8
    cs.rms = (p.detection == kDetectionRMS);
    cs.mode = p.mode;
    cs.scListen = p.scListen;
    cs.bypassTarget = p.bypass ? 1.0f : 0.0f;

    // --- Gain computer curve (Calf gain_reduction::update_curve) ---
    const float linThreshold = dbToLinear(p.thresholdDb);
    const float linKneeSqrt = std::sqrt(cs.knee);
    cs.linKneeStart = linThreshold / linKneeSqrt;
    cs.adjKneeStart = cs.linKneeStart * cs.linKneeStart;
    const float linKneeStop = linThreshold * linKneeSqrt;
    cs.thres = std::log(linThreshold);
    cs.kneeStart = std::log(cs.linKneeStart);
    cs.kneeStop = std::log(linKneeStop);
    cs.compressedKneeStop = (cs.kneeStop - cs.thres) / cs.ratio + cs.thres;

    // Publish the new set atomically at a block boundary.
    activeIndex_.store(inactive, std::memory_order_release);
}

float DeEsserDSP::outputGain(float linSlope, bool rms, const CoeffSet& cs) const noexcept {
    // Thor's compressor gain computer (Calf gain_reduction::output_gain).
    if (linSlope > (rms ? cs.adjKneeStart : cs.linKneeStart)) {
        float slope = std::log(linSlope);
        if (rms) slope *= 0.5f;

        float gain = 0.f;
        float delta = 0.f;
        // The deesser ratio is bounded well below Calf's "fake infinity"; the
        // branch is kept for fidelity but the else path always runs here.
        if (cs.ratio >= 32768.0f) {
            gain = cs.thres;
            delta = 0.f;
        } else {
            gain = (slope - cs.thres) / cs.ratio + cs.thres;
            delta = 1.f / cs.ratio;
        }

        if (cs.knee > 1.f && slope < cs.kneeStop) {
            gain = hermite_interpolation(slope, cs.kneeStart, cs.kneeStop,
                                         cs.kneeStart, cs.compressedKneeStop, 1.f, delta);
        }

        return std::exp(gain - slope);
    }
    return 1.f;
}

void DeEsserDSP::process(float* const* channels, int channelCount, int frameCount) noexcept {
    if (channels == nullptr || frameCount <= 0) return;
    const int chCount = std::clamp(channelCount, 1, kMaxChannels);
    const bool stereo = (chCount >= 2);

    const int idx = activeIndex_.load(std::memory_order_acquire);
    const CoeffSet& cs = coeffSets_[idx];

    // Publish the active coefficients into the per-channel filter state once per
    // block; w1/w2 persist (mirrors Calf's params_changed + copy_coeffs).
    for (int c = 0; c < chCount; ++c) {
        channels_[c].hp.copy_coeffs(cs.hp);
        channels_[c].lp.copy_coeffs(cs.lp);
        channels_[c].peak.copy_coeffs(cs.peak);
    }

    Biquad& hpL = channels_[0].hp;
    Biquad& lpL = channels_[0].lp;
    Biquad& peakL = channels_[0].peak;
    const int rc = stereo ? 1 : 0;
    Biquad& hpR = channels_[rc].hp;
    Biquad& lpR = channels_[rc].lp;
    Biquad& peakR = channels_[rc].peak;

    const float bypassStep = 1.0f / static_cast<float>(0.010 * sampleRate_); // 10 ms crossfade
    const float bypassTarget = cs.bypassTarget;
    const float makeup = cs.makeupLin;
    const bool rms = cs.rms;
    const float attackCoeff = cs.attackCoeff;
    const float releaseCoeff = cs.releaseCoeff;

    // Compressor inner loop (Calf gain_reduction::process). Multiplies the audio
    // pair in place by the computed gain and returns that gain (the comp meter).
    auto compress = [&](float& left, float& right, float detL, float detR) -> float {
        // stereo_link == 0 → average detection.
        float absample = (std::fabs(detL) + std::fabs(detR)) * 0.5f;
        if (rms) absample *= absample;
        linSlope_ = sanitize(linSlope_);
        linSlope_ += (absample - linSlope_) * (absample > linSlope_ ? attackCoeff : releaseCoeff);
        float g = 1.0f;
        if (linSlope_ > 0.0f) g = outputGain(linSlope_, rms, cs);
        left *= g * makeup;
        right *= g * makeup;
        return g;
    };

    auto guard = [](float v) -> float {
        if (!std::isfinite(v)) return 0.0f;
        if (v > 1.0f) return 1.0f;
        if (v < -1.0f) return -1.0f;
        return v;
    };

    float blockPeak = 0.0f;
    float blockMinGain = 1.0f;

    for (int n = 0; n < frameCount; ++n) {
        // Click-free bypass crossfade toward the published target.
        if (bypassMix_ < bypassTarget) {
            bypassMix_ = std::min(bypassMix_ + bypassStep, bypassTarget);
        } else if (bypassMix_ > bypassTarget) {
            bypassMix_ = std::max(bypassMix_ - bypassStep, bypassTarget);
        }

        const float dryL = channels[0][n];
        const float dryR = stereo ? channels[1][n] : dryL;
        const float inL = sanitize(dryL);
        const float inR = stereo ? sanitize(dryR) : inL;

        if (std::isfinite(dryL)) blockPeak = std::max(blockPeak, std::fabs(dryL));
        if (stereo && std::isfinite(dryR)) blockPeak = std::max(blockPeak, std::fabs(dryR));

        float leftAC = inL, rightAC = inR;

        // Sidechain detection signal: peaking EQ of the high-passed input.
        float leftSC = peakL.process(hpL.process(inL));
        float rightSC = stereo ? peakR.process(hpR.process(inR)) : leftSC;
        const float leftMC = leftSC;   // monitored sidechain (S/C-Listen)
        const float rightMC = rightSC;

        float gain = 1.0f;
        if (cs.mode == kModeSplit) {
            hpL.sanitize();
            if (stereo) hpR.sanitize();
            // Calf re-uses the same high-pass object for the band split, so it is
            // processed a second time here; preserved verbatim.
            float leftRC = static_cast<float>(hpL.process(inL));
            float rightRC = stereo ? static_cast<float>(hpR.process(inR)) : leftRC;
            gain = compress(leftRC, rightRC, leftSC, rightSC);
            leftAC = static_cast<float>(lpL.process(inL));
            rightAC = stereo ? static_cast<float>(lpR.process(inR)) : leftAC;
            leftAC += leftRC;
            rightAC += rightRC;
        } else { // WIDE: compress the whole band from the sidechain detector.
            gain = compress(leftAC, rightAC, leftSC, rightSC);
        }

        blockMinGain = std::min(blockMinGain, gain);

        float outL = cs.scListen ? leftMC : leftAC;
        float outR = cs.scListen ? rightMC : rightAC;

        const float invMix = 1.0f - bypassMix_;
        outL = bypassMix_ * dryL + invMix * outL;
        if (stereo) outR = bypassMix_ * dryR + invMix * outR;

        channels[0][n] = guard(outL);
        if (stereo) channels[1][n] = guard(outR);
    }

    hpL.sanitize();
    lpL.sanitize();
    peakL.sanitize();
    if (stereo) {
        hpR.sanitize();
        lpR.sanitize();
        peakR.sanitize();
    }

    inputPeakMeter_.store(blockPeak, std::memory_order_relaxed);
    float reductionDb = 0.0f;
    if (blockMinGain > 0.0f && blockMinGain < 1.0f) {
        reductionDb = -20.0f * std::log10(blockMinGain);
    }
    gainReductionMeterDb_.store(reductionDb, std::memory_order_relaxed);
}

} // namespace td
