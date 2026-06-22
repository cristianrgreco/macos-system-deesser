//
//  TDRealtimeRenderer.h
//  De-Esser
//
//  Objective-C façade over the C++ real-time render path. The public interface
//  is plain C / Objective-C (no C++) so it can be imported by Swift through the
//  bridging header. It owns the AudioDeviceIOProcID and a static C callback; the
//  callback never messages Objective-C or touches the Swift model (spec §4.3).
//
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#include <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

/// Logical stream description used to size the renderer before the audio thread
/// starts. Channel counts are the logical channel counts (1 = mono, 2 = stereo).
typedef struct {
    double   sampleRate;
    uint32_t inputChannelCount;   // tap stream
    uint32_t outputChannelCount;  // physical device
    uint32_t maxFramesPerBuffer;  // upper bound for scratch allocation
} TDStreamLayout;

/// De-esser parameters bridged to the C++ DSP (mirrors td::DeEsserParams).
/// These are the Calf "Deesser" controls (the de-esser EasyEffects wraps); the
/// dB-denominated fields are converted to linear inside the DSP.
typedef struct {
    float thresholdDb;   // detection threshold (dBFS)
    float ratio;         // compression ratio (1..20)
    float makeupDb;      // makeup gain (dB)
    float f1FreqHz;      // "Split" — sidechain high-pass / crossover
    float f2FreqHz;      // "Peak" — sibilance band centre
    float f1LevelDb;     // "Gain" — high-pass pass-band gain (dB)
    float f2LevelDb;     // "Level" — sidechain peak boost (dB)
    float f2Q;           // "Peak Q"
    float laxity;        // detector laxity (1..100) → attack/release
    int32_t detection;   // 0 = RMS, 1 = peak
    int32_t mode;        // 0 = wide, 1 = split
    bool  scListen;      // monitor only the sidechain (for tuning)
    bool  bypass;
} TDDeEsserParams;

/// Lock-free meter snapshot polled by the UI at a low rate (spec §4.1).
typedef struct {
    uint64_t heartbeat;
    uint64_t lastHostTime;
    float    inputPeak;
    float    gainReductionDb;
    bool     fatalFormat;
} TDRendererMeters;

@interface TDRealtimeRenderer : NSObject

/// Allocates all DSP/scratch state for the given layout. No audio runs yet.
- (instancetype)initWithLayout:(TDStreamLayout)layout NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Control-thread parameter update; coefficients are computed here and swapped
/// atomically inside the DSP (spec §11.4).
- (void)updateParameters:(TDDeEsserParams)params;

/// Registers the I/O proc on the aggregate device and starts it. Returns an
/// OSStatus; on failure no proc remains registered.
- (OSStatus)startOnAggregateDevice:(AudioObjectID)aggregateDeviceID;

/// Marks the renderer stopping (callback emits silence, ceases meter updates),
/// then stops and destroys the I/O proc. Safe to call more than once.
- (void)stop;

/// Lock-free snapshot of heartbeat/meters/fatal-format state.
- (TDRendererMeters)meters;

@end

NS_ASSUME_NONNULL_END
