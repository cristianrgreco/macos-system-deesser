//
//  DeEsserDSP.hpp
//  Teams De-Esser
//
//  Faithful C++ port of the Calf Studio Gear "Deesser" plugin
//  (calf-studio-gear/calf: deesser_audio_module + gain_reduction_audio_module),
//  which is the de-esser EasyEffects wraps for PipeWire/PulseAudio. The algorithm
//  is reproduced exactly: a sidechain high-pass + peaking-EQ feeds Thor's
//  compressor (RMS/peak detection, soft-knee gain computer, laxity-derived
//  attack/release), applied either to the whole band (WIDE) or to the high band
//  of a Linkwitz-style split (SPLIT).
//
//  Pure C++ with no Core Audio dependency so it can be exercised by offline unit
//  tests on plain arrays. All buffers and state are allocated in prepare() before
//  the audio thread starts; process() performs no allocation, locks, or logging.
//
#pragma once

#include <atomic>
#include "Biquad.hpp"

namespace td {

constexpr int kMaxChannels = 2;

/// Detection mode (Calf `deesser_detection_names`).
enum DeEsserDetection { kDetectionRMS = 0, kDetectionPeak = 1 };

/// Processing mode (Calf `CalfDeessModes`).
enum DeEsserModeKind { kModeWide = 0, kModeSplit = 1 };

/// Parameters mirror the C struct exposed to Swift (TDDeEsserParams). The DSP
/// owns its own plain-C++ copy so the header has no Objective-C dependency.
///
/// dB-denominated fields are in decibels and converted to the linear values the
/// Calf module expects inside setParameters() — exactly where EasyEffects'
/// `BIND_LV2_PORT_DB` macro performs the same conversion. Defaults reproduce the
/// Calf Deesser metadata defaults (== EasyEffects defaults): threshold 0.125
/// linear (-18.06 dB), ratio 3:1, makeup 0 dB, split 6 kHz, peak 4.5 kHz / +12 dB,
/// laxity 15, RMS detection, Wide mode.
struct DeEsserParams {
    float thresholdDb = -18.06f; // detection threshold (0.125 linear)
    float ratio       = 3.0f;    // 1..20
    float makeupDb    = 0.0f;    // makeup gain
    float f1FreqHz    = 6000.0f; // "Split" — sidechain high-pass / crossover
    float f2FreqHz    = 4500.0f; // "Peak" — sibilance band centre
    float f1LevelDb   = 0.0f;    // "Gain" — high-pass pass-band gain (1.0 linear)
    float f2LevelDb   = 12.04f;  // "Level" — sidechain peak boost (4.0 linear)
    float f2Q         = 1.0f;    // "Peak Q"
    float laxity      = 15.0f;   // detector laxity (1..100) → attack/release
    int   detection   = kDetectionRMS;
    int   mode         = kModeWide;
    bool  scListen    = false;   // monitor the sidechain ("S/C-Listen")
    bool  bypass      = false;
};

class DeEsserDSP {
public:
    DeEsserDSP();

    /// Allocates/clears state for a given sample rate and channel count.
    /// Must be called on the control thread before the audio thread runs.
    void prepare(double sampleRate, int channelCount);

    /// Recomputes filter coefficients and the compressor curve off the real-time
    /// thread into the inactive slot and atomically publishes it. Safe to call
    /// while process() is running as long as calls are not faster than the audio
    /// block rate.
    void setParameters(const DeEsserParams& params);

    /// Clears filter and detector state. Only call when the sample rate changes
    /// or the graph is rebuilt, never mid-stream for parameter edits.
    void reset();

    /// Processes up to kMaxChannels in place. `channels[c]` points to
    /// `frameCount` contiguous floats. Real-time safe.
    void process(float* const* channels, int channelCount, int frameCount) noexcept;

    /// Most recent applied gain reduction in positive dB (0 == no reduction).
    float currentGainReductionDb() const noexcept { return gainReductionMeterDb_.load(std::memory_order_relaxed); }

    /// Most recent input peak (linear, full-band).
    float currentInputPeak() const noexcept { return inputPeakMeter_.load(std::memory_order_relaxed); }

private:
    /// Precomputed, publishable coefficient/curve set (off-thread side of the
    /// double buffer). Holds everything the Calf module derives in params_changed
    /// / update_curve so process() never recomputes coefficients per sample.
    struct CoeffSet {
        BiquadCoeffs hp;    // sidechain high-pass (f1)
        BiquadCoeffs lp;    // split low-pass (f1)
        BiquadCoeffs peak;  // sidechain peaking EQ (f2)

        // gain_reduction compressor
        float attackCoeff   = 0.0f;
        float releaseCoeff  = 0.0f;
        float makeupLin     = 1.0f;
        float ratio         = 3.0f;
        float knee          = 2.8f; // Calf fixes the deesser knee at 2.8
        // update_curve() products
        float thres              = 0.0f;
        float kneeStart          = 0.0f;
        float kneeStop           = 0.0f;
        float compressedKneeStop = 0.0f;
        float linKneeStart       = 0.0f;
        float adjKneeStart       = 0.0f;

        bool  rms        = true;  // detection == RMS
        int   mode       = kModeWide;
        bool  scListen   = false;
        float bypassTarget = 0.0f; // 1 == fully bypassed (dry)
    };

    // Per-channel filter state (coefficients are copied in from the active
    // CoeffSet at each block boundary; w1/w2 persist across blocks).
    struct ChannelState {
        Biquad hp;
        Biquad lp;
        Biquad peak;
    };

    /// Thor's compressor gain computer (Calf gain_reduction::output_gain).
    float outputGain(float linSlope, bool rms, const CoeffSet& cs) const noexcept;

    // Detector / smoothing state (real-time owned).
    float linSlope_ = 0.0f;   // compressor envelope
    float bypassMix_ = 0.0f;  // 1 == dry (crossfaded)

    ChannelState channels_[kMaxChannels];

    double sampleRate_ = 48000.0;
    int channelCount_ = 2;

    // Double-buffered coefficient sets with atomic active index.
    CoeffSet coeffSets_[2];
    std::atomic<int> activeIndex_{0};

    std::atomic<float> gainReductionMeterDb_{0.0f};
    std::atomic<float> inputPeakMeter_{0.0f};

    static float dbToLinear(float db) noexcept;
    static float sanitize(float x) noexcept;
};

} // namespace td
