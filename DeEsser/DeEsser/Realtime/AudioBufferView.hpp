//
//  AudioBufferView.hpp
//  De-Esser
//
//  Zero-allocation, stack-only view over an AudioBufferList. Flattens the list
//  into logical Float32 channels regardless of whether the data is interleaved
//  (one buffer, N channels) or non-interleaved (N buffers, 1 channel each), and
//  any mix of the two (spec §10.2 supported layouts). Real-time safe.
//
#pragma once

#include <CoreAudio/CoreAudioTypes.h>
#include <algorithm>
#include <cstdint>

namespace td {

struct AudioBufferView {
    static constexpr int kMaxChannels = 16;

    float* base[kMaxChannels];
    int    stride[kMaxChannels]; // in floats between successive frames
    int    channelCount = 0;
    int    frameCount = 0;

    inline float get(int ch, int frame) const noexcept {
        return base[ch][frame * stride[ch]];
    }
    inline void set(int ch, int frame, float value) const noexcept {
        base[ch][frame * stride[ch]] = value;
    }

    /// Builds a view assuming Float32 samples (validated at graph setup).
    static AudioBufferView make(const AudioBufferList* abl) noexcept {
        AudioBufferView v;
        if (abl == nullptr) return v;

        int minFrames = INT32_MAX;
        for (UInt32 b = 0; b < abl->mNumberBuffers && v.channelCount < kMaxChannels; ++b) {
            const AudioBuffer& buf = abl->mBuffers[b];
            const int ch = static_cast<int>(buf.mNumberChannels);
            if (ch <= 0 || buf.mData == nullptr) continue;

            const int bytesPerFrame = ch * static_cast<int>(sizeof(float));
            const int frames = bytesPerFrame > 0
                ? static_cast<int>(buf.mDataByteSize) / bytesPerFrame
                : 0;
            minFrames = std::min(minFrames, frames);

            float* data = static_cast<float*>(buf.mData);
            for (int c = 0; c < ch && v.channelCount < kMaxChannels; ++c) {
                v.base[v.channelCount] = data + c;
                v.stride[v.channelCount] = ch; // interleaved within this buffer
                ++v.channelCount;
            }
        }

        v.frameCount = (v.channelCount == 0 || minFrames == INT32_MAX) ? 0 : minFrames;
        return v;
    }
};

} // namespace td
