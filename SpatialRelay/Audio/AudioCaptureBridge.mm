#import "AudioCaptureBridge.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

namespace {

// More than ten seconds at 48 kHz. This leaves ample headroom for an AirPods
// spatial-mode hardware reconfiguration without dropping or compressing PCM.
constexpr UInt32 kRingCapacityFrames = 524288;
NSString *const kCaptureErrorDomain = @"com.shevlfs.SpatialRelay.AudioCapture";

struct CaptureStorage {
    explicit CaptureStorage(UInt32 capacity)
        : samples(static_cast<size_t>(capacity) * 2, 0.0f),
          capacityFrames(capacity),
          mask(capacity - 1) {}

    std::vector<float> samples;
    const UInt32 capacityFrames;
    const UInt32 mask;

    alignas(64) std::atomic<UInt64> readCursor { 0 };
    alignas(64) std::atomic<UInt64> writeCursor { 0 };
    std::atomic<UInt64> droppedFrames { 0 };
    std::atomic<UInt64> formatMismatches { 0 };
    std::atomic<UInt64> callbacks { 0 };
    std::atomic<UInt64> capturedFrames { 0 };
    std::atomic<UInt32> peakBits { 0 };
    std::atomic<bool> callbackIsRegistered { false };

    bool nonInterleaved = false;
    UInt32 bytesPerFrame = 0;

    void reset() noexcept {
        readCursor.store(0, std::memory_order_release);
        writeCursor.store(0, std::memory_order_release);
        droppedFrames.store(0, std::memory_order_relaxed);
        formatMismatches.store(0, std::memory_order_relaxed);
        callbacks.store(0, std::memory_order_relaxed);
        capturedFrames.store(0, std::memory_order_relaxed);
        peakBits.store(0, std::memory_order_relaxed);
    }

    UInt32 available() const noexcept {
        // Load the consumer-owned cursor first. If the consumer advances after
        // this snapshot, the result is only conservatively high; it cannot
        // underflow because the producer-owned cursor never moves backwards.
        const auto read = readCursor.load(std::memory_order_acquire);
        const auto write = writeCursor.load(std::memory_order_acquire);
        if (write < read) return 0;
        return static_cast<UInt32>(std::min<UInt64>(write - read, capacityFrames));
    }

    void publishPeak(float peak) noexcept {
        UInt32 bits = 0;
        static_assert(sizeof(bits) == sizeof(peak));
        std::memcpy(&bits, &peak, sizeof(bits));
        // Nonnegative finite IEEE Float32 values have the same bit ordering as
        // UInt32. Hold the maximum until the UI consumes it, rather than losing
        // transients to a quieter callback between meter polls.
        UInt32 previous = peakBits.load(std::memory_order_relaxed);
        while (previous < bits &&
               !peakBits.compare_exchange_weak(previous, bits, std::memory_order_relaxed)) {}
    }

    float takePeak() noexcept {
        const UInt32 bits = peakBits.exchange(0, std::memory_order_relaxed);
        float peak = 0.0f;
        std::memcpy(&peak, &bits, sizeof(peak));
        return peak;
    }

    UInt32 writableFrames(UInt32 requested, UInt64 write, UInt64 read) noexcept {
        const UInt64 occupied = write - read;
        const UInt32 freeFrames = occupied >= capacityFrames
            ? 0
            : capacityFrames - static_cast<UInt32>(occupied);
        const UInt32 writable = std::min(requested, freeFrames);
        if (writable < requested) {
            droppedFrames.fetch_add(requested - writable, std::memory_order_relaxed);
        }
        return writable;
    }

    void writeInterleaved(const float *source, UInt32 requestedFrames) noexcept {
        if (source == nullptr || requestedFrames == 0) return;

        const UInt64 write = writeCursor.load(std::memory_order_relaxed);
        const UInt64 read = readCursor.load(std::memory_order_acquire);
        const UInt32 frames = writableFrames(requestedFrames, write, read);
        if (frames == 0) return;

        const UInt32 offset = static_cast<UInt32>(write) & mask;
        const UInt32 first = std::min(frames, capacityFrames - offset);
        std::memcpy(samples.data() + static_cast<size_t>(offset) * 2,
                    source,
                    static_cast<size_t>(first) * 2 * sizeof(float));
        if (first < frames) {
            std::memcpy(samples.data(),
                        source + static_cast<size_t>(first) * 2,
                        static_cast<size_t>(frames - first) * 2 * sizeof(float));
        }

        float peak = 0.0f;
        for (UInt32 index = 0; index < frames * 2; ++index) {
            peak = std::max(peak, std::fabs(source[index]));
        }
        publishPeak(std::min(peak, 1.0f));
        capturedFrames.fetch_add(frames, std::memory_order_relaxed);
        writeCursor.store(write + frames, std::memory_order_release);
    }

    void writePlanar(const float *left, const float *right, UInt32 requestedFrames) noexcept {
        if (left == nullptr || right == nullptr || requestedFrames == 0) return;

        const UInt64 write = writeCursor.load(std::memory_order_relaxed);
        const UInt64 read = readCursor.load(std::memory_order_acquire);
        const UInt32 frames = writableFrames(requestedFrames, write, read);
        if (frames == 0) return;

        float peak = 0.0f;
        for (UInt32 index = 0; index < frames; ++index) {
            const UInt32 destination = (static_cast<UInt32>(write) + index) & mask;
            samples[static_cast<size_t>(destination) * 2] = left[index];
            samples[static_cast<size_t>(destination) * 2 + 1] = right[index];
            peak = std::max(peak, std::max(std::fabs(left[index]), std::fabs(right[index])));
        }

        publishPeak(std::min(peak, 1.0f));
        capturedFrames.fetch_add(frames, std::memory_order_relaxed);
        writeCursor.store(write + frames, std::memory_order_release);
    }

    UInt32 readInterleaved(float *destination, UInt32 maximumFrames) noexcept {
        if (destination == nullptr || maximumFrames == 0) return 0;

        const UInt64 read = readCursor.load(std::memory_order_relaxed);
        const UInt64 write = writeCursor.load(std::memory_order_acquire);
        const UInt32 frames = static_cast<UInt32>(
            std::min<UInt64>(maximumFrames, write - read)
        );
        if (frames == 0) return 0;

        const UInt32 offset = static_cast<UInt32>(read) & mask;
        const UInt32 first = std::min(frames, capacityFrames - offset);
        std::memcpy(destination,
                    samples.data() + static_cast<size_t>(offset) * 2,
                    static_cast<size_t>(first) * 2 * sizeof(float));
        if (first < frames) {
            std::memcpy(destination + static_cast<size_t>(first) * 2,
                        samples.data(),
                        static_cast<size_t>(frames - first) * 2 * sizeof(float));
        }

        readCursor.store(read + frames, std::memory_order_release);
        return frames;
    }

    UInt32 discard(UInt32 maximumFrames) noexcept {
        const UInt64 read = readCursor.load(std::memory_order_relaxed);
        const UInt64 write = writeCursor.load(std::memory_order_acquire);
        const UInt32 frames = static_cast<UInt32>(
            std::min<UInt64>(maximumFrames, write - read)
        );
        readCursor.store(read + frames, std::memory_order_release);
        return frames;
    }
};

CaptureStorage *storage(SRAudioCaptureBridge *bridge) noexcept {
    return static_cast<CaptureStorage *>(bridge->_captureStorage);
}

bool isFloatAligned(const void *pointer) noexcept {
    return pointer != nullptr &&
        (reinterpret_cast<std::uintptr_t>(pointer) % alignof(float)) == 0;
}

OSStatus captureIOProc(AudioObjectID,
                       const AudioTimeStamp *,
                       const AudioBufferList *inputData,
                       const AudioTimeStamp *,
                       AudioBufferList *,
                       const AudioTimeStamp *,
                       void *clientData) noexcept {
    auto *state = static_cast<CaptureStorage *>(clientData);
    if (state == nullptr) {
        return noErr;
    }
    state->callbacks.fetch_add(1, std::memory_order_relaxed);

    if (inputData == nullptr || inputData->mNumberBuffers == 0) return noErr;

    if (state->nonInterleaved) {
        if (inputData->mNumberBuffers != 2) {
            state->formatMismatches.fetch_add(1, std::memory_order_relaxed);
            return noErr;
        }

        const AudioBuffer &leftBuffer = inputData->mBuffers[0];
        const AudioBuffer &rightBuffer = inputData->mBuffers[1];
        if (leftBuffer.mDataByteSize == 0 && rightBuffer.mDataByteSize == 0) return noErr;
        if (leftBuffer.mNumberChannels != 1 ||
            rightBuffer.mNumberChannels != 1 ||
            !isFloatAligned(leftBuffer.mData) ||
            !isFloatAligned(rightBuffer.mData) ||
            leftBuffer.mDataByteSize != rightBuffer.mDataByteSize ||
            leftBuffer.mDataByteSize % sizeof(float) != 0) {
            state->formatMismatches.fetch_add(1, std::memory_order_relaxed);
            return noErr;
        }

        const UInt32 byteCount = leftBuffer.mDataByteSize;
        const UInt32 frameCount = byteCount / sizeof(float);
        state->writePlanar(static_cast<const float *>(leftBuffer.mData),
                           static_cast<const float *>(rightBuffer.mData),
                           frameCount);
    } else {
        if (inputData->mNumberBuffers != 1) {
            state->formatMismatches.fetch_add(1, std::memory_order_relaxed);
            return noErr;
        }
        const AudioBuffer &buffer = inputData->mBuffers[0];
        if (buffer.mDataByteSize == 0) return noErr;
        if (buffer.mNumberChannels != 2 ||
            !isFloatAligned(buffer.mData) ||
            state->bytesPerFrame == 0 ||
            buffer.mDataByteSize % state->bytesPerFrame != 0) {
            state->formatMismatches.fetch_add(1, std::memory_order_relaxed);
            return noErr;
        }

        const UInt32 frameCount = buffer.mDataByteSize / state->bytesPerFrame;
        state->writeInterleaved(static_cast<const float *>(buffer.mData), frameCount);
    }

    return noErr;
}

NSError *captureError(NSString *operation, OSStatus status) {
    NSString *message = [NSString stringWithFormat:@"%@ failed with Core Audio status %d.",
                         operation,
                         static_cast<int>(status)];
    return [NSError errorWithDomain:kCaptureErrorDomain
                               code:status
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

} // namespace

@interface SRPCMChunk ()
@property(nonatomic, readwrite) NSData *data;
@property(nonatomic, readwrite) UInt32 frameCount;
- (instancetype)initWithData:(NSData *)data frameCount:(UInt32)frameCount;
@end

@implementation SRPCMChunk

- (instancetype)initWithData:(NSData *)data frameCount:(UInt32)frameCount {
    self = [super init];
    if (self) {
        _data = data;
        _frameCount = frameCount;
    }
    return self;
}

@end

@implementation SRAudioCaptureBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        static_assert((kRingCapacityFrames & (kRingCapacityFrames - 1)) == 0,
                      "Ring capacity must be a power of two");
        _captureStorage = new CaptureStorage(kRingCapacityFrames);
        _deviceID = kAudioObjectUnknown;
        _ioProcID = nullptr;
        _ioProcMayBeRunning = NO;
    }
    return self;
}

- (void)dealloc {
    const BOOL stopped = [self stopWithError:nil];
    // A failed IOProc destruction is extremely rare, but freeing callback memory
    // would be unsafe. Leak the bounded storage until process exit instead.
    if (stopped) delete storage(self);
    _captureStorage = nullptr;
}

- (BOOL)isCapturing {
    auto *state = storage(self);
    return state != nullptr && state->callbackIsRegistered.load(std::memory_order_acquire);
}

- (UInt32)availableFrameCount {
    auto *state = storage(self);
    return state == nullptr ? 0 : state->available();
}

- (UInt64)droppedFrameCount {
    auto *state = storage(self);
    return state == nullptr ? 0 : state->droppedFrames.load(std::memory_order_relaxed);
}

- (UInt64)formatMismatchCount {
    auto *state = storage(self);
    return state == nullptr ? 0 : state->formatMismatches.load(std::memory_order_relaxed);
}

- (UInt64)callbackCount {
    auto *state = storage(self);
    return state == nullptr ? 0 : state->callbacks.load(std::memory_order_relaxed);
}

- (UInt64)capturedFrameCount {
    auto *state = storage(self);
    return state == nullptr ? 0 : state->capturedFrames.load(std::memory_order_relaxed);
}

- (float)peakLevel {
    auto *state = storage(self);
    return state == nullptr ? 0.0f : state->takePeak();
}

- (BOOL)startCapturingDevice:(AudioObjectID)deviceID
                      format:(AudioStreamBasicDescription)format
                       error:(NSError * _Nullable __autoreleasing *)error {
    if (error != nullptr) *error = nil;

    NSError *stopError = nil;
    if (![self stopWithError:&stopError]) {
        if (error != nullptr) *error = stopError;
        return NO;
    }

    const AudioFormatFlags allowedFlags = kAudioFormatFlagIsFloat |
        kAudioFormatFlagIsPacked |
        kAudioFormatFlagIsNonInterleaved |
        kAudioFormatFlagIsNonMixable;
    const bool hasOnlySupportedFlags = (format.mFormatFlags & ~allowedFlags) == 0;
    const bool isFloatPCM = format.mFormatID == kAudioFormatLinearPCM &&
        hasOnlySupportedFlags &&
        (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
        (format.mFormatFlags & kAudioFormatFlagIsPacked) != 0 &&
        (format.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0;
    const bool nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 expectedBytesPerFrame = nonInterleaved ? sizeof(float) : sizeof(float) * 2;
    const bool isStereoFloat32 = isFloatPCM &&
        format.mChannelsPerFrame == 2 &&
        format.mBitsPerChannel == 32 &&
        std::isfinite(format.mSampleRate) &&
        format.mSampleRate > 0 &&
        format.mFramesPerPacket == 1 &&
        format.mBytesPerFrame == expectedBytesPerFrame &&
        format.mBytesPerPacket == expectedBytesPerFrame &&
        format.mReserved == 0;
    if (!isStereoFloat32) {
        if (error != nullptr) {
            NSString *description = [NSString stringWithFormat:
                @"Expected packed native-endian stereo Float32 PCM; received format '%c%c%c%c', flags 0x%08x, %u channels, %u bits, %u bytes/frame, %u frames/packet at %.3f Hz.",
                static_cast<char>((format.mFormatID >> 24) & 0xff),
                static_cast<char>((format.mFormatID >> 16) & 0xff),
                static_cast<char>((format.mFormatID >> 8) & 0xff),
                static_cast<char>(format.mFormatID & 0xff),
                format.mFormatFlags,
                format.mChannelsPerFrame,
                format.mBitsPerChannel,
                format.mBytesPerFrame,
                format.mFramesPerPacket,
                format.mSampleRate];
            *error = [NSError errorWithDomain:kCaptureErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: description}];
        }
        return NO;
    }

    auto *state = storage(self);
    state->reset();
    state->nonInterleaved = nonInterleaved;
    state->bytesPerFrame = expectedBytesPerFrame;

    AudioDeviceIOProcID ioProcID = nullptr;
    OSStatus status = AudioDeviceCreateIOProcID(deviceID,
                                                captureIOProc,
                                                state,
                                                &ioProcID);
    if (status != noErr) {
        if (error != nullptr) *error = captureError(@"Creating the tap callback", status);
        return NO;
    }

    _deviceID = deviceID;
    _ioProcID = ioProcID;
    state->callbackIsRegistered.store(true, std::memory_order_release);
    // Set this before AudioDeviceStart. If start reports an error after doing
    // partial work, cleanup will still make a conservative stop attempt.
    _ioProcMayBeRunning = YES;

    status = AudioDeviceStart(deviceID, ioProcID);
    if (status != noErr) {
        NSError *cleanupError = nil;
        [self stopWithError:&cleanupError];
        if (error != nullptr) {
            NSError *startError = captureError(@"Starting the tap callback", status);
            if (cleanupError != nil) {
                NSString *message = [NSString stringWithFormat:@"%@ Cleanup also failed: %@",
                                     startError.localizedDescription,
                                     cleanupError.localizedDescription];
                *error = [NSError errorWithDomain:kCaptureErrorDomain
                                             code:status
                                         userInfo:@{NSLocalizedDescriptionKey: message}];
            } else {
                *error = startError;
            }
        }
        return NO;
    }

    return YES;
}

- (BOOL)stopWithError:(NSError * _Nullable __autoreleasing *)error {
    if (error != nullptr) *error = nil;
    if (_ioProcID == nullptr && _deviceID == kAudioObjectUnknown) {
        _ioProcMayBeRunning = NO;
        return YES;
    }
    if (_ioProcID == nullptr || _deviceID == kAudioObjectUnknown) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:kCaptureErrorDomain
                                         code:-2
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"The tap callback has inconsistent Core Audio ownership state."
            }];
        }
        return NO;
    }

    OSStatus stopStatus = noErr;
    if (_ioProcMayBeRunning) {
        stopStatus = AudioDeviceStop(_deviceID, _ioProcID);
        if (stopStatus == noErr || stopStatus == kAudioHardwareNotRunningError) {
            _ioProcMayBeRunning = NO;
        }
    }

    // Always attempt destruction. It is the authoritative ownership boundary:
    // once this succeeds, HAL can no longer call the clientData pointer even if
    // AudioDeviceStop returned an error.
    const OSStatus destroyStatus = AudioDeviceDestroyIOProcID(_deviceID, _ioProcID);
    if (destroyStatus == noErr) {
        _ioProcID = nullptr;
        _deviceID = kAudioObjectUnknown;
        _ioProcMayBeRunning = NO;
        storage(self)->callbackIsRegistered.store(false, std::memory_order_release);
        return YES;
    }

    if (error != nullptr) {
        NSError *destroyError = captureError(@"Destroying the tap callback", destroyStatus);
        if (stopStatus != noErr && stopStatus != kAudioHardwareNotRunningError) {
            NSError *stopError = captureError(@"Stopping the tap callback", stopStatus);
            NSString *message = [NSString stringWithFormat:@"%@ %@",
                                 stopError.localizedDescription,
                                 destroyError.localizedDescription];
            *error = [NSError errorWithDomain:kCaptureErrorDomain
                                         code:destroyStatus
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
        } else {
            *error = destroyError;
        }
    }
    return NO;
}

- (void)reset {
    // Resetting cursors while the real-time producer is active would violate
    // the SPSC ring invariants. The app only resets before capture or in tests.
    if (_ioProcMayBeRunning) return;
    auto *state = storage(self);
    if (state != nullptr) state->reset();
}

- (SRPCMChunk *)dequeueChunkWithMaximumFrameCount:(UInt32)maximumFrameCount {
    auto *state = storage(self);
    if (state == nullptr || maximumFrameCount == 0) return nil;

    const UInt32 available = state->available();
    const UInt32 requested = std::min(maximumFrameCount, available);
    if (requested == 0) return nil;

    const size_t byteCount = static_cast<size_t>(requested) * 2 * sizeof(float);
    std::unique_ptr<float, decltype(&std::free)> samples(
        static_cast<float *>(std::malloc(byteCount)), &std::free
    );
    if (!samples) return nil;
    const UInt32 actual = state->readInterleaved(samples.get(), requested);
    if (actual == 0) return nil;
    // Immutable backing can bridge to Swift Data without copying mutable bytes.
    NSData *data = [[NSData alloc] initWithBytesNoCopy:samples.release()
                                              length:static_cast<NSUInteger>(actual) * 2 * sizeof(float)
                                        freeWhenDone:YES];
    return [[SRPCMChunk alloc] initWithData:data frameCount:actual];
}

- (UInt32)discardFramesWithMaximumFrameCount:(UInt32)maximumFrameCount {
    auto *state = storage(self);
    return state == nullptr ? 0 : state->discard(maximumFrameCount);
}

#if DEBUG
- (void)debugEnqueueInterleavedFloatData:(NSData *)data {
    auto *state = storage(self);
    if (_ioProcMayBeRunning ||
        state == nullptr ||
        !isFloatAligned(data.bytes) ||
        data.length % (2 * sizeof(float)) != 0) return;
    const UInt32 frames = static_cast<UInt32>(data.length / (2 * sizeof(float)));
    state->writeInterleaved(static_cast<const float *>(data.bytes), frames);
}
#endif

@end
