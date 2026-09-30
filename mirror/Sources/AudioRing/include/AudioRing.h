#ifndef AUDIO_RING_H
#define AUDIO_RING_H

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

/// Decoded audio on its way from the receiving thread, which writes it, to the output unit,
/// which plays it: the buffer of scrcpy's audio regulator and the part of the regulator that
/// runs on the audio thread (audio_regulator.c). It is in C because Swift is not supported on
/// audio realtime threads. One writer, one reader and no lock: only the reader moves the read
/// position, and the writer drops frames by moving a floor that the reader skips to. Frames
/// are stereo Float32, one plane per channel.
typedef struct AudioRing AudioRing;

CF_ASSUME_NONNULL_BEGIN

/// A ring for `capacity` frames, which plays nothing until it first holds `target` frames.
AudioRing *audio_ring_new(uint32_t capacity, uint32_t target);

/// Appends `count` frames, or silence if `left` and `right` are NULL. Returns how many fit.
uint32_t audio_ring_write(AudioRing *ring, const float *_Nullable left, const float *_Nullable right, uint32_t count);

/// The number of frames buffered.
uint32_t audio_ring_level(AudioRing *ring);

/// Drops the oldest frames above `max`. Returns how many.
uint32_t audio_ring_drop(AudioRing *ring, uint32_t max);

/// The silent frames played for want of data since the last call.
uint32_t audio_ring_take_underflow(AudioRing *ring);

/// Whether playback has started.
bool audio_ring_played(AudioRing *ring);

/// The reader: an AURenderCallback whose refCon is the ring.
OSStatus audio_ring_render(void *ring, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                           UInt32 bus, UInt32 frames, AudioBufferList *_Nullable data) CA_REALTIME_API;

CF_ASSUME_NONNULL_END

#endif
