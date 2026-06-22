//
//  Biquad.hpp
//  De-Esser
//
//  Header-only RBJ-cookbook biquad, ported verbatim (coefficient math and the
//  Direct-Form-II `biquad_d2` topology) from Calf Studio Gear
//  (calf-studio-gear/calf, src/calf/biquad.h) — the same filter the Calf Deesser
//  plugin uses, which is what EasyEffects wraps for PipeWire/PulseAudio.
//
//  Pure C++: no Core Audio, no allocation, no locks — safe for the real-time
//  thread and unit-testable with plain arrays.
//
#pragma once

#include <cmath>

namespace td {

/// Flushes non-finite values and denormals to zero (Calf's `sanitize` /
/// `sanitize_denormal`), avoiding the large CPU penalty of subnormals.
inline double biquadSanitize(double v) noexcept {
    if (!std::isfinite(v)) return 0.0;
    if (std::fabs(v) < 1.0e-18) return 0.0;
    return v;
}

/// RBJ-cookbook biquad coefficients in Calf's sign convention: `a*` are the
/// feed-forward (numerator) terms and `b1/b2` the feed-back (denominator) terms.
struct BiquadCoeffs {
    double a0 = 1.0;
    double a1 = 0.0;
    double a2 = 0.0;
    double b1 = 0.0;
    double b2 = 0.0;

    /// Low-pass (RBJ). `gain` scales the pass-band.
    inline void set_lp_rbj(double fc, double q, double sr, double gain = 1.0) noexcept {
        double omega = (2.0 * M_PI * fc / sr);
        double sn = std::sin(omega);
        double cs = std::cos(omega);
        double alpha = (sn / (2 * q));
        double inv = (1.0 / (1.0 + alpha));
        a2 = a0 = (gain * inv * (1.0 - cs) * 0.5);
        a1 = a0 + a0;
        b1 = (-2.0 * cs * inv);
        b2 = ((1.0 - alpha) * inv);
    }

    /// High-pass (RBJ). `gain` scales the pass-band.
    inline void set_hp_rbj(double fc, double q, double esr, double gain = 1.0) noexcept {
        double omega = (2 * M_PI * fc / esr);
        double sn = std::sin(omega);
        double cs = std::cos(omega);
        double alpha = (sn / (2 * q));
        double inv = (1.0 / (1.0 + alpha));
        a0 = (gain * inv * (1 + cs) / 2);
        a1 = -2.0 * a0;
        a2 = a0;
        b1 = (-2 * cs * inv);
        b2 = ((1 - alpha) * inv);
    }

    /// Peaking EQ (RBJ). `peak` is the linear band gain.
    inline void set_peakeq_rbj(double freq, double q, double peak, double sr) noexcept {
        double A = std::sqrt(peak);
        double w0 = freq * 2 * M_PI * (1.0 / sr);
        double alpha = std::sin(w0) / (2 * q);
        double ib0 = 1.0 / (1 + alpha / A);
        a1 = b1 = -2 * std::cos(w0) * ib0;
        a0 = ib0 * (1 + alpha * A);
        a2 = ib0 * (1 - alpha * A);
        b2 = ib0 * (1 - alpha / A);
    }

    inline void copy_coeffs(const BiquadCoeffs& src) noexcept {
        a0 = src.a0;
        a1 = src.a1;
        a2 = src.a2;
        b1 = src.b1;
        b2 = src.b2;
    }
};

/// Direct Form II biquad with double-precision state (Calf `biquad_d2`).
struct Biquad : public BiquadCoeffs {
    double w1 = 0.0;
    double w2 = 0.0;

    inline double process(double in) noexcept {
        double n = biquadSanitize(in);
        w1 = biquadSanitize(w1);
        w2 = biquadSanitize(w2);
        double tmp = n - w1 * b1 - w2 * b2;
        double out = tmp * a0 + w1 * a1 + w2 * a2;
        w2 = w1;
        w1 = tmp;
        return out;
    }

    inline void sanitize() noexcept {
        w1 = biquadSanitize(w1);
        w2 = biquadSanitize(w2);
    }

    inline void reset() noexcept {
        w1 = 0.0;
        w2 = 0.0;
    }
};

} // namespace td
