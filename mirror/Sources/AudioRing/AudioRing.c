#include "AudioRing.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Positions count frames from the start; the ring's size is a power of 2.
struct AudioRing {
    float *planes[2];
    uint32_t mask;
    uint32_t target;
    _Atomic uint64_t head;  // written up to here, by the writer
    _Atomic uint64_t tail;  // read up to here, by the reader
    _Atomic uint64_t floor; // dropped up to here, by the writer
    _Atomic uint32_t underflow;
    _Atomic bool played;
};

static uint64_t later(uint64_t a, uint64_t b) {
    return a > b ? a : b;
}

AudioRing *audio_ring_new(uint32_t capacity, uint32_t target) {
    uint32_t size = 1;
    while (size < capacity) {
        size *= 2;
    }
    AudioRing *ring = calloc(1, sizeof *ring);
    ring->planes[0] = calloc(size, sizeof(float));
    ring->planes[1] = calloc(size, sizeof(float));
    ring->mask = size - 1;
    ring->target = target;
    return ring;
}

uint32_t audio_ring_level(AudioRing *ring) {
    uint64_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    return (uint32_t)(head - later(atomic_load_explicit(&ring->tail, memory_order_acquire),
                               atomic_load_explicit(&ring->floor, memory_order_relaxed)));
}

uint32_t audio_ring_write(AudioRing *ring, const float *left, const float *right, uint32_t count) {
    uint64_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    // Dropped frames are free even if the reader has stopped before them: it skips them before
    // it reads. It could still be copying some of them only if the writer went around the ring
    // during one copy, a few microseconds, which takes over 60 packets.
    uint32_t space = ring->mask + 1 - audio_ring_level(ring);
    if (count > space) {
        count = space;
    }
    for (uint32_t done = 0; done < count;) {
        uint32_t at = (head + done) & ring->mask;
        uint32_t n = count - done < ring->mask + 1 - at ? count - done : ring->mask + 1 - at;
        if (left) {
            memcpy(ring->planes[0] + at, left + done, n * sizeof(float));
            memcpy(ring->planes[1] + at, right + done, n * sizeof(float));
        } else {
            memset(ring->planes[0] + at, 0, n * sizeof(float));
            memset(ring->planes[1] + at, 0, n * sizeof(float));
        }
        done += n;
    }
    atomic_store_explicit(&ring->head, head + count, memory_order_release);
    return count;
}

uint32_t audio_ring_drop(AudioRing *ring, uint32_t max) {
    uint32_t level = audio_ring_level(ring);
    if (level <= max) {
        return 0;
    }
    uint64_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    atomic_store_explicit(&ring->floor, head - max, memory_order_release);
    return level - max;
}

uint32_t audio_ring_take_underflow(AudioRing *ring) {
    return atomic_exchange_explicit(&ring->underflow, 0, memory_order_relaxed);
}

bool audio_ring_played(AudioRing *ring) {
    return atomic_load_explicit(&ring->played, memory_order_relaxed);
}

// Plays silence until the ring first holds its target, then the frames in order, and silence
// when they run out. The late frames are kept, as in scrcpy: the writer's clock compensation
// brings the level back.
OSStatus audio_ring_render(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                           UInt32 bus, UInt32 frames, AudioBufferList *data) CA_REALTIME_API {
    AudioRing *ring = refCon;
    // The floor before the head: a floor is never past the head written before it.
    uint64_t floor = atomic_load_explicit(&ring->floor, memory_order_acquire);
    uint64_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    uint64_t tail = later(atomic_load_explicit(&ring->tail, memory_order_relaxed), floor);
    uint32_t count = 0;
    if (atomic_load_explicit(&ring->played, memory_order_relaxed) || head - tail >= ring->target) {
        count = frames < head - tail ? frames : (uint32_t)(head - tail);
        for (uint32_t done = 0; done < count;) {
            uint32_t at = (tail + done) & ring->mask;
            uint32_t n = count - done < ring->mask + 1 - at ? count - done : ring->mask + 1 - at;
            for (int c = 0; c < 2; c++) {
                memcpy((float *)data->mBuffers[c].mData + done, ring->planes[c] + at, n * sizeof(float));
            }
            done += n;
        }
        if (count < frames) {
            atomic_fetch_add_explicit(&ring->underflow, frames - count, memory_order_relaxed);
        }
        atomic_store_explicit(&ring->played, true, memory_order_relaxed);
    }
    for (int c = 0; c < 2; c++) {
        memset((float *)data->mBuffers[c].mData + count, 0, (frames - count) * sizeof(float));
    }
    atomic_store_explicit(&ring->tail, tail + count, memory_order_release);
    return noErr;
}
