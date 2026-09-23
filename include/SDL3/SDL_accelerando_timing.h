/* Accelerando local diagnostic extension; not an upstream SDL API. */
#ifndef SDL_accelerando_timing_h_
#define SDL_accelerando_timing_h_

#include <SDL3/SDL_gpu.h>

#define SDL_PROP_GPU_ACCELERANDO_TIMING_POINTER "SDL.gpu.accelerando.timing.v1"
#define SDL_ACCELERANDO_GPU_TIMING_VERSION 1

typedef enum SDL_AccelerandoGPUTimingPhase
{
    SDL_ACCELERANDO_GPU_FENCE_WAIT,
    SDL_ACCELERANDO_GPU_FENCE_CLEANUP,
    SDL_ACCELERANDO_GPU_NEXT_DRAWABLE,
    SDL_ACCELERANDO_GPU_ACQUIRE_SWAPCHAIN,
    SDL_ACCELERANDO_GPU_SUBMIT_LOCK,
    SDL_ACCELERANDO_GPU_PRESENT_DRAWABLE,
    SDL_ACCELERANDO_GPU_COMMIT,
    SDL_ACCELERANDO_GPU_SUBMIT_CLEANUP,
    SDL_ACCELERANDO_GPU_SUBMIT,
    SDL_ACCELERANDO_GPU_COMMAND_FLUSH,
    SDL_ACCELERANDO_GPU_ACQUIRE_COMMAND_BUFFER,
    SDL_ACCELERANDO_GPU_TIMING_PHASE_COUNT
} SDL_AccelerandoGPUTimingPhase;

typedef struct SDL_AccelerandoGPUTimingSample
{
    Uint64 sequence;
    Uint64 begin_ns;
    Uint64 end_ns;
    Uint64 duration_ns[SDL_ACCELERANDO_GPU_TIMING_PHASE_COUNT];
    Uint32 calls[SDL_ACCELERANDO_GPU_TIMING_PHASE_COUNT];
} SDL_AccelerandoGPUTimingSample;

/*
 * Available only on the Metal device when ACCEL_METAL_DIAGNOSTICS=1 was set
 * before device creation. Cache this property once, along with its device.
 * The API and device are owned by SDL; do not release them. All calls must use
 * that device on the thread which created it. Other threads are not sampled.
 * begin() resets a fixed POD sample; read() finishes and copies it. Neither
 * performs logging, heap allocation, locking, or a property lookup. Begin just
 * before SDL_RenderPresent and read just after it for present-only attribution,
 * or begin earlier to include command flushes during scene rendering.
 *
 * Durations are CPU wall time in SDL_GetTicksNS units, not GPU execution time.
 * ACQUIRE_SWAPCHAIN includes FENCE_WAIT/FENCE_CLEANUP/NEXT_DRAWABLE; SUBMIT
 * includes SUBMIT_LOCK/PRESENT_DRAWABLE/COMMIT/SUBMIT_CLEANUP. Do not sum nested
 * counters. Calls distinguish a zero duration from a phase not executed.
 * ACCEL_METAL_SIGNPOSTS=1 additionally emits optional Instruments intervals.
 * Keep signposts disabled in allocation/pacing measurements.
 */
typedef struct SDL_AccelerandoGPUTimingAPI
{
    Uint32 version;
    Uint32 sample_size;
    bool (SDLCALL *begin)(SDL_GPUDevice *device);
    bool (SDLCALL *read)(SDL_GPUDevice *device, SDL_AccelerandoGPUTimingSample *sample);
    /* Used internally by SDL_Renderer's GPU command queue instrumentation. */
    bool (SDLCALL *is_active)(SDL_GPUDevice *device);
    void (SDLCALL *add_duration)(SDL_GPUDevice *device, SDL_AccelerandoGPUTimingPhase phase, Uint64 duration_ns);
} SDL_AccelerandoGPUTimingAPI;

#endif
