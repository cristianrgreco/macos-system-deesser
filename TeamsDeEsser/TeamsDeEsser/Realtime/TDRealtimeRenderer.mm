//
//  TDRealtimeRenderer.mm
//  Teams De-Esser
//
#import "TDRealtimeRenderer.h"

#import <os/log.h>

#include <atomic>
#include <cstring>
#include <memory>
#include <vector>

// Control-thread diagnostics only. Never called from the audio callback.
static os_log_t TDRendererLog() {
    static os_log_t log = os_log_create("local.TeamsDeEsser", "renderer");
    return log;
}

#include "AudioBufferView.hpp"
#include "DeEsserDSP.hpp"

namespace {

/// Plain C++ render context passed to the static I/O proc as client data, so the
/// callback never messages Objective-C (spec §10.3).
struct RenderContext {
    td::DeEsserDSP dsp;

    int inputChannelCount = 2;
    int outputChannelCount = 2;
    int maxFrames = 16384;

    // scratch[0..maxFrames-1] = left, scratch[maxFrames..] = right. Allocated
    // once on the control thread; never resized on the audio thread.
    std::vector<float> scratch;

    std::atomic<uint64_t> heartbeat{0};
    std::atomic<uint64_t> lastHostTime{0};
    std::atomic<float> inputPeak{0.0f};
    std::atomic<float> gainReductionDb{0.0f};
    std::atomic<bool> fatalFormat{false};
    std::atomic<bool> stopping{false};
};

// Shared render body. Called from the I/O block (see -startOnAggregateDevice:).
// Real-time safe: no allocation, locks, logging, Obj-C, or Swift access.
void TDRenderProcess(RenderContext* ctx,
                     const AudioTimeStamp* inNow,
                     const AudioBufferList* inInputData,
                     AudioBufferList* outOutputData) {
    if (ctx == nullptr) return;

    // 1. Heartbeat + host time (always, so the watchdog sees liveness).
    ctx->heartbeat.fetch_add(1, std::memory_order_relaxed);
    if (inNow != nullptr) {
        ctx->lastHostTime.store(inNow->mHostTime, std::memory_order_relaxed);
    }

    // 3. Clear all output buffers first (silence is the safe default).
    if (outOutputData != nullptr) {
        for (UInt32 b = 0; b < outOutputData->mNumberBuffers; ++b) {
            AudioBuffer& buf = outOutputData->mBuffers[b];
            if (buf.mData != nullptr) {
                std::memset(buf.mData, 0, buf.mDataByteSize);
            }
        }
    }

    // When stopping, leave output silent and skip meter updates (spec §5.2).
    if (ctx->stopping.load(std::memory_order_relaxed)) {
        return;
    }

    // 2. Validate buffer lists.
    if (inInputData == nullptr || outOutputData == nullptr) {
        return;
    }

    // 4. Stack-only channel views.
    const td::AudioBufferView inView = td::AudioBufferView::make(inInputData);
    const td::AudioBufferView outView = td::AudioBufferView::make(outOutputData);

    if (outView.channelCount == 0) {
        // No usable output destination: cannot proceed (spec §10.2 fatal format).
        ctx->fatalFormat.store(true, std::memory_order_relaxed);
        return;
    }
    if (inView.channelCount == 0) {
        // No input this cycle (e.g. stopped tap); emit the silence already written.
        return;
    }

    // 5. Frame count from the buffer byte sizes; use the safe minimum.
    int frames = std::min(inView.frameCount, outView.frameCount);
    if (frames <= 0) return;
    if (frames > ctx->maxFrames) frames = ctx->maxFrames;

    // 6. Read mono/stereo Float32 input into scratch (deinterleaved).
    const int inCh = std::min(inView.channelCount, 2);
    float* s0 = ctx->scratch.data();
    float* s1 = ctx->scratch.data() + ctx->maxFrames;
    for (int n = 0; n < frames; ++n) {
        s0[n] = inView.get(0, n);
    }
    if (inCh >= 2) {
        for (int n = 0; n < frames; ++n) {
            s1[n] = inView.get(1, n);
        }
    }

    // 7. Run the de-esser (or bypass crossfade) in place on scratch.
    const int dspCh = (inCh >= 2) ? 2 : 1;
    float* chans[2] = { s0, s1 };
    ctx->dsp.process(chans, dspCh, frames);

    // 8. Write mono/stereo output, clearing unused channels (already cleared).
    if (outView.channelCount == 1) {
        for (int n = 0; n < frames; ++n) {
            const float v = (dspCh >= 2) ? 0.5f * (s0[n] + s1[n]) : s0[n];
            outView.set(0, n, v);
        }
    } else {
        for (int n = 0; n < frames; ++n) {
            outView.set(0, n, s0[n]);
        }
        const float* right = (dspCh >= 2) ? s1 : s0;
        for (int n = 0; n < frames; ++n) {
            outView.set(1, n, right[n]);
        }
        // Channels >= 2 remain at the silence written in step 3.
    }

    // 9. Publish meters (DSP already computed them per block).
    ctx->inputPeak.store(ctx->dsp.currentInputPeak(), std::memory_order_relaxed);
    ctx->gainReductionDb.store(ctx->dsp.currentGainReductionDb(), std::memory_order_relaxed);
}

} // namespace

@implementation TDRealtimeRenderer {
    std::unique_ptr<RenderContext> _ctx;
    AudioObjectID _deviceID;
    AudioDeviceIOProcID _procID;
    dispatch_queue_t _ioQueue;
    bool _running;
}

- (instancetype)initWithLayout:(TDStreamLayout)layout {
    self = [super init];
    if (self) {
        _ctx = std::make_unique<RenderContext>();
        _ctx->inputChannelCount = std::max<int>(1, (int)layout.inputChannelCount);
        _ctx->outputChannelCount = std::max<int>(1, (int)layout.outputChannelCount);
        _ctx->maxFrames = layout.maxFramesPerBuffer > 0 ? (int)layout.maxFramesPerBuffer : 16384;
        // Always reserve a generous floor so unexpectedly large buffers are safe.
        if (_ctx->maxFrames < 16384) _ctx->maxFrames = 16384;

        _ctx->scratch.assign((size_t)_ctx->maxFrames * 2, 0.0f);

        const int dspChannels = std::min<int>(_ctx->inputChannelCount, 2);
        _ctx->dsp.prepare(layout.sampleRate > 0 ? layout.sampleRate : 48000.0, dspChannels);

        // Dedicated serial queue at the highest QoS for the I/O block. The block
        // body (TDRenderProcess) is real-time safe.
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _ioQueue = dispatch_queue_create("local.TeamsDeEsser.io", attr);

        _deviceID = kAudioObjectUnknown;
        _procID = nullptr;
        _running = false;
    }
    return self;
}

- (void)updateParameters:(TDDeEsserParams)params {
    td::DeEsserParams p;
    p.thresholdDb = params.thresholdDb;
    p.ratio = params.ratio;
    p.makeupDb = params.makeupDb;
    p.f1FreqHz = params.f1FreqHz;
    p.f2FreqHz = params.f2FreqHz;
    p.f1LevelDb = params.f1LevelDb;
    p.f2LevelDb = params.f2LevelDb;
    p.f2Q = params.f2Q;
    p.laxity = params.laxity;
    p.detection = params.detection;
    p.mode = params.mode;
    p.scListen = params.scListen;
    p.bypass = params.bypass;
    _ctx->dsp.setParameters(p);
}

- (OSStatus)startOnAggregateDevice:(AudioObjectID)aggregateDeviceID {
    if (_running) return noErr;

    _ctx->stopping.store(false, std::memory_order_relaxed);
    _ctx->fatalFormat.store(false, std::memory_order_relaxed);

    _deviceID = aggregateDeviceID;

    // Capture the raw C++ context (not self) so the block does no Obj-C work.
    RenderContext* ctx = _ctx.get();
    OSStatus status = AudioDeviceCreateIOProcIDWithBlock(&_procID,
                                                         aggregateDeviceID,
                                                         _ioQueue,
                                                         ^(const AudioTimeStamp* inNow,
                                                           const AudioBufferList* inInputData,
                                                           const AudioTimeStamp* /*inInputTime*/,
                                                           AudioBufferList* outOutputData,
                                                           const AudioTimeStamp* /*inOutputTime*/) {
        TDRenderProcess(ctx, inNow, inInputData, outOutputData);
    });
    os_log(TDRendererLog(), "TDDIAG CreateIOProcID device=%u status=%d procID=%p",
           (unsigned)aggregateDeviceID, (int)status, (void *)_procID);
    if (status != noErr || _procID == nullptr) {
        _procID = nullptr;
        _deviceID = kAudioObjectUnknown;
        return status != noErr ? status : kAudioHardwareUnspecifiedError;
    }

    status = AudioDeviceStart(aggregateDeviceID, _procID);
    os_log(TDRendererLog(), "TDDIAG AudioDeviceStart device=%u status=%d",
           (unsigned)aggregateDeviceID, (int)status);
    if (status != noErr) {
        AudioDeviceDestroyIOProcID(aggregateDeviceID, _procID);
        _procID = nullptr;
        _deviceID = kAudioObjectUnknown;
        return status;
    }

    _running = true;
    return noErr;
}

- (void)stop {
    // 1. Mark stopping so the callback outputs silence and stops metering.
    _ctx->stopping.store(true, std::memory_order_relaxed);

    if (_procID != nullptr && _deviceID != kAudioObjectUnknown) {
        // 2. Stop I/O, 3. destroy the proc.
        AudioDeviceStop(_deviceID, _procID);
        AudioDeviceDestroyIOProcID(_deviceID, _procID);
    }
    _procID = nullptr;
    _deviceID = kAudioObjectUnknown;
    _running = false;
}

- (TDRendererMeters)meters {
    TDRendererMeters m;
    m.heartbeat = _ctx->heartbeat.load(std::memory_order_relaxed);
    m.lastHostTime = _ctx->lastHostTime.load(std::memory_order_relaxed);
    m.inputPeak = _ctx->inputPeak.load(std::memory_order_relaxed);
    m.gainReductionDb = _ctx->gainReductionDb.load(std::memory_order_relaxed);
    m.fatalFormat = _ctx->fatalFormat.load(std::memory_order_relaxed);
    return m;
}

- (void)dealloc {
    [self stop];
}

@end
