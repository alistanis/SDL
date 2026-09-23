/*
  Simple DirectMedia Layer
  Copyright (C) 1997-2026 Sam Lantinga <slouken@libsdl.org>

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.
*/

#include "SDL_internal.h"

#ifdef SDL_GPU_METAL

#include <Metal/Metal.h>
#include <QuartzCore/CoreAnimation.h>
#include <stdatomic.h>
#include <float.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <os/signpost.h>
#include <SDL3/SDL_accelerando_timing.h>

#include "../SDL_sysgpu.h"

// Defines

#define METAL_FIRST_VERTEX_BUFFER_SLOT 14
#define WINDOW_PROPERTY_DATA           "SDL.internal.gpu.metal.data"
#define SDL_GPU_SHADERSTAGE_COMPUTE    2

// Optional investigation counters: 128 render passes, four timestamps each.
// The 4 KiB timestamp buffer stays below Metal's 32 KiB counter-buffer limit.
#define AFTERGLOW_MAX_TIMED_PASSES 128
#define AFTERGLOW_MAX_PASS_SHADERS 8
typedef struct AfterglowMetalPassRecord
{
    Uint32 width, height, drawCount, shaderCount;
    Uint64 vertices;
    Uint32 shaderHashes[AFTERGLOW_MAX_PASS_SHADERS];
    Uint32 shaderDraws[AFTERGLOW_MAX_PASS_SHADERS];
} AfterglowMetalPassRecord;

// This object has its own lifetime, independent of SDL's recycled wrappers.
// Its recording metadata is immutable after commit until the callback releases
// the lease. An early wrapper reuse skips sampling instead of overwriting it.
@interface AfterglowMetalPassSamples : NSObject {
@public
    id<MTLCounterSampleBuffer> buffer;
    SDL_AtomicInt busy;
    Uint32 passCount, droppedPasses;
    Uint64 acquisition, cpuStart, gpuStart;
    AfterglowMetalPassRecord passes[AFTERGLOW_MAX_TIMED_PASSES];
}
@end
@implementation AfterglowMetalPassSamples
@end

// AFTERGLOW OPTIONAL PRESENTATION RECORDER BEGIN
// Native presented handlers may outlive SDL's device/window/fence wrappers.
// Each block retains this independent owner; it owns no native drawables.
#define AFTERGLOW_PRESENTATION_CAPACITY 131072U
_Static_assert(ATOMIC_INT_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2,
               "Presentation recording requires lock-free integer publication");
#define AFTERGLOW_PRESENTATION_SUBMITTED 1U
#define AFTERGLOW_PRESENTATION_COMPLETED 2U
#define AFTERGLOW_PRESENTATION_NIL 4U

typedef struct AfterglowMetalPresentationRecord
{
    Uint64 submission, layer, drawableID;
    Uint64 requestBeforeNS, requestAfterNS, callbackDrawableID;
    double requestHostTime, presentedHostTime, callbackHostTime;
    _Atomic(Uint32) flags;
} AfterglowMetalPresentationRecord;

@interface AfterglowMetalPresentations : NSObject {
@public
    AfterglowMetalPresentationRecord *records;
    char *outputPath;
    _Atomic(Uint64) reserved, overflow, nilDrawables;
    _Atomic(Uint32) completed;
    _Atomic(bool) exported;
    Uint64 startBeforeNS, startAfterNS;
    double startHostTime;
}
- (instancetype)initWithPath:(const char *)path;
@end

@implementation AfterglowMetalPresentations
- (instancetype)initWithPath:(const char *)path
{
    self = [super init];
    if (self) {
        outputPath = SDL_strdup(path);
        records = SDL_calloc(AFTERGLOW_PRESENTATION_CAPACITY, sizeof(*records));
        if (!outputPath || !records) return nil;
        atomic_init(&reserved, 0);
        atomic_init(&completed, 0);
        atomic_init(&overflow, 0);
        atomic_init(&nilDrawables, 0);
        atomic_init(&exported, false);
        for (Uint32 i = 0; i < AFTERGLOW_PRESENTATION_CAPACITY; ++i) {
            atomic_init(&records[i].flags, 0);
        }
        startBeforeNS = SDL_GetTicksNS();
        startHostTime = CACurrentMediaTime();
        startAfterNS = SDL_GetTicksNS();
    }
    return self;
}
- (void)dealloc
{
    SDL_free(records);
    SDL_free(outputPath);
}
@end

static AfterglowMetalPresentations *METAL_INTERNAL_AfterglowCreatePresentations(void)
{
    const char *path = SDL_getenv("AFTERGLOW_METAL_PRESENTATIONS");
    if (!path || !*path) return nil;
    if (@available(macOS 10.15.4, iOS 10.3, tvOS 10.3, *)) {
        AfterglowMetalPresentations *owner = [[AfterglowMetalPresentations alloc] initWithPath:path];
        if (!owner) {
            SDL_LogError(SDL_LOG_CATEGORY_GPU, "AfterglowMetal/presentations allocation failed");
        } else {
            SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
                "AfterglowMetal/presentations enabled path=%s capacity=%u bytes=%zu",
                path, AFTERGLOW_PRESENTATION_CAPACITY,
                AFTERGLOW_PRESENTATION_CAPACITY * sizeof(*owner->records));
        }
        return owner;
    }
    SDL_LogError(SDL_LOG_CATEGORY_GPU, "AfterglowMetal/presentations unsupported OS");
    return nil;
}

static Uint32 METAL_INTERNAL_AfterglowReservePresentation(
    AfterglowMetalPresentations *owner, Uint64 submission, Uint64 layer,
    Uint64 drawableID, bool nilDrawable)
{
    const Uint64 attempt = atomic_fetch_add_explicit(&owner->reserved, 1, memory_order_relaxed);
    if (nilDrawable) atomic_fetch_add_explicit(&owner->nilDrawables, 1, memory_order_relaxed);
    if (attempt >= AFTERGLOW_PRESENTATION_CAPACITY) {
        atomic_fetch_add_explicit(&owner->overflow, 1, memory_order_relaxed);
        return UINT32_MAX;
    }
    const Uint32 slot = (Uint32)attempt;
    AfterglowMetalPresentationRecord *record = &owner->records[slot];
    record->submission = submission;
    record->layer = layer;
    record->drawableID = drawableID;
    record->requestBeforeNS = SDL_GetTicksNS();
    record->requestHostTime = CACurrentMediaTime();
    record->requestAfterNS = SDL_GetTicksNS();
    atomic_store_explicit(&record->flags, AFTERGLOW_PRESENTATION_SUBMITTED |
        (nilDrawable ? AFTERGLOW_PRESENTATION_NIL : 0U), memory_order_release);
    return slot;
}

static void METAL_INTERNAL_AfterglowCompletePresentation(
    AfterglowMetalPresentations *owner, Uint32 slot, double presentedTime,
    Uint64 drawableID)
{
    AfterglowMetalPresentationRecord *record = &owner->records[slot];
    record->callbackHostTime = CACurrentMediaTime();
    record->callbackDrawableID = drawableID;
    record->presentedHostTime = presentedTime;
    atomic_store_explicit(&record->flags, AFTERGLOW_PRESENTATION_SUBMITTED |
        AFTERGLOW_PRESENTATION_COMPLETED, memory_order_release);
    atomic_fetch_add_explicit(&owner->completed, 1, memory_order_relaxed);
}

static void METAL_INTERNAL_AfterglowRecordPresentation(
    AfterglowMetalPresentations *owner, id<MTLDrawable> drawable,
    Uint64 submission, Uint64 layer)
{
    if (@available(macOS 10.15.4, iOS 10.3, tvOS 10.3, *)) {
        const Uint32 slot = METAL_INTERNAL_AfterglowReservePresentation(
            owner, submission, layer, drawable ? drawable.drawableID : 0, drawable == nil);
        if (slot == UINT32_MAX || !drawable) return;
        [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
            METAL_INTERNAL_AfterglowCompletePresentation(
                owner, slot, presented.presentedTime, presented.drawableID);
        }];
    }
}

static void METAL_INTERNAL_AfterglowWriteJSONString(FILE *file, const char *value)
{
    fputc('"', file);
    if (value) {
        for (const unsigned char *p = (const unsigned char *)value; *p; ++p) {
            if (*p == '"' || *p == '\\') fprintf(file, "\\%c", *p);
            else if (*p < 0x20) fprintf(file, "\\u%04x", *p);
            else fputc(*p, file);
        }
    }
    fputc('"', file);
}

static void METAL_INTERNAL_AfterglowExportPresentations(
    AfterglowMetalPresentations *owner, Uint64 captureEpochNS, const char *capturePath)
{
    if (atomic_exchange_explicit(&owner->exported, true, memory_order_acq_rel)) return;
    const Uint64 attempts = atomic_load_explicit(&owner->reserved, memory_order_acquire);
    const Uint32 count = (Uint32)SDL_min(attempts, (Uint64)AFTERGLOW_PRESENTATION_CAPACITY);
    const Uint32 completedAtStart = atomic_load_explicit(&owner->completed, memory_order_acquire);
    const Uint64 endBeforeNS = SDL_GetTicksNS();
    const double endHostTime = CACurrentMediaTime();
    const Uint64 endAfterNS = SDL_GetTicksNS();
    const int descriptor = open(owner->outputPath, O_WRONLY | O_CREAT | O_EXCL, 0600);
    FILE *file = descriptor < 0 ? NULL : fdopen(descriptor, "w");
    if (!file) {
        const int failure = errno;
        if (descriptor >= 0) close(descriptor);
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "AfterglowMetal/presentations export failed path=%s errno=%d",
                     owner->outputPath, failure);
        return;
    }
    fprintf(file, "{\"type\":\"metadata\",\"schema\":1,\"capacity\":%u,\"record_bytes\":%zu,"
        "\"capture_epoch_sdl_ns\":%" SDL_PRIu64 ",\"capture_path\":",
        AFTERGLOW_PRESENTATION_CAPACITY, sizeof(*owner->records), captureEpochNS);
    METAL_INTERNAL_AfterglowWriteJSONString(file, capturePath);
    fprintf(file, ",\"start_before_sdl_ns\":%" SDL_PRIu64 ",\"start_host_s\":%.9f,"
        "\"start_after_sdl_ns\":%" SDL_PRIu64 ",\"end_before_sdl_ns\":%" SDL_PRIu64
        ",\"end_host_s\":%.9f,\"end_after_sdl_ns\":%" SDL_PRIu64 "}\n",
        owner->startBeforeNS, owner->startHostTime, owner->startAfterNS,
        endBeforeNS, endHostTime, endAfterNS);
    Uint32 completedSnapshot = 0, positive = 0, zero = 0, invalid = 0, nilCount = 0;
    for (Uint32 i = 0; i < count; ++i) {
        const AfterglowMetalPresentationRecord *record = &owner->records[i];
        const Uint32 flags = atomic_load_explicit(&record->flags, memory_order_acquire);
        // Callback-owned fields are read only after their release publication.
        const bool ready = (flags & AFTERGLOW_PRESENTATION_COMPLETED) != 0;
        const bool submitted = (flags & AFTERGLOW_PRESENTATION_SUBMITTED) != 0;
        const bool nilDrawable = (flags & AFTERGLOW_PRESENTATION_NIL) != 0;
        const double time = ready ? record->presentedHostTime : 0.0;
        const bool validTime = time >= 0.0 && time <= DBL_MAX;
        const char *status = !submitted ? "reserved" : nilDrawable ? "nil_drawable" :
            !ready ? "pending" : !validTime ? "invalid" : time == 0.0 ? "zero" : "presented";
        completedSnapshot += ready;
        nilCount += nilDrawable;
        positive += ready && validTime && time > 0.0;
        zero += ready && time == 0.0;
        invalid += ready && !validTime;
        fprintf(file, "{\"type\":\"presentation\",\"slot\":%u,\"submission\":%" SDL_PRIu64
            ",\"layer\":%" SDL_PRIu64 ",\"drawable_id\":%" SDL_PRIu64
            ",\"request_before_sdl_ns\":%" SDL_PRIu64 ",\"request_host_s\":%.9f,"
            "\"request_after_sdl_ns\":%" SDL_PRIu64 ",\"callback_host_s\":%.9f"
            ",\"callback_drawable_id\":%" SDL_PRIu64 ",\"presented_host_s\":",
            i, submitted ? record->submission : 0, submitted ? record->layer : 0,
            submitted ? record->drawableID : 0, submitted ? record->requestBeforeNS : 0,
            submitted ? record->requestHostTime : 0.0, submitted ? record->requestAfterNS : 0,
            ready ? record->callbackHostTime : 0.0, ready ? record->callbackDrawableID : 0);
        if (ready && validTime) fprintf(file, "%.9f", time); else fputs("null", file);
        fprintf(file, ",\"status\":\"%s\"}\n", status);
    }
    fprintf(file, "{\"type\":\"footer\",\"reserved\":%" SDL_PRIu64 ",\"records\":%u,"
        "\"completed_snapshot\":%u,\"positive\":%u,\"zero\":%u,\"invalid\":%u,\"nil\":%u,"
        "\"missing\":%u,\"overflow\":%" SDL_PRIu64 ",\"completed_at_export_start\":%u,"
        "\"completed_at_export_end\":%u,\"nil_total\":%" SDL_PRIu64 "}\n",
        attempts, count, completedSnapshot, positive, zero, invalid, nilCount,
        count - completedSnapshot - nilCount,
        atomic_load_explicit(&owner->overflow, memory_order_acquire), completedAtStart,
        atomic_load_explicit(&owner->completed, memory_order_acquire),
        atomic_load_explicit(&owner->nilDrawables, memory_order_acquire));
    const bool writeFailed = ferror(file) != 0;
    const bool closeFailed = fclose(file) != 0;
    SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
        "AfterglowMetal/presentations exported path=%s records=%u complete=%u missing=%u overflow=%" SDL_PRIu64 " success=%d",
        owner->outputPath, count, completedSnapshot, count - completedSnapshot - nilCount,
        atomic_load_explicit(&owner->overflow, memory_order_relaxed), !writeFailed && !closeFailed);
}
// AFTERGLOW OPTIONAL PRESENTATION RECORDER END

// Keep the resource set used by a typical command buffer in the command
// buffer itself. Metal command buffers can remain in flight for several
// frames, so growing these arrays lazily makes otherwise allocation-free
// rendering depend on when a pooled command buffer is first used. Larger
// workloads retain the existing dynamically growing fallback.
#define METAL_INLINE_USED_BUFFER_CAPACITY         64
#define METAL_INLINE_USED_TEXTURE_CAPACITY        64
#define METAL_INLINE_USED_UNIFORM_BUFFER_CAPACITY 32
// GPU render submission cycles its retained vertex upload/destination
// buffers whenever an earlier command buffer can still reference them. Keep
// the bounded wrapper/pointer ring in the container itself: allocating one
// MetalBuffer wrapper at each new high-water mark otherwise leaks SDL
// calloc/realloc calls into the first live frames after loading. Native Metal
// objects are still created lazily in these prepared slots, so static asset
// buffers do not multiply their VRAM footprint.
#define METAL_INLINE_CYCLED_BUFFER_CAPACITY        16

#define TRACK_RESOURCE(resource, type, array, inline_array, count, capacity) \
    do {                                                                       \
        Uint32 i;                                                              \
                                                                               \
        for (i = 0; i < commandBuffer->count; i += 1) {                        \
            if (commandBuffer->array[i] == (resource)) {                       \
                return;                                                        \
            }                                                                  \
        }                                                                      \
                                                                               \
        if (commandBuffer->count == commandBuffer->capacity) {                 \
            if (commandBuffer->capacity > SDL_MAX_UINT32 / 2 ||                \
                (size_t)(commandBuffer->capacity * 2) >                        \
                    SDL_SIZE_MAX / sizeof(type)) {                             \
                SDL_OutOfMemory();                                             \
                SDL_AtomicIncRef(&(resource)->referenceCount);                 \
                return;                                                        \
            }                                                                  \
            const Uint32 newCapacity = commandBuffer->capacity * 2;            \
            type *newArray;                                                    \
            if (commandBuffer->array == commandBuffer->inline_array) {         \
                newArray = (type *)SDL_malloc(newCapacity * sizeof(type));     \
                if (newArray) {                                                \
                    SDL_memcpy(                                                \
                        newArray,                                              \
                        commandBuffer->inline_array,                           \
                        commandBuffer->count * sizeof(type));                  \
                }                                                              \
            } else {                                                           \
                newArray = (type *)SDL_realloc(                                \
                    commandBuffer->array,                                      \
                    newCapacity * sizeof(type));                               \
            }                                                                  \
            if (!newArray) {                                                   \
                /* Retain forever rather than permit a GPU use-after-free. */  \
                SDL_AtomicIncRef(&(resource)->referenceCount);                 \
                return;                                                        \
            }                                                                  \
            commandBuffer->array = newArray;                                   \
            commandBuffer->capacity = newCapacity;                             \
        }                                                                      \
        commandBuffer->array[commandBuffer->count] = (resource);               \
        commandBuffer->count += 1;                                             \
        SDL_AtomicIncRef(&(resource)->referenceCount);                         \
    } while (0)

#define SET_ERROR_AND_RETURN(fmt, msg, ret)               \
    do {                                                  \
        if (renderer->debugMode) {                        \
            SDL_LogError(SDL_LOG_CATEGORY_GPU, fmt, msg); \
        }                                                 \
        SDL_SetError(fmt, msg);                           \
        return ret;                                       \
    } while (0)

#define SET_STRING_ERROR_AND_RETURN(msg, ret) SET_ERROR_AND_RETURN("%s", msg, ret)

// Blit Shaders

#include "Metal_Blit.h"

// Forward Declarations

static bool METAL_Wait(SDL_GPURenderer *driverData);
static void METAL_ReleaseWindow(
    SDL_GPURenderer *driverData,
    SDL_Window *window);
static void METAL_INTERNAL_DestroyBlitResources(SDL_GPURenderer *driverData);

// Conversions

#define RETURN_FORMAT(availability, format) \
    if (availability) { return format; } else { return MTLPixelFormatInvalid; }

static MTLPixelFormat SDLToMetal_TextureFormat(SDL_GPUTextureFormat format)
{
    switch (format) {
        case SDL_GPU_TEXTUREFORMAT_INVALID: return MTLPixelFormatInvalid;
        case SDL_GPU_TEXTUREFORMAT_A8_UNORM: return MTLPixelFormatA8Unorm;
        case SDL_GPU_TEXTUREFORMAT_R8_UNORM: return MTLPixelFormatR8Unorm;
        case SDL_GPU_TEXTUREFORMAT_R8G8_UNORM: return MTLPixelFormatRG8Unorm;
        case SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM: return MTLPixelFormatRGBA8Unorm;
        case SDL_GPU_TEXTUREFORMAT_R16_UNORM: return MTLPixelFormatR16Unorm;
        case SDL_GPU_TEXTUREFORMAT_R16G16_UNORM: return MTLPixelFormatRG16Unorm;
        case SDL_GPU_TEXTUREFORMAT_R16G16B16A16_UNORM: return MTLPixelFormatRGBA16Unorm;
        case SDL_GPU_TEXTUREFORMAT_R10G10B10A2_UNORM: return MTLPixelFormatRGB10A2Unorm;
        case SDL_GPU_TEXTUREFORMAT_B5G6R5_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatB5G6R5Unorm);
        case SDL_GPU_TEXTUREFORMAT_B5G5R5A1_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatBGR5A1Unorm);
        case SDL_GPU_TEXTUREFORMAT_B4G4R4A4_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatABGR4Unorm);
        case SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM: return MTLPixelFormatBGRA8Unorm;
        case SDL_GPU_TEXTUREFORMAT_BC1_RGBA_UNORM: RETURN_FORMAT(@available(iOS 16.4, tvOS 16.4, *), MTLPixelFormatBC1_RGBA);
        case SDL_GPU_TEXTUREFORMAT_BC2_RGBA_UNORM: RETURN_FORMAT(@available(iOS 16.4, tvOS 16.4, *), MTLPixelFormatBC2_RGBA);
        case SDL_GPU_TEXTUREFORMAT_BC3_RGBA_UNORM: RETURN_FORMAT(@available(iOS 16.4, tvOS 16.4, *), MTLPixelFormatBC3_RGBA);
        case SDL_GPU_TEXTUREFORMAT_BC4_R_UNORM: RETURN_FORMAT(@available(iOS 16.4, tvOS 16.4, *), MTLPixelFormatBC4_RUnorm);
        case SDL_GPU_TEXTUREFORMAT_BC5_RG_UNORM: RETURN_FORMAT(@available(iOS 16.4, tvOS 16.4, *), MTLPixelFormatBC5_RGUnorm);
        case SDL_GPU_TEXTUREFORMAT_BC7_RGBA_UNORM: RETURN_FORMAT(@available(iOS 16.4, tvOS 16.4, *), MTLPixelFormatBC7_RGBAUnorm);
        case SDL_GPU_TEXTUREFORMAT_BC6H_RGB_FLOAT: RETURN_FORMAT(@available(iOS 16.4, tvOS 16.4, *), MTLPixelFormatBC6H_RGBFloat);
        case SDL_GPU_TEXTUREFORMAT_BC6H_RGB_UFLOAT: RETURN_FORMAT(@available(iOS 16.4, tvOS 16.4, *), MTLPixelFormatBC6H_RGBUfloat);
        case SDL_GPU_TEXTUREFORMAT_R8_SNORM: return MTLPixelFormatR8Snorm;
        case SDL_GPU_TEXTUREFORMAT_R8G8_SNORM: return MTLPixelFormatRG8Snorm;
        case SDL_GPU_TEXTUREFORMAT_R8G8B8A8_SNORM: return MTLPixelFormatRGBA8Snorm;
        case SDL_GPU_TEXTUREFORMAT_R16_SNORM: return MTLPixelFormatR16Snorm;
        case SDL_GPU_TEXTUREFORMAT_R16G16_SNORM: return MTLPixelFormatRG16Snorm;
        case SDL_GPU_TEXTUREFORMAT_R16G16B16A16_SNORM: return MTLPixelFormatRGBA16Snorm;
        case SDL_GPU_TEXTUREFORMAT_R16_FLOAT: return MTLPixelFormatR16Float;
        case SDL_GPU_TEXTUREFORMAT_R16G16_FLOAT: return MTLPixelFormatRG16Float;
        case SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT: return MTLPixelFormatRGBA16Float;
        case SDL_GPU_TEXTUREFORMAT_R32_FLOAT: return MTLPixelFormatR32Float;
        case SDL_GPU_TEXTUREFORMAT_R32G32_FLOAT: return MTLPixelFormatRG32Float;
        case SDL_GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT: return MTLPixelFormatRGBA32Float;
        case SDL_GPU_TEXTUREFORMAT_R11G11B10_UFLOAT: return MTLPixelFormatRG11B10Float;
        case SDL_GPU_TEXTUREFORMAT_R8_UINT: return MTLPixelFormatR8Uint;
        case SDL_GPU_TEXTUREFORMAT_R8G8_UINT: return MTLPixelFormatRG8Uint;
        case SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UINT: return MTLPixelFormatRGBA8Uint;
        case SDL_GPU_TEXTUREFORMAT_R16_UINT: return MTLPixelFormatR16Uint;
        case SDL_GPU_TEXTUREFORMAT_R16G16_UINT: return MTLPixelFormatRG16Uint;
        case SDL_GPU_TEXTUREFORMAT_R16G16B16A16_UINT: return MTLPixelFormatRGBA16Uint;
        case SDL_GPU_TEXTUREFORMAT_R32_UINT: return MTLPixelFormatR32Uint;
        case SDL_GPU_TEXTUREFORMAT_R32G32_UINT: return MTLPixelFormatRG32Uint;
        case SDL_GPU_TEXTUREFORMAT_R32G32B32A32_UINT: return MTLPixelFormatRGBA32Uint;
        case SDL_GPU_TEXTUREFORMAT_R8_INT: return MTLPixelFormatR8Sint;
        case SDL_GPU_TEXTUREFORMAT_R8G8_INT: return MTLPixelFormatRG8Sint;
        case SDL_GPU_TEXTUREFORMAT_R8G8B8A8_INT: return MTLPixelFormatRGBA8Sint;
        case SDL_GPU_TEXTUREFORMAT_R16_INT: return MTLPixelFormatR16Sint;
        case SDL_GPU_TEXTUREFORMAT_R16G16_INT: return MTLPixelFormatRG16Sint;
        case SDL_GPU_TEXTUREFORMAT_R16G16B16A16_INT: return MTLPixelFormatRGBA16Sint;
        case SDL_GPU_TEXTUREFORMAT_R32_INT: return MTLPixelFormatR32Sint;
        case SDL_GPU_TEXTUREFORMAT_R32G32_INT: return MTLPixelFormatRG32Sint;
        case SDL_GPU_TEXTUREFORMAT_R32G32B32A32_INT: return MTLPixelFormatRGBA32Sint;
        case SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB: return MTLPixelFormatRGBA8Unorm_sRGB;
        case SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB: return MTLPixelFormatBGRA8Unorm_sRGB;
        case SDL_GPU_TEXTUREFORMAT_BC1_RGBA_UNORM_SRGB: RETURN_FORMAT(@available(iOS 16.4, tvOS 16.4, *), MTLPixelFormatBC1_RGBA_sRGB);
        case SDL_GPU_TEXTUREFORMAT_BC2_RGBA_UNORM_SRGB: RETURN_FORMAT(@available(iOS 16.4, tvOS 16.4, *), MTLPixelFormatBC2_RGBA_sRGB);
        case SDL_GPU_TEXTUREFORMAT_BC3_RGBA_UNORM_SRGB: RETURN_FORMAT(@available(iOS 16.4, tvOS 16.4, *), MTLPixelFormatBC3_RGBA_sRGB);
        case SDL_GPU_TEXTUREFORMAT_BC7_RGBA_UNORM_SRGB: RETURN_FORMAT(@available(iOS 16.4, tvOS 16.4, *), MTLPixelFormatBC7_RGBAUnorm_sRGB);
        case SDL_GPU_TEXTUREFORMAT_D16_UNORM: RETURN_FORMAT(@available(iOS 13.0, tvOS 13.0, *), MTLPixelFormatDepth16Unorm);
        case SDL_GPU_TEXTUREFORMAT_D24_UNORM:
#ifdef SDL_PLATFORM_MACOS
            return MTLPixelFormatDepth24Unorm_Stencil8;
#else
            return MTLPixelFormatInvalid;
#endif
        case SDL_GPU_TEXTUREFORMAT_D32_FLOAT: return MTLPixelFormatDepth32Float;
        case SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT:
#ifdef SDL_PLATFORM_MACOS
            return MTLPixelFormatDepth24Unorm_Stencil8;
#else
            return MTLPixelFormatInvalid;
#endif
        case SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT: return MTLPixelFormatDepth32Float_Stencil8;
        case SDL_GPU_TEXTUREFORMAT_ASTC_4x4_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_4x4_LDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_5x4_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_5x4_LDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_5x5_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_5x5_LDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_6x5_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_6x5_LDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_6x6_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_6x6_LDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x5_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_8x5_LDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x6_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_8x6_LDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x8_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_8x8_LDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x5_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_10x5_LDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x6_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_10x6_LDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x8_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_10x8_LDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x10_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_10x10_LDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_12x10_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_12x10_LDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_12x12_UNORM: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_12x12_LDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_4x4_UNORM_SRGB: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_4x4_sRGB);
        case SDL_GPU_TEXTUREFORMAT_ASTC_5x4_UNORM_SRGB: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_5x4_sRGB);
        case SDL_GPU_TEXTUREFORMAT_ASTC_5x5_UNORM_SRGB: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_5x5_sRGB);
        case SDL_GPU_TEXTUREFORMAT_ASTC_6x5_UNORM_SRGB: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_6x5_sRGB);
        case SDL_GPU_TEXTUREFORMAT_ASTC_6x6_UNORM_SRGB: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_6x6_sRGB);
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x5_UNORM_SRGB: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_8x5_sRGB);
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x6_UNORM_SRGB: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_8x6_sRGB);
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x8_UNORM_SRGB: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_8x8_sRGB);
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x5_UNORM_SRGB: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_10x5_sRGB);
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x6_UNORM_SRGB: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_10x6_sRGB);
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x8_UNORM_SRGB: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_10x8_sRGB);
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x10_UNORM_SRGB: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_10x10_sRGB);
        case SDL_GPU_TEXTUREFORMAT_ASTC_12x10_UNORM_SRGB: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_12x10_sRGB);
        case SDL_GPU_TEXTUREFORMAT_ASTC_12x12_UNORM_SRGB: RETURN_FORMAT(@available(macOS 11.0, *), MTLPixelFormatASTC_12x12_sRGB);
        case SDL_GPU_TEXTUREFORMAT_ASTC_4x4_FLOAT: RETURN_FORMAT(@available(macOS 11.0, iOS 13.0, tvOS 16.0, *), MTLPixelFormatASTC_4x4_HDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_5x4_FLOAT: RETURN_FORMAT(@available(macOS 11.0, iOS 13.0, tvOS 16.0, *), MTLPixelFormatASTC_5x4_HDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_5x5_FLOAT: RETURN_FORMAT(@available(macOS 11.0, iOS 13.0, tvOS 16.0, *), MTLPixelFormatASTC_5x5_HDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_6x5_FLOAT: RETURN_FORMAT(@available(macOS 11.0, iOS 13.0, tvOS 16.0, *), MTLPixelFormatASTC_6x5_HDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_6x6_FLOAT: RETURN_FORMAT(@available(macOS 11.0, iOS 13.0, tvOS 16.0, *), MTLPixelFormatASTC_6x6_HDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x5_FLOAT: RETURN_FORMAT(@available(macOS 11.0, iOS 13.0, tvOS 16.0, *), MTLPixelFormatASTC_8x5_HDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x6_FLOAT: RETURN_FORMAT(@available(macOS 11.0, iOS 13.0, tvOS 16.0, *), MTLPixelFormatASTC_8x6_HDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x8_FLOAT: RETURN_FORMAT(@available(macOS 11.0, iOS 13.0, tvOS 16.0, *), MTLPixelFormatASTC_8x8_HDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x5_FLOAT: RETURN_FORMAT(@available(macOS 11.0, iOS 13.0, tvOS 16.0, *), MTLPixelFormatASTC_10x5_HDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x6_FLOAT: RETURN_FORMAT(@available(macOS 11.0, iOS 13.0, tvOS 16.0, *), MTLPixelFormatASTC_10x6_HDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x8_FLOAT: RETURN_FORMAT(@available(macOS 11.0, iOS 13.0, tvOS 16.0, *), MTLPixelFormatASTC_10x8_HDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x10_FLOAT: RETURN_FORMAT(@available(macOS 11.0, iOS 13.0, tvOS 16.0, *), MTLPixelFormatASTC_10x10_HDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_12x10_FLOAT: RETURN_FORMAT(@available(macOS 11.0, iOS 13.0, tvOS 16.0, *), MTLPixelFormatASTC_12x10_HDR);
        case SDL_GPU_TEXTUREFORMAT_ASTC_12x12_FLOAT: RETURN_FORMAT(@available(macOS 11.0, iOS 13.0, tvOS 16.0, *), MTLPixelFormatASTC_12x12_HDR);
    }
}

#undef RETURN_FORMAT

static MTLVertexFormat SDLToMetal_VertexFormat[] = {
    MTLVertexFormatInvalid,           // INVALID
    MTLVertexFormatInt,               // INT
    MTLVertexFormatInt2,              // INT2
    MTLVertexFormatInt3,              // INT3
    MTLVertexFormatInt4,              // INT4
    MTLVertexFormatUInt,              // UINT
    MTLVertexFormatUInt2,             // UINT2
    MTLVertexFormatUInt3,             // UINT3
    MTLVertexFormatUInt4,             // UINT4
    MTLVertexFormatFloat,             // FLOAT
    MTLVertexFormatFloat2,            // FLOAT2
    MTLVertexFormatFloat3,            // FLOAT3
    MTLVertexFormatFloat4,            // FLOAT4
    MTLVertexFormatChar2,             // BYTE2
    MTLVertexFormatChar4,             // BYTE4
    MTLVertexFormatUChar2,            // UBYTE2
    MTLVertexFormatUChar4,            // UBYTE4
    MTLVertexFormatChar2Normalized,   // BYTE2_NORM
    MTLVertexFormatChar4Normalized,   // BYTE4_NORM
    MTLVertexFormatUChar2Normalized,  // UBYTE2_NORM
    MTLVertexFormatUChar4Normalized,  // UBYTE4_NORM
    MTLVertexFormatShort2,            // SHORT2
    MTLVertexFormatShort4,            // SHORT4
    MTLVertexFormatUShort2,           // USHORT2
    MTLVertexFormatUShort4,           // USHORT4
    MTLVertexFormatShort2Normalized,  // SHORT2_NORM
    MTLVertexFormatShort4Normalized,  // SHORT4_NORM
    MTLVertexFormatUShort2Normalized, // USHORT2_NORM
    MTLVertexFormatUShort4Normalized, // USHORT4_NORM
    MTLVertexFormatHalf2,             // HALF2
    MTLVertexFormatHalf4              // HALF4
};
SDL_COMPILE_TIME_ASSERT(SDLToMetal_VertexFormat, SDL_arraysize(SDLToMetal_VertexFormat) == SDL_GPU_VERTEXELEMENTFORMAT_MAX_ENUM_VALUE);

static MTLIndexType SDLToMetal_IndexType[] = {
    MTLIndexTypeUInt16, // 16BIT
    MTLIndexTypeUInt32, // 32BIT
};

static MTLPrimitiveType SDLToMetal_PrimitiveType[] = {
    MTLPrimitiveTypeTriangle,      // TRIANGLELIST
    MTLPrimitiveTypeTriangleStrip, // TRIANGLESTRIP
    MTLPrimitiveTypeLine,          // LINELIST
    MTLPrimitiveTypeLineStrip,     // LINESTRIP
    MTLPrimitiveTypePoint          // POINTLIST
};

static MTLTriangleFillMode SDLToMetal_PolygonMode[] = {
    MTLTriangleFillModeFill,  // FILL
    MTLTriangleFillModeLines, // LINE
};

static MTLCullMode SDLToMetal_CullMode[] = {
    MTLCullModeNone,  // NONE
    MTLCullModeFront, // FRONT
    MTLCullModeBack,  // BACK
};

static MTLWinding SDLToMetal_FrontFace[] = {
    MTLWindingCounterClockwise, // COUNTER_CLOCKWISE
    MTLWindingClockwise,        // CLOCKWISE
};

static MTLBlendFactor SDLToMetal_BlendFactor[] = {
    MTLBlendFactorZero,                     // INVALID
    MTLBlendFactorZero,                     // ZERO
    MTLBlendFactorOne,                      // ONE
    MTLBlendFactorSourceColor,              // SRC_COLOR
    MTLBlendFactorOneMinusSourceColor,      // ONE_MINUS_SRC_COLOR
    MTLBlendFactorDestinationColor,         // DST_COLOR
    MTLBlendFactorOneMinusDestinationColor, // ONE_MINUS_DST_COLOR
    MTLBlendFactorSourceAlpha,              // SRC_ALPHA
    MTLBlendFactorOneMinusSourceAlpha,      // ONE_MINUS_SRC_ALPHA
    MTLBlendFactorDestinationAlpha,         // DST_ALPHA
    MTLBlendFactorOneMinusDestinationAlpha, // ONE_MINUS_DST_ALPHA
    MTLBlendFactorBlendColor,               // CONSTANT_COLOR
    MTLBlendFactorOneMinusBlendColor,       // ONE_MINUS_CONSTANT_COLOR
    MTLBlendFactorSourceAlphaSaturated,     // SRC_ALPHA_SATURATE
};
SDL_COMPILE_TIME_ASSERT(SDLToMetal_BlendFactor, SDL_arraysize(SDLToMetal_BlendFactor) == SDL_GPU_BLENDFACTOR_MAX_ENUM_VALUE);

static MTLBlendOperation SDLToMetal_BlendOp[] = {
    MTLBlendOperationAdd,             // INVALID
    MTLBlendOperationAdd,             // ADD
    MTLBlendOperationSubtract,        // SUBTRACT
    MTLBlendOperationReverseSubtract, // REVERSE_SUBTRACT
    MTLBlendOperationMin,             // MIN
    MTLBlendOperationMax,             // MAX
};
SDL_COMPILE_TIME_ASSERT(SDLToMetal_BlendOp, SDL_arraysize(SDLToMetal_BlendOp) == SDL_GPU_BLENDOP_MAX_ENUM_VALUE);

static MTLCompareFunction SDLToMetal_CompareOp[] = {
    MTLCompareFunctionNever,        // INVALID
    MTLCompareFunctionNever,        // NEVER
    MTLCompareFunctionLess,         // LESS
    MTLCompareFunctionEqual,        // EQUAL
    MTLCompareFunctionLessEqual,    // LESS_OR_EQUAL
    MTLCompareFunctionGreater,      // GREATER
    MTLCompareFunctionNotEqual,     // NOT_EQUAL
    MTLCompareFunctionGreaterEqual, // GREATER_OR_EQUAL
    MTLCompareFunctionAlways,       // ALWAYS
};
SDL_COMPILE_TIME_ASSERT(SDLToMetal_CompareOp, SDL_arraysize(SDLToMetal_CompareOp) == SDL_GPU_COMPAREOP_MAX_ENUM_VALUE);

static MTLStencilOperation SDLToMetal_StencilOp[] = {
    MTLStencilOperationKeep,           // INVALID
    MTLStencilOperationKeep,           // KEEP
    MTLStencilOperationZero,           // ZERO
    MTLStencilOperationReplace,        // REPLACE
    MTLStencilOperationIncrementClamp, // INCREMENT_AND_CLAMP
    MTLStencilOperationDecrementClamp, // DECREMENT_AND_CLAMP
    MTLStencilOperationInvert,         // INVERT
    MTLStencilOperationIncrementWrap,  // INCREMENT_AND_WRAP
    MTLStencilOperationDecrementWrap,  // DECREMENT_AND_WRAP
};
SDL_COMPILE_TIME_ASSERT(SDLToMetal_StencilOp, SDL_arraysize(SDLToMetal_StencilOp) == SDL_GPU_STENCILOP_MAX_ENUM_VALUE);

static MTLSamplerAddressMode SDLToMetal_SamplerAddressMode[] = {
    MTLSamplerAddressModeRepeat,       // REPEAT
    MTLSamplerAddressModeMirrorRepeat, // MIRRORED_REPEAT
    MTLSamplerAddressModeClampToEdge   // CLAMP_TO_EDGE
};

static MTLSamplerMinMagFilter SDLToMetal_MinMagFilter[] = {
    MTLSamplerMinMagFilterNearest, // NEAREST
    MTLSamplerMinMagFilterLinear,  // LINEAR
};

static MTLSamplerMipFilter SDLToMetal_MipFilter[] = {
    MTLSamplerMipFilterNearest, // NEAREST
    MTLSamplerMipFilterLinear,  // LINEAR
};

static MTLLoadAction SDLToMetal_LoadOp[] = {
    MTLLoadActionLoad,     // LOAD
    MTLLoadActionClear,    // CLEAR
    MTLLoadActionDontCare, // DONT_CARE
};

static MTLStoreAction SDLToMetal_StoreOp[] = {
    MTLStoreActionStore,
    MTLStoreActionDontCare,
    MTLStoreActionMultisampleResolve,
    MTLStoreActionStoreAndMultisampleResolve
};

static MTLVertexStepFunction SDLToMetal_StepFunction[] = {
    MTLVertexStepFunctionPerVertex,
    MTLVertexStepFunctionPerInstance,
};

static NSUInteger SDLToMetal_SampleCount[] = {
    1, // SDL_GPU_SAMPLECOUNT_1
    2, // SDL_GPU_SAMPLECOUNT_2
    4, // SDL_GPU_SAMPLECOUNT_4
    8  // SDL_GPU_SAMPLECOUNT_8
};

static SDL_GPUTextureFormat SwapchainCompositionToFormat[] = {
    SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,      // SDR
    SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB, // SDR_LINEAR
    SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,  // HDR_EXTENDED_LINEAR
    SDL_GPU_TEXTUREFORMAT_R10G10B10A2_UNORM,   // HDR10_ST2084
};

static CFStringRef SwapchainCompositionToColorSpace[4]; // initialized on device creation

static MTLTextureType SDLToMetal_TextureType(SDL_GPUTextureType textureType, bool isMSAA)
{
    switch (textureType) {
    case SDL_GPU_TEXTURETYPE_2D:
        return isMSAA ? MTLTextureType2DMultisample : MTLTextureType2D;
    case SDL_GPU_TEXTURETYPE_2D_ARRAY:
        return MTLTextureType2DArray;
    case SDL_GPU_TEXTURETYPE_3D:
        return MTLTextureType3D;
    case SDL_GPU_TEXTURETYPE_CUBE:
        return MTLTextureTypeCube;
    case SDL_GPU_TEXTURETYPE_CUBE_ARRAY:
        return MTLTextureTypeCubeArray;
    default:
        return MTLTextureType2D;
    }
}

static MTLColorWriteMask SDLToMetal_ColorWriteMask(
    SDL_GPUColorComponentFlags mask)
{
    MTLColorWriteMask result = 0;
    if (mask & SDL_GPU_COLORCOMPONENT_R) {
        result |= MTLColorWriteMaskRed;
    }
    if (mask & SDL_GPU_COLORCOMPONENT_G) {
        result |= MTLColorWriteMaskGreen;
    }
    if (mask & SDL_GPU_COLORCOMPONENT_B) {
        result |= MTLColorWriteMaskBlue;
    }
    if (mask & SDL_GPU_COLORCOMPONENT_A) {
        result |= MTLColorWriteMaskAlpha;
    }
    return result;
}

static MTLDepthClipMode SDLToMetal_DepthClipMode(
    bool enableDepthClip
) {
    if (enableDepthClip) {
        return MTLDepthClipModeClip;
    } else {
        return MTLDepthClipModeClamp;
    }
}

// Structs

typedef struct MetalRenderer MetalRenderer;
typedef struct MetalCommandBuffer MetalCommandBuffer;

typedef struct MetalTexture
{
    id<MTLTexture> handle;
    SDL_AtomicInt referenceCount;
} MetalTexture;

typedef struct MetalTextureContainer
{
    TextureCommonHeader header;

    MetalTexture *activeTexture;
    Uint8 canBeCycled;

    Uint32 textureCapacity;
    Uint32 textureCount;
    MetalTexture **textures;

    char *debugName;
} MetalTextureContainer;

typedef struct MetalFence
{
    id<MTLCommandBuffer> commandBuffer;
    SDL_AtomicInt referenceCount;
    // AFTERGLOW TEMPORARY DIAGNOSTICS: assigned before submission/publication.
    Uint64 afterglowDiagnosticSubmission;
} MetalFence;

typedef struct MetalWindowData
{
    SDL_Window *window;
    MetalRenderer *renderer;
    int refcount;
    SDL_MetalView view;
    CAMetalLayer *layer;
    SDL_GPUPresentMode presentMode;
    id<CAMetalDrawable> drawable;
    MetalTexture texture;
    MetalTextureContainer textureContainer;
    SDL_GPUFence *inFlightFences[MAX_FRAMES_IN_FLIGHT];
    Uint32 frameCounter;
    Uint64 afterglowPresentationLayer;
} MetalWindowData;

typedef struct MetalShader
{
    id<MTLLibrary> library;
    id<MTLFunction> function;

    SDL_GPUShaderStage stage;
    Uint32 numSamplers;
    Uint32 numUniformBuffers;
    Uint32 numStorageBuffers;
    Uint32 numStorageTextures;
    Uint32 afterglowSourceHash;
} MetalShader;

typedef struct MetalGraphicsPipeline
{
    GraphicsPipelineCommonHeader header;

    id<MTLRenderPipelineState> handle;

    SDL_GPURasterizerState rasterizerState;
    SDL_GPUPrimitiveType primitiveType;
    Uint32 afterglowFragmentHash;

    id<MTLDepthStencilState> depth_stencil_state;
} MetalGraphicsPipeline;

typedef struct MetalComputePipeline
{
    ComputePipelineCommonHeader header;

    id<MTLComputePipelineState> handle;
    Uint32 threadcountX;
    Uint32 threadcountY;
    Uint32 threadcountZ;
} MetalComputePipeline;

typedef struct MetalBuffer
{
    id<MTLBuffer> handle;
    SDL_AtomicInt referenceCount;
} MetalBuffer;

typedef struct MetalBufferContainer
{
    MetalBuffer *activeBuffer;
    Uint32 size;

    Uint32 bufferCapacity;
    Uint32 bufferCount;
    MetalBuffer **buffers;
    MetalBuffer inlineBuffers[METAL_INLINE_CYCLED_BUFFER_CAPACITY];
    MetalBuffer *inlineBufferPointers[METAL_INLINE_CYCLED_BUFFER_CAPACITY];

    bool isPrivate;
    bool isWriteOnly;
    char *debugName;
} MetalBufferContainer;

typedef struct MetalUniformBuffer
{
    id<MTLBuffer> handle;
    Uint32 writeOffset;
    Uint32 drawOffset;
} MetalUniformBuffer;

typedef struct MetalCommandBuffer
{
    CommandBufferCommonHeader common;
    AfterglowMetalPassSamples *afterglowPassSamples;
    bool afterglowPassSampling;
    Sint32 afterglowActiveTimedPass;
    MetalRenderer *renderer;

    // Native Handle
    id<MTLCommandBuffer> handle;
    // AFTERGLOW TEMPORARY DIAGNOSTIC: zero if created outside our capture.
    Uint64 afterglowCaptureGeneration;

    // Presentation
    MetalWindowData **windowDatas;
    Uint32 windowDataCount;
    Uint32 windowDataCapacity;

    // Render Pass
    id<MTLRenderCommandEncoder> renderEncoder;
    MetalGraphicsPipeline *graphics_pipeline;
    MetalBuffer *indexBuffer;
    Uint32 indexBufferOffset;
    SDL_GPUIndexElementSize index_element_size;

    // Copy Pass
    id<MTLBlitCommandEncoder> blitEncoder;

    // Compute Pass
    id<MTLComputeCommandEncoder> computeEncoder;
    MetalComputePipeline *compute_pipeline;

    // Resource slot state
    bool needVertexBufferBind;
    bool needVertexSamplerBind;
    bool needVertexStorageTextureBind;
    bool needVertexStorageBufferBind;
    bool needVertexUniformBufferBind[MAX_UNIFORM_BUFFERS_PER_STAGE];

    bool needFragmentSamplerBind;
    bool needFragmentStorageTextureBind;
    bool needFragmentStorageBufferBind;
    bool needFragmentUniformBufferBind[MAX_UNIFORM_BUFFERS_PER_STAGE];

    bool needComputeSamplerBind;
    bool needComputeReadOnlyStorageTextureBind;
    bool needComputeReadOnlyStorageBufferBind;
    bool needComputeUniformBufferBind[MAX_UNIFORM_BUFFERS_PER_STAGE];

    id<MTLBuffer> vertexBuffers[MAX_VERTEX_BUFFERS];
    Uint32 vertexBufferOffsets[MAX_VERTEX_BUFFERS];
    Uint32 vertexBufferCount;

    id<MTLSamplerState> vertexSamplers[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    id<MTLTexture> vertexTextures[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    id<MTLTexture> vertexStorageTextures[MAX_STORAGE_TEXTURES_PER_STAGE];
    id<MTLBuffer> vertexStorageBuffers[MAX_STORAGE_BUFFERS_PER_STAGE];
    MetalUniformBuffer *vertexUniformBuffers[MAX_UNIFORM_BUFFERS_PER_STAGE];

    id<MTLSamplerState> fragmentSamplers[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    id<MTLTexture> fragmentTextures[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    id<MTLTexture> fragmentStorageTextures[MAX_STORAGE_TEXTURES_PER_STAGE];
    id<MTLBuffer> fragmentStorageBuffers[MAX_STORAGE_BUFFERS_PER_STAGE];
    MetalUniformBuffer *fragmentUniformBuffers[MAX_UNIFORM_BUFFERS_PER_STAGE];

    id<MTLTexture> computeSamplerTextures[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    id<MTLSamplerState> computeSamplers[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    id<MTLTexture> computeReadOnlyTextures[MAX_STORAGE_TEXTURES_PER_STAGE];
    id<MTLBuffer> computeReadOnlyBuffers[MAX_STORAGE_BUFFERS_PER_STAGE];
    id<MTLTexture> computeReadWriteTextures[MAX_COMPUTE_WRITE_TEXTURES];
    id<MTLBuffer> computeReadWriteBuffers[MAX_COMPUTE_WRITE_BUFFERS];
    MetalUniformBuffer *computeUniformBuffers[MAX_UNIFORM_BUFFERS_PER_STAGE];

    MetalUniformBuffer *inlineUsedUniformBuffers[METAL_INLINE_USED_UNIFORM_BUFFER_CAPACITY];
    MetalUniformBuffer **usedUniformBuffers;
    Uint32 usedUniformBufferCount;
    Uint32 usedUniformBufferCapacity;

    // Fences
    MetalFence *fence;

    // Reference Counting
    MetalBuffer *inlineUsedBuffers[METAL_INLINE_USED_BUFFER_CAPACITY];
    MetalBuffer **usedBuffers;
    Uint32 usedBufferCount;
    Uint32 usedBufferCapacity;

    MetalTexture *inlineUsedTextures[METAL_INLINE_USED_TEXTURE_CAPACITY];
    MetalTexture **usedTextures;
    Uint32 usedTextureCount;
    Uint32 usedTextureCapacity;
} MetalCommandBuffer;

typedef struct MetalSampler
{
    id<MTLSamplerState> handle;
} MetalSampler;

typedef struct BlitPipeline
{
    SDL_GPUGraphicsPipeline *pipeline;
    SDL_GPUTextureFormat format;
} BlitPipeline;

struct MetalRenderer
{
    // Reference to the parent device
    SDL_GPUDevice *sdlGPUDevice;

    id<MTLDevice> device;
    id<MTLCommandQueue> queue;

    bool debugMode;
    // AFTERGLOW TEMPORARY DIAGNOSTICS: immutable settings, and a sequence
    // counter protected by submitLock. Remove after the device investigation.
    AfterglowMetalPresentations *afterglowPresentations;
    Uint64 afterglowNextPresentationLayer;
    bool afterglowDiagnosticsEnabled;
    Uint64 afterglowDiagnosticSampleInterval;
    Uint64 afterglowDiagnosticSubmission;
    Uint64 afterglowNextThermalSampleNS;
    Sint32 afterglowThermalState;
    Sint32 afterglowLowPowerModeState;
    Uint32 afterglowPassTimestampMode;
    Uint32 afterglowPassCounterBuffers;
    Uint64 afterglowPassAcquisition;
    id<MTLCounterSet> afterglowTimestampCounterSet;
    // Protected by afterglowCaptureLock; never accessed by completion handlers.
    SDL_Mutex *afterglowCaptureLock;
    bool afterglowCaptureActive;
    Uint64 afterglowCaptureGeneration;
    NSString *afterglowCapturePath;
    SDL_PropertiesID props;
    Uint32 allowedFramesInFlight;

    // Accelerando opt-in CPU timings, written only by the device owner thread.
    bool timingEnabled;
    bool timingActive;
    bool timingSignposts;
    SDL_ThreadID timingOwner;
    Uint64 timingSequence;
    SDL_AccelerandoGPUTimingSample timingSample;
    os_log_t timingLog;
    os_signpost_id_t timingSignpostID;

    MetalWindowData **claimedWindows;
    Uint32 claimedWindowCount;
    Uint32 claimedWindowCapacity;

    MetalCommandBuffer **availableCommandBuffers;
    Uint32 availableCommandBufferCount;
    Uint32 availableCommandBufferCapacity;

    MetalCommandBuffer **submittedCommandBuffers;
    Uint32 submittedCommandBufferCount;
    Uint32 submittedCommandBufferCapacity;

    MetalFence **availableFences;
    Uint32 availableFenceCount;
    Uint32 availableFenceCapacity;

    MetalUniformBuffer **uniformBufferPool;
    Uint32 uniformBufferPoolCount;
    Uint32 uniformBufferPoolCapacity;

    MetalBufferContainer **bufferContainersToDestroy;
    Uint32 bufferContainersToDestroyCount;
    Uint32 bufferContainersToDestroyCapacity;

    MetalTextureContainer **textureContainersToDestroy;
    Uint32 textureContainersToDestroyCount;
    Uint32 textureContainersToDestroyCapacity;

    // Blit
    SDL_GPUShader *blitVertexShader;
    SDL_GPUShader *blitFrom2DShader;
    SDL_GPUShader *blitFrom2DArrayShader;
    SDL_GPUShader *blitFrom3DShader;
    SDL_GPUShader *blitFromCubeShader;
    SDL_GPUShader *blitFromCubeArrayShader;

    SDL_GPUSampler *blitNearestSampler;
    SDL_GPUSampler *blitLinearSampler;

    BlitPipelineCacheEntry *blitPipelines;
    Uint32 blitPipelineCount;
    Uint32 blitPipelineCapacity;

    // Mutexes
    SDL_Mutex *submitLock;
    SDL_Mutex *acquireCommandBufferLock;
    SDL_Mutex *acquireUniformBufferLock;
    SDL_Mutex *disposeLock;
    SDL_Mutex *fenceLock;
    SDL_Mutex *windowLock;
};

// Helper Functions

static void METAL_INTERNAL_AfterglowCreatePassSamples(
    MetalRenderer *renderer, MetalCommandBuffer *commandBuffer)
{
    if (!renderer->afterglowTimestampCounterSet ||
        renderer->afterglowPassCounterBuffers >= 32) {
        return;
    }
    if (@available(macOS 11.0, iOS 14.0, tvOS 14.0, *)) {
        MTLCounterSampleBufferDescriptor *descriptor = [MTLCounterSampleBufferDescriptor new];
        descriptor.counterSet = renderer->afterglowTimestampCounterSet;
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.sampleCount = AFTERGLOW_MAX_TIMED_PASSES * 4;
        descriptor.label = @"Afterglow optional render-pass timestamps";
        NSError *error = nil;
        id<MTLCounterSampleBuffer> buffer = [renderer->device
            newCounterSampleBufferWithDescriptor:descriptor error:&error];
        if (buffer) {
            AfterglowMetalPassSamples *samples = [AfterglowMetalPassSamples new];
            samples->buffer = buffer;
            commandBuffer->afterglowPassSamples = samples;
            renderer->afterglowPassCounterBuffers += 1;
        } else {
            SDL_LogError(SDL_LOG_CATEGORY_GPU,
                "AfterglowMetal/pass_timestamps allocation failed: %s",
                error.localizedDescription.UTF8String);
        }
    }
}

static void METAL_INTERNAL_AfterglowAcquirePassSamples(
    MetalRenderer *renderer, MetalCommandBuffer *commandBuffer)
{
    commandBuffer->afterglowPassSampling = false;
    commandBuffer->afterglowActiveTimedPass = -1;
    if (!renderer->afterglowPassTimestampMode) {
        return;
    }
    const Uint64 acquisition = ++renderer->afterglowPassAcquisition;
    if (renderer->afterglowPassTimestampMode == 1 && acquisition % 30 != 0) {
        return;
    }
    AfterglowMetalPassSamples *samples = commandBuffer->afterglowPassSamples;
    if (samples && SDL_CompareAndSwapAtomicInt(&samples->busy, 0, 1)) {
        samples->passCount = 0;
        samples->droppedPasses = 0;
        samples->acquisition = acquisition;
        SDL_zeroa(samples->passes);
        if (@available(macOS 11.0, iOS 14.0, tvOS 14.0, *)) {
            [renderer->device sampleTimestamps:&samples->cpuStart gpuTimestamp:&samples->gpuStart];
        }
        commandBuffer->afterglowPassSampling = true;
    }
}

static void METAL_INTERNAL_AfterglowRecordPassDraw(
    MetalCommandBuffer *commandBuffer, Uint32 draws, Uint64 vertices)
{
    if (!commandBuffer->afterglowPassSampling || commandBuffer->afterglowActiveTimedPass < 0) {
        return;
    }
    AfterglowMetalPassRecord *pass = &commandBuffer->afterglowPassSamples->passes[
        commandBuffer->afterglowActiveTimedPass];
    pass->drawCount += draws;
    pass->vertices += vertices;
    const Uint32 hash = commandBuffer->graphics_pipeline->afterglowFragmentHash;
    Uint32 index = 0;
    while (index < pass->shaderCount && pass->shaderHashes[index] != hash) {
        index += 1;
    }
    if (index < AFTERGLOW_MAX_PASS_SHADERS) {
        if (index == pass->shaderCount) {
            pass->shaderHashes[index] = hash;
            pass->shaderCount += 1;
        }
        pass->shaderDraws[index] += draws;
    }
}

static double METAL_INTERNAL_AfterglowTimestampMilliseconds(
    Uint64 start, Uint64 end, Uint64 gpuLower, Uint64 gpuUpper,
    double nanosecondsPerGPUTick)
{
    if (start == 0 || end == 0 || start == MTLCounterErrorValue ||
        end == MTLCounterErrorValue || end < start || start < gpuLower ||
        end > gpuUpper || nanosecondsPerGPUTick <= 0.0) {
        return -1.0;
    }
    return (double)(end - start) * nanosecondsPerGPUTick / 1000000.0;
}

// Called only with an exclusively leased, strongly retained native owner.
// No SDL renderer, fence, command-buffer wrapper or pipeline is captured.
static void METAL_INTERNAL_AfterglowCompletePassSamples(
    AfterglowMetalPassSamples *samples, id<MTLCommandBuffer> nativeBuffer,
    Uint64 submission, bool logPeriodic)
{
    @autoreleasepool {
        if (@available(macOS 11.0, iOS 14.0, tvOS 14.0, *)) {
            if (nativeBuffer.status != MTLCommandBufferStatusCompleted) {
                SDL_LogError(SDL_LOG_CATEGORY_GPU,
                    "AfterglowMetal/pass_timestamps incomplete submission=%" SDL_PRIu64 " status=%d",
                    submission, (int)nativeBuffer.status);
                SDL_SetAtomicInt(&samples->busy, 0);
                return;
            }
            const double gpuMs = (nativeBuffer.GPUEndTime - nativeBuffer.GPUStartTime) * 1000.0;
            if (samples->passCount && (gpuMs > 12.0 || logPeriodic)) {
                MTLTimestamp cpuEnd = 0, gpuEnd = 0;
                [nativeBuffer.device sampleTimestamps:&cpuEnd gpuTimestamp:&gpuEnd];
                const double scale = cpuEnd > samples->cpuStart && gpuEnd > samples->gpuStart
                    ? (double)(cpuEnd - samples->cpuStart) / (double)(gpuEnd - samples->gpuStart) : -1.0;
                NSData *resolved = [samples->buffer resolveCounterRange:
                    NSMakeRange(0, samples->passCount * 4)];
                SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
                    "AfterglowMetal/pass_timestamps submission=%" SDL_PRIu64
                    " acquisition=%" SDL_PRIu64 " passes=%u dropped=%u gpu_ms=%.3f"
                    " cpu_start=%" SDL_PRIu64 " cpu_end=%" SDL_PRIu64
                    " gpu_start=%" SDL_PRIu64 " gpu_end=%" SDL_PRIu64 " ns_per_tick=%.9f",
                    submission, samples->acquisition, samples->passCount, samples->droppedPasses,
                    gpuMs, samples->cpuStart, (Uint64)cpuEnd, samples->gpuStart, (Uint64)gpuEnd, scale);
                if (resolved.length >= samples->passCount * 4 * sizeof(MTLCounterResultTimestamp)) {
                    const MTLCounterResultTimestamp *timestamps = resolved.bytes;
                    for (Uint32 i = 0; i < samples->passCount; i += 1) {
                        const AfterglowMetalPassRecord *pass = &samples->passes[i];
                        const Uint64 vs = timestamps[i * 4].timestamp;
                        const Uint64 ve = timestamps[i * 4 + 1].timestamp;
                        const Uint64 fs = timestamps[i * 4 + 2].timestamp;
                        const Uint64 fe = timestamps[i * 4 + 3].timestamp;
                        char shaders[256] = { 0 };
                        size_t written = 0;
                        for (Uint32 j = 0; j < pass->shaderCount; j += 1) {
                            written += SDL_snprintf(shaders + written, sizeof(shaders) - written,
                                "%s%08x:%u", j ? "," : "", pass->shaderHashes[j], pass->shaderDraws[j]);
                        }
                        SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
                            "AfterglowMetal/pass submission=%" SDL_PRIu64 " pass=%u target=%ux%u"
                            " draws=%u vertices=%" SDL_PRIu64 " vertex_ms=%.6f fragment_ms=%.6f"
                            " v_start_ticks=%" SDL_PRIu64 " v_end_ticks=%" SDL_PRIu64
                            " f_start_ticks=%" SDL_PRIu64 " f_end_ticks=%" SDL_PRIu64 " shaders=%s",
                            submission, i, pass->width, pass->height, pass->drawCount, pass->vertices,
                            METAL_INTERNAL_AfterglowTimestampMilliseconds(vs, ve, samples->gpuStart, gpuEnd, scale),
                            METAL_INTERNAL_AfterglowTimestampMilliseconds(fs, fe, samples->gpuStart, gpuEnd, scale),
                            vs, ve, fs, fe, shaders);
                    }
                } else {
                    SDL_LogError(SDL_LOG_CATEGORY_GPU,
                        "AfterglowMetal/pass_timestamps resolve failed submission=%" SDL_PRIu64 " bytes=%u",
                        submission, (Uint32)resolved.length);
                }
            }
        }
        // Final owner access: a reused wrapper may now start a new recording.
        SDL_SetAtomicInt(&samples->busy, 0);
    }
}

// AFTERGLOW TEMPORARY DIAGNOSTIC: MTLCaptureManager only records command
// buffers created after capture starts and committed before capture stops.
// Keep the start and native allocation together, and identify that capture on
// each buffer so a previously acquired buffer cannot stop a newer capture.
static void METAL_INTERNAL_AfterglowAcquireNativeCommandBuffer(
    MetalRenderer *renderer,
    MetalCommandBuffer *commandBuffer)
{
    commandBuffer->afterglowCaptureGeneration = 0;
    if (!renderer->afterglowCaptureLock) {
        commandBuffer->handle = [renderer->queue commandBuffer];
        return;
    }

    SDL_LockMutex(renderer->afterglowCaptureLock);
    NSString *requestedPath = nil;
    SDL_LockProperties(renderer->props);
    const char *request = SDL_GetStringProperty(
        renderer->props, "afterglow.metal.capture_request", NULL);
    if (request) {
        requestedPath = [NSString stringWithUTF8String:request];
        SDL_ClearProperty(renderer->props, "afterglow.metal.capture_request");
    }
    SDL_UnlockProperties(renderer->props);

    if (requestedPath) {
        NSString *failure = nil;
        if (renderer->afterglowCaptureActive) {
            failure = @"a capture is already active";
        } else if (![requestedPath isAbsolutePath] ||
                   ![requestedPath.pathExtension isEqualToString:@"gputrace"]) {
            failure = @"capture requires an absolute .gputrace path";
        } else if ([[NSFileManager defaultManager] fileExistsAtPath:requestedPath]) {
            failure = @"capture output already exists; choose a new path";
        } else if (@available(macOS 10.15, iOS 13.0, tvOS 13.0, *)) {
            MTLCaptureManager *manager = [MTLCaptureManager sharedCaptureManager];
            if (![manager supportsDestination:MTLCaptureDestinationGPUTraceDocument]) {
                failure = @"GPU trace capture unsupported; enable MetalCaptureEnabled in the diagnostic app plist";
            } else if (manager.isCapturing) {
                failure = @"another Metal capture is already active";
            } else {
                MTLCaptureDescriptor *descriptor = [MTLCaptureDescriptor new];
                descriptor.captureObject = renderer->queue;
                descriptor.destination = MTLCaptureDestinationGPUTraceDocument;
                descriptor.outputURL = [NSURL fileURLWithPath:requestedPath];
                NSError *error = nil;
                if ([manager startCaptureWithDescriptor:descriptor error:&error]) {
                    renderer->afterglowCaptureActive = true;
                    renderer->afterglowCaptureGeneration += 1;
                    renderer->afterglowCapturePath = requestedPath;
                    SDL_SetStringProperty(renderer->props, "afterglow.metal.capture_status",
                        [[@"recording: " stringByAppendingString:requestedPath] UTF8String]);
                    SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
                        "AfterglowMetal/capture started generation=%" SDL_PRIu64 " path=%s",
                        renderer->afterglowCaptureGeneration, requestedPath.UTF8String);
                } else {
                    failure = error.localizedDescription ?: @"Metal rejected the capture request";
                }
            }
        } else {
            failure = @"GPU trace capture requires macOS 10.15 or iOS/tvOS 13";
        }
        if (failure) {
            SDL_SetStringProperty(renderer->props, "afterglow.metal.capture_status",
                [[@"error: " stringByAppendingString:failure] UTF8String]);
            SDL_LogError(SDL_LOG_CATEGORY_GPU, "AfterglowMetal/capture failed path=%s reason=%s",
                requestedPath.UTF8String, failure.UTF8String);
        }
    }

    commandBuffer->handle = [renderer->queue commandBuffer];
    if (renderer->afterglowCaptureActive) {
        commandBuffer->afterglowCaptureGeneration = renderer->afterglowCaptureGeneration;
    }
    SDL_UnlockMutex(renderer->afterglowCaptureLock);
}

// devicectl cannot export the buffer aliases Metal puts inside a .gputrace.
// Replace only internal file symlinks in this newly created capture package.
static bool METAL_INTERNAL_AfterglowMaterializeCaptureLinks(
    NSString *capturePath,
    Uint32 *materializedCount,
    Uint32 *errorCount)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSDictionary *rootAttributes = [fileManager attributesOfItemAtPath:capturePath error:&error];
    *materializedCount = 0;
    *errorCount = 0;
    if (![rootAttributes[NSFileType] isEqualToString:NSFileTypeDirectory]) {
        *errorCount = 1;
        SDL_LogError(SDL_LOG_CATEGORY_GPU,
            "AfterglowMetal/capture export failed path=%s reason=%s",
            capturePath.UTF8String,
            (error.localizedDescription ?: @"capture output is not a regular directory").UTF8String);
        return false;
    }

    NSURL *rootURL = [[NSURL fileURLWithPath:capturePath isDirectory:YES]
        URLByResolvingSymlinksInPath].URLByStandardizingPath;
    NSString *rootPrefix = [rootURL.path stringByAppendingString:@"/"];
    NSDirectoryEnumerator<NSURL *> *entries = [fileManager
        enumeratorAtURL:rootURL
        includingPropertiesForKeys:nil
        options:0
        errorHandler:^BOOL(NSURL *url, NSError *enumerationError) {
            *errorCount += 1;
            SDL_LogError(SDL_LOG_CATEGORY_GPU,
                "AfterglowMetal/capture export enumeration failed path=%s reason=%s",
                url.path.UTF8String, enumerationError.localizedDescription.UTF8String);
            return YES;
        }];
    if (entries == nil) {
        *errorCount += 1;
    }
    for (NSURL *entryURL in entries) {
        @autoreleasepool {
            error = nil;
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:entryURL.path error:&error];
            NSString *failure = nil;
            if (attributes == nil) {
                failure = error.localizedDescription ?: @"could not inspect capture entry";
            } else if ([attributes[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
                // The enumerator does not descend through symlinks. Check both
                // the alias's parent and its resolved target before any I/O.
                NSURL *parentURL = [entryURL.URLByDeletingLastPathComponent
                    URLByResolvingSymlinksInPath].URLByStandardizingPath;
                NSURL *targetURL = [entryURL URLByResolvingSymlinksInPath].URLByStandardizingPath;
                const bool parentInside = [parentURL.path isEqualToString:rootURL.path] ||
                    [parentURL.path hasPrefix:rootPrefix];
                if (!parentInside || ![targetURL.path hasPrefix:rootPrefix]) {
                    failure = @"refusing a symlink outside the capture package";
                } else {
                    NSDictionary *targetAttributes = [fileManager
                        attributesOfItemAtPath:targetURL.path error:&error];
                    if (![targetAttributes[NSFileType] isEqualToString:NSFileTypeRegular]) {
                        failure = error.localizedDescription ?: @"symlink target is not a regular file";
                    } else {
                        NSData *contents = [NSData dataWithContentsOfURL:targetURL options:0 error:&error];
                        if (contents == nil ||
                            ![contents writeToURL:entryURL options:NSDataWritingAtomic error:&error]) {
                            failure = error.localizedDescription ?: @"could not materialize capture symlink";
                        } else {
                            // Atomic writing replaces the alias, preserving its
                            // target and leaving complete bytes at the alias path.
                            *materializedCount += 1;
                        }
                    }
                }
            }
            if (failure) {
                *errorCount += 1;
                SDL_LogError(SDL_LOG_CATEGORY_GPU,
                    "AfterglowMetal/capture export entry failed path=%s reason=%s",
                    entryURL.path.UTF8String, failure.UTF8String);
            }
        }
    }
    SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
        "AfterglowMetal/capture export path=%s materialized=%u errors=%u",
        capturePath.UTF8String, *materializedCount, *errorCount);
    return *errorCount == 0;
}

static void METAL_INTERNAL_AfterglowStopCapture(
    MetalRenderer *renderer,
    Uint64 generation)
{
    if (!renderer->afterglowCaptureLock) {
        return;
    }
    SDL_LockMutex(renderer->afterglowCaptureLock);
    if (renderer->afterglowCaptureActive &&
        (generation == 0 || generation == renderer->afterglowCaptureGeneration)) {
        [[MTLCaptureManager sharedCaptureManager] stopCapture];
        Uint32 materializedCount = 0;
        Uint32 exportErrors = 0;
        const bool exportReady = METAL_INTERNAL_AfterglowMaterializeCaptureLinks(
            renderer->afterglowCapturePath, &materializedCount, &exportErrors);
        SDL_SetStringProperty(renderer->props, "afterglow.metal.capture_status",
            [[NSString stringWithFormat:@"%@: %@ (materialized=%u errors=%u)",
                exportReady ? @"stopped, export ready" : @"error preparing stopped capture for export",
                renderer->afterglowCapturePath, materializedCount, exportErrors] UTF8String]);
        SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
            "AfterglowMetal/capture stopped generation=%" SDL_PRIu64 " path=%s",
            renderer->afterglowCaptureGeneration, renderer->afterglowCapturePath.UTF8String);
        renderer->afterglowCaptureActive = false;
        renderer->afterglowCapturePath = nil;
    }
    SDL_UnlockMutex(renderer->afterglowCaptureLock);
}

static bool METAL_INTERNAL_TimingActive(MetalRenderer *renderer)
{
    // Check the immutable owner before reading mutable sample state. GPU calls
    // on worker threads must not race the main thread's capture or counters.
    return renderer->timingEnabled && renderer->timingOwner == SDL_GetCurrentThreadID() && renderer->timingActive;
}

static void METAL_INTERNAL_TimingAdd(MetalRenderer *renderer, SDL_AccelerandoGPUTimingPhase phase, Uint64 duration)
{
    renderer->timingSample.duration_ns[phase] += duration;
    renderer->timingSample.calls[phase] += 1;
}

static void METAL_INTERNAL_TimingSignpost(MetalRenderer *renderer, SDL_AccelerandoGPUTimingPhase phase, bool begin)
{
    if (!renderer->timingSignposts) return;
    if (@available(macOS 10.14, iOS 12.0, tvOS 12.0, *)) {
        // Literal names keep Instruments events readable without formatting or
        // message construction. Signposts are separate from timing captures.
#define TIMING_SIGNPOST_CASE(phase_name, label) \
        case phase_name: \
            if (begin) os_signpost_interval_begin(renderer->timingLog, renderer->timingSignpostID, label); \
            else os_signpost_interval_end(renderer->timingLog, renderer->timingSignpostID, label); \
            break
        switch (phase) {
            TIMING_SIGNPOST_CASE(SDL_ACCELERANDO_GPU_FENCE_WAIT, "GPU fence wait");
            TIMING_SIGNPOST_CASE(SDL_ACCELERANDO_GPU_NEXT_DRAWABLE, "nextDrawable");
            TIMING_SIGNPOST_CASE(SDL_ACCELERANDO_GPU_SUBMIT_LOCK, "GPU submit lock");
            TIMING_SIGNPOST_CASE(SDL_ACCELERANDO_GPU_PRESENT_DRAWABLE, "presentDrawable");
            TIMING_SIGNPOST_CASE(SDL_ACCELERANDO_GPU_COMMIT, "GPU commit");
            TIMING_SIGNPOST_CASE(SDL_ACCELERANDO_GPU_SUBMIT_CLEANUP, "GPU submit cleanup");
            default: break;
        }
#undef TIMING_SIGNPOST_CASE
    }
}

static bool SDLCALL METAL_TimingBegin(SDL_GPUDevice *device)
{
    if (!device) return false;
    MetalRenderer *renderer = (MetalRenderer *)device->driverData;
    if (!renderer->timingEnabled || renderer->timingOwner != SDL_GetCurrentThreadID()) return false;
    SDL_zero(renderer->timingSample);
    renderer->timingSample.sequence = ++renderer->timingSequence;
    renderer->timingSample.begin_ns = SDL_GetTicksNS();
    renderer->timingActive = true;
    return true;
}

static bool SDLCALL METAL_TimingRead(SDL_GPUDevice *device, SDL_AccelerandoGPUTimingSample *sample)
{
    if (!device || !sample) return false;
    MetalRenderer *renderer = (MetalRenderer *)device->driverData;
    if (!METAL_INTERNAL_TimingActive(renderer)) return false;
    renderer->timingSample.end_ns = SDL_GetTicksNS();
    renderer->timingActive = false;
    *sample = renderer->timingSample;
    return true;
}

static bool SDLCALL METAL_TimingIsActive(SDL_GPUDevice *device)
{
    return device && METAL_INTERNAL_TimingActive((MetalRenderer *)device->driverData);
}

static void SDLCALL METAL_TimingAddDuration(SDL_GPUDevice *device, SDL_AccelerandoGPUTimingPhase phase, Uint64 duration)
{
    if (device && (unsigned)phase < SDL_ACCELERANDO_GPU_TIMING_PHASE_COUNT) {
        MetalRenderer *renderer = (MetalRenderer *)device->driverData;
        if (METAL_INTERNAL_TimingActive(renderer)) METAL_INTERNAL_TimingAdd(renderer, phase, duration);
    }
}

static const SDL_AccelerandoGPUTimingAPI metalTimingAPI = {
    SDL_ACCELERANDO_GPU_TIMING_VERSION, sizeof(SDL_AccelerandoGPUTimingSample),
    METAL_TimingBegin, METAL_TimingRead, METAL_TimingIsActive, METAL_TimingAddDuration
};

// FIXME: This should be moved into SDL_sysgpu.h
static inline Uint32 METAL_INTERNAL_NextHighestAlignment(
    Uint32 n,
    Uint32 align)
{
    return align * ((n + align - 1) / align);
}

// Quit

static void METAL_DestroyDevice(SDL_GPUDevice *device)
{
    MetalRenderer *renderer = (MetalRenderer *)device->driverData;

    // Flush any remaining GPU work...
    METAL_Wait(device->driverData);
    METAL_INTERNAL_AfterglowStopCapture(renderer, 0);
    if (renderer->afterglowPresentations) {
        METAL_INTERNAL_AfterglowExportPresentations(renderer->afterglowPresentations,
            (Uint64)SDL_GetNumberProperty(renderer->props, "afterglow.presentation.capture_epoch_ns", 0),
            SDL_GetStringProperty(renderer->props, "afterglow.presentation.capture_path", ""));
        renderer->afterglowPresentations = nil;
    }

    // Release the window data
    for (Sint32 i = renderer->claimedWindowCount - 1; i >= 0; i -= 1) {
        METAL_ReleaseWindow(device->driverData, renderer->claimedWindows[i]->window);
    }
    SDL_free(renderer->claimedWindows);

    // Release the blit resources
    METAL_INTERNAL_DestroyBlitResources(device->driverData);

    // Release uniform buffers
    for (Uint32 i = 0; i < renderer->uniformBufferPoolCount; i += 1) {
        renderer->uniformBufferPool[i]->handle = nil;
        SDL_free(renderer->uniformBufferPool[i]);
    }
    SDL_free(renderer->uniformBufferPool);

    // Release destroyed resource lists
    SDL_free(renderer->bufferContainersToDestroy);
    SDL_free(renderer->textureContainersToDestroy);

    // Release command buffer infrastructure
    for (Uint32 i = 0; i < renderer->availableCommandBufferCount; i += 1) {
        MetalCommandBuffer *commandBuffer = renderer->availableCommandBuffers[i];
        if (commandBuffer->usedBuffers != commandBuffer->inlineUsedBuffers) {
            SDL_free(commandBuffer->usedBuffers);
        }
        if (commandBuffer->usedTextures != commandBuffer->inlineUsedTextures) {
            SDL_free(commandBuffer->usedTextures);
        }
        if (commandBuffer->usedUniformBuffers != commandBuffer->inlineUsedUniformBuffers) {
            SDL_free(commandBuffer->usedUniformBuffers);
        }
        SDL_free(commandBuffer->windowDatas);
        commandBuffer->afterglowPassSamples = nil;
        SDL_free(commandBuffer);
    }
    SDL_free(renderer->availableCommandBuffers);
    SDL_free(renderer->submittedCommandBuffers);

    // Release fence infrastructure
    for (Uint32 i = 0; i < renderer->availableFenceCount; i += 1) {
        SDL_free(renderer->availableFences[i]);
    }
    SDL_free(renderer->availableFences);

    // Release the mutexes
    SDL_DestroyMutex(renderer->submitLock);
    SDL_DestroyMutex(renderer->acquireCommandBufferLock);
    SDL_DestroyMutex(renderer->acquireUniformBufferLock);
    SDL_DestroyMutex(renderer->disposeLock);
    SDL_DestroyMutex(renderer->fenceLock);
    SDL_DestroyMutex(renderer->windowLock);
    SDL_DestroyMutex(renderer->afterglowCaptureLock);

    // Release the command queue
    renderer->afterglowTimestampCounterSet = nil;
    renderer->queue = nil;
    renderer->timingLog = nil;

    // Release properties
    SDL_DestroyProperties(renderer->props);

    // Free the primary structures
    SDL_free(renderer);
    SDL_free(device);
}

static SDL_PropertiesID METAL_GetDeviceProperties(SDL_GPUDevice *device)
{
    MetalRenderer *renderer = (MetalRenderer *)device->driverData;
    return renderer->props;
}

// Resource tracking

static void METAL_INTERNAL_TrackBuffer(
    MetalCommandBuffer *commandBuffer,
    MetalBuffer *buffer)
{
    TRACK_RESOURCE(
        buffer,
        MetalBuffer *,
        usedBuffers,
        inlineUsedBuffers,
        usedBufferCount,
        usedBufferCapacity);
}

static void METAL_INTERNAL_TrackTexture(
    MetalCommandBuffer *commandBuffer,
    MetalTexture *texture)
{
    TRACK_RESOURCE(
        texture,
        MetalTexture *,
        usedTextures,
        inlineUsedTextures,
        usedTextureCount,
        usedTextureCapacity);
}

static void METAL_INTERNAL_TrackUniformBuffer(
    MetalCommandBuffer *commandBuffer,
    MetalUniformBuffer *uniformBuffer)
{
    Uint32 i;
    for (i = 0; i < commandBuffer->usedUniformBufferCount; i += 1) {
        if (commandBuffer->usedUniformBuffers[i] == uniformBuffer) {
            return;
        }
    }

    if (commandBuffer->usedUniformBufferCount == commandBuffer->usedUniformBufferCapacity) {
        if (commandBuffer->usedUniformBufferCapacity > SDL_MAX_UINT32 / 2 ||
            (size_t)(commandBuffer->usedUniformBufferCapacity * 2) >
                SDL_SIZE_MAX / sizeof(MetalUniformBuffer *)) {
            // This buffer remains checked out of the pool, which is safer
            // than recycling it while the GPU can still reference it.
            SDL_OutOfMemory();
            return;
        }
        const Uint32 newCapacity = commandBuffer->usedUniformBufferCapacity * 2;
        MetalUniformBuffer **newUniformBuffers;
        if (commandBuffer->usedUniformBuffers == commandBuffer->inlineUsedUniformBuffers) {
            newUniformBuffers = (MetalUniformBuffer **)SDL_malloc(
                newCapacity * sizeof(MetalUniformBuffer *));
            if (newUniformBuffers) {
                SDL_memcpy(
                    newUniformBuffers,
                    commandBuffer->inlineUsedUniformBuffers,
                    commandBuffer->usedUniformBufferCount * sizeof(MetalUniformBuffer *));
            }
        } else {
            newUniformBuffers = (MetalUniformBuffer **)SDL_realloc(
                commandBuffer->usedUniformBuffers,
                newCapacity * sizeof(MetalUniformBuffer *));
        }
        if (!newUniformBuffers) {
            return;
        }
        commandBuffer->usedUniformBuffers = newUniformBuffers;
        commandBuffer->usedUniformBufferCapacity = newCapacity;
    }

    commandBuffer->usedUniformBuffers[commandBuffer->usedUniformBufferCount] = uniformBuffer;
    commandBuffer->usedUniformBufferCount += 1;
}

// Shader Compilation

typedef struct MetalLibraryFunction
{
    id<MTLLibrary> library;
    id<MTLFunction> function;
} MetalLibraryFunction;

static bool METAL_INTERNAL_IsValidMetalLibrary(
    const Uint8 *code,
    size_t codeSize)
{
    // Metal libraries have a 4 byte header containing `MTLB`.
    if (codeSize < 4 || code == NULL) {
        return false;
    }
    return SDL_memcmp(code, "MTLB", 4) == 0;
}

// This function assumes that it's called from within an autorelease pool
static MetalLibraryFunction METAL_INTERNAL_CompileShader(
    MetalRenderer *renderer,
    SDL_GPUShaderFormat format,
    const Uint8 *code,
    size_t codeSize,
    const char *entrypoint)
{
    MetalLibraryFunction libraryFunction = { nil, nil };
    id<MTLLibrary> library;
    NSError *error;
    dispatch_data_t data;
    id<MTLFunction> function;

    if (!entrypoint) {
        entrypoint = "main0";
    }

    if (format == SDL_GPU_SHADERFORMAT_MSL) {
        NSString *codeString = [[NSString alloc]
            initWithBytes:code
                   length:codeSize
                 encoding:NSUTF8StringEncoding];
        library = [renderer->device
            newLibraryWithSource:codeString
                         options:nil
                           error:&error];
    } else if (format == SDL_GPU_SHADERFORMAT_METALLIB) {
        if (!METAL_INTERNAL_IsValidMetalLibrary(code, codeSize)) {
            SET_STRING_ERROR_AND_RETURN(
                "The provided shader code is not a valid Metal library!",
                libraryFunction);
        }
        data = dispatch_data_create(
            code,
            codeSize,
            dispatch_get_global_queue(0, 0),
            DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        library = [renderer->device newLibraryWithData:data error:&error];
    } else {
        SDL_assert(!"SDL_gpu.c should have already validated this!");
        return libraryFunction;
    }

    if (library == nil) {
        SDL_LogError(
            SDL_LOG_CATEGORY_GPU,
            "Creating MTLLibrary failed: %s",
            [[error description] cStringUsingEncoding:[NSString defaultCStringEncoding]]);
        return libraryFunction;
    } else if (error != nil) {
        SDL_LogWarn(
            SDL_LOG_CATEGORY_GPU,
            "Creating MTLLibrary failed: %s",
            [[error description] cStringUsingEncoding:[NSString defaultCStringEncoding]]);
    }

    function = [library newFunctionWithName:@(entrypoint)];
    if (function == nil) {
        SDL_LogError(
            SDL_LOG_CATEGORY_GPU,
            "Creating MTLFunction failed");
        return libraryFunction;
    }

    libraryFunction.library = library;
    libraryFunction.function = function;
    return libraryFunction;
}

// Disposal

static void METAL_INTERNAL_DestroyTextureContainer(
    MetalTextureContainer *container)
{
    for (Uint32 i = 0; i < container->textureCount; i += 1) {
        container->textures[i]->handle = nil;
        SDL_free(container->textures[i]);
    }
    SDL_DestroyProperties(container->header.info.props);
    if (container->debugName != NULL) {
        SDL_free(container->debugName);
    }
    SDL_free(container->textures);
    SDL_free(container);
}

static void METAL_ReleaseTexture(
    SDL_GPURenderer *driverData,
    SDL_GPUTexture *texture)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalTextureContainer *container = (MetalTextureContainer *)texture;

    SDL_LockMutex(renderer->disposeLock);

    EXPAND_ARRAY_IF_NEEDED(
        renderer->textureContainersToDestroy,
        MetalTextureContainer *,
        renderer->textureContainersToDestroyCount + 1,
        renderer->textureContainersToDestroyCapacity,
        renderer->textureContainersToDestroyCapacity + 1);

    renderer->textureContainersToDestroy[renderer->textureContainersToDestroyCount] = container;
    renderer->textureContainersToDestroyCount += 1;

    SDL_UnlockMutex(renderer->disposeLock);
}

static void METAL_ReleaseSampler(
    SDL_GPURenderer *driverData,
    SDL_GPUSampler *sampler)
{
    @autoreleasepool {
        MetalSampler *metalSampler = (MetalSampler *)sampler;
        metalSampler->handle = nil;
        SDL_free(metalSampler);
    }
}

static void METAL_INTERNAL_DestroyBufferContainer(
    MetalBufferContainer *container)
{
    for (Uint32 i = 0; i < container->bufferCount; i += 1) {
        container->buffers[i]->handle = nil;
        bool isInline = false;
        for (Uint32 inlineIndex = 0;
             inlineIndex < METAL_INLINE_CYCLED_BUFFER_CAPACITY;
             inlineIndex += 1) {
            if (container->buffers[i] ==
                &container->inlineBuffers[inlineIndex]) {
                isInline = true;
                break;
            }
        }
        if (!isInline) {
            SDL_free(container->buffers[i]);
        }
    }
    if (container->debugName != NULL) {
        SDL_free(container->debugName);
    }
    if (container->buffers != container->inlineBufferPointers) {
        SDL_free(container->buffers);
    }
    SDL_free(container);
}

static void METAL_ReleaseBuffer(
    SDL_GPURenderer *driverData,
    SDL_GPUBuffer *buffer)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalBufferContainer *container = (MetalBufferContainer *)buffer;

    SDL_LockMutex(renderer->disposeLock);

    EXPAND_ARRAY_IF_NEEDED(
        renderer->bufferContainersToDestroy,
        MetalBufferContainer *,
        renderer->bufferContainersToDestroyCount + 1,
        renderer->bufferContainersToDestroyCapacity,
        renderer->bufferContainersToDestroyCapacity + 1);

    renderer->bufferContainersToDestroy[renderer->bufferContainersToDestroyCount] = container;
    renderer->bufferContainersToDestroyCount += 1;

    SDL_UnlockMutex(renderer->disposeLock);
}

static void METAL_ReleaseTransferBuffer(
    SDL_GPURenderer *driverData,
    SDL_GPUTransferBuffer *transferBuffer)
{
    METAL_ReleaseBuffer(
        driverData,
        (SDL_GPUBuffer *)transferBuffer);
}

static void METAL_ReleaseShader(
    SDL_GPURenderer *driverData,
    SDL_GPUShader *shader)
{
    @autoreleasepool {
        MetalShader *metalShader = (MetalShader *)shader;
        metalShader->function = nil;
        metalShader->library = nil;
        SDL_free(metalShader);
    }
}

static void METAL_ReleaseComputePipeline(
    SDL_GPURenderer *driverData,
    SDL_GPUComputePipeline *computePipeline)
{
    @autoreleasepool {
        MetalComputePipeline *metalComputePipeline = (MetalComputePipeline *)computePipeline;
        metalComputePipeline->handle = nil;
        SDL_free(metalComputePipeline);
    }
}

static void METAL_ReleaseGraphicsPipeline(
    SDL_GPURenderer *driverData,
    SDL_GPUGraphicsPipeline *graphicsPipeline)
{
    @autoreleasepool {
        MetalGraphicsPipeline *metalGraphicsPipeline = (MetalGraphicsPipeline *)graphicsPipeline;
        metalGraphicsPipeline->handle = nil;
        metalGraphicsPipeline->depth_stencil_state = nil;
        SDL_free(metalGraphicsPipeline);
    }
}

// Pipeline Creation

static SDL_GPUComputePipeline *METAL_CreateComputePipeline(
    SDL_GPURenderer *driverData,
    const SDL_GPUComputePipelineCreateInfo *createinfo)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalLibraryFunction libraryFunction;
        id<MTLComputePipelineState> handle;
        MetalComputePipeline *pipeline;
        NSError *error;

        libraryFunction = METAL_INTERNAL_CompileShader(
            renderer,
            createinfo->format,
            createinfo->code,
            createinfo->code_size,
            createinfo->entrypoint);

        if (libraryFunction.library == nil || libraryFunction.function == nil) {
            return NULL;
        }

        MTLComputePipelineDescriptor *descriptor = [MTLComputePipelineDescriptor new];
        descriptor.computeFunction = libraryFunction.function;

        if (renderer->debugMode && SDL_HasProperty(createinfo->props, SDL_PROP_GPU_COMPUTEPIPELINE_CREATE_NAME_STRING)) {
            const char *name = SDL_GetStringProperty(createinfo->props, SDL_PROP_GPU_COMPUTEPIPELINE_CREATE_NAME_STRING, NULL);
            descriptor.label = @(name);
        }

        handle = [renderer->device newComputePipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone reflection: nil error:&error];
        if (error != NULL) {
            SET_ERROR_AND_RETURN("Creating compute pipeline failed: %s", [[error description] UTF8String], NULL);
        }

        pipeline = SDL_calloc(1, sizeof(MetalComputePipeline));
        pipeline->handle = handle;
        pipeline->header.numSamplers = createinfo->num_samplers;
        pipeline->header.numReadonlyStorageTextures = createinfo->num_readonly_storage_textures;
        pipeline->header.numReadWriteStorageTextures = createinfo->num_readwrite_storage_textures;
        pipeline->header.numReadonlyStorageBuffers = createinfo->num_readonly_storage_buffers;
        pipeline->header.numReadWriteStorageBuffers = createinfo->num_readwrite_storage_buffers;
        pipeline->header.numUniformBuffers = createinfo->num_uniform_buffers;
        pipeline->threadcountX = createinfo->threadcount_x;
        pipeline->threadcountY = createinfo->threadcount_y;
        pipeline->threadcountZ = createinfo->threadcount_z;

        return (SDL_GPUComputePipeline *)pipeline;
    }
}

static SDL_GPUGraphicsPipeline *METAL_CreateGraphicsPipeline(
    SDL_GPURenderer *driverData,
    const SDL_GPUGraphicsPipelineCreateInfo *createinfo)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalShader *vertexShader = (MetalShader *)createinfo->vertex_shader;
        MetalShader *fragmentShader = (MetalShader *)createinfo->fragment_shader;
        MTLRenderPipelineDescriptor *pipelineDescriptor;
        const SDL_GPUColorTargetBlendState *blendState;
        MTLVertexDescriptor *vertexDescriptor;
        Uint32 binding;
        MTLDepthStencilDescriptor *depthStencilDescriptor;
        MTLStencilDescriptor *frontStencilDescriptor = NULL;
        MTLStencilDescriptor *backStencilDescriptor = NULL;
        id<MTLDepthStencilState> depthStencilState = nil;
        id<MTLRenderPipelineState> pipelineState = nil;
        NSError *error = NULL;
        MetalGraphicsPipeline *result = NULL;

        if (renderer->debugMode) {
            if (vertexShader->stage != SDL_GPU_SHADERSTAGE_VERTEX) {
                SDL_assert_release(!"CreateGraphicsPipeline was passed a fragment shader for the vertex stage");
            }
            if (fragmentShader->stage != SDL_GPU_SHADERSTAGE_FRAGMENT) {
                SDL_assert_release(!"CreateGraphicsPipeline was passed a vertex shader for the fragment stage");
            }
        }
#ifdef SDL_PLATFORM_VISIONOS
        // The default is depth clipping enabled and it can't be changed
        if (!createinfo->rasterizer_state.enable_depth_clip) {
            SDL_assert_release(!"Rasterizer state enable_depth_clip must be true on this platform");
        }
#endif

        pipelineDescriptor = [MTLRenderPipelineDescriptor new];

        // Blend

        for (Uint32 i = 0; i < createinfo->target_info.num_color_targets; i += 1) {
            blendState = &createinfo->target_info.color_target_descriptions[i].blend_state;
            SDL_GPUColorComponentFlags colorWriteMask = blendState->enable_color_write_mask ?
                blendState->color_write_mask :
                0xF;

            pipelineDescriptor.colorAttachments[i].pixelFormat = SDLToMetal_TextureFormat(createinfo->target_info.color_target_descriptions[i].format);
            pipelineDescriptor.colorAttachments[i].writeMask = SDLToMetal_ColorWriteMask(colorWriteMask);
            pipelineDescriptor.colorAttachments[i].blendingEnabled = blendState->enable_blend;
            pipelineDescriptor.colorAttachments[i].rgbBlendOperation = SDLToMetal_BlendOp[blendState->color_blend_op];
            pipelineDescriptor.colorAttachments[i].alphaBlendOperation = SDLToMetal_BlendOp[blendState->alpha_blend_op];
            pipelineDescriptor.colorAttachments[i].sourceRGBBlendFactor = SDLToMetal_BlendFactor[blendState->src_color_blendfactor];
            pipelineDescriptor.colorAttachments[i].sourceAlphaBlendFactor = SDLToMetal_BlendFactor[blendState->src_alpha_blendfactor];
            pipelineDescriptor.colorAttachments[i].destinationRGBBlendFactor = SDLToMetal_BlendFactor[blendState->dst_color_blendfactor];
            pipelineDescriptor.colorAttachments[i].destinationAlphaBlendFactor = SDLToMetal_BlendFactor[blendState->dst_alpha_blendfactor];
        }

        // Multisample

        pipelineDescriptor.rasterSampleCount = SDLToMetal_SampleCount[createinfo->multisample_state.sample_count];
        pipelineDescriptor.alphaToCoverageEnabled = createinfo->multisample_state.enable_alpha_to_coverage;

        // Depth Stencil

        if (createinfo->target_info.has_depth_stencil_target) {
            pipelineDescriptor.depthAttachmentPixelFormat = SDLToMetal_TextureFormat(createinfo->target_info.depth_stencil_format);
            if (IsStencilFormat(createinfo->target_info.depth_stencil_format)) {
                pipelineDescriptor.stencilAttachmentPixelFormat = SDLToMetal_TextureFormat(createinfo->target_info.depth_stencil_format);
            }

            if (createinfo->depth_stencil_state.enable_stencil_test) {
                frontStencilDescriptor = [MTLStencilDescriptor new];
                frontStencilDescriptor.stencilCompareFunction = SDLToMetal_CompareOp[createinfo->depth_stencil_state.front_stencil_state.compare_op];
                frontStencilDescriptor.stencilFailureOperation = SDLToMetal_StencilOp[createinfo->depth_stencil_state.front_stencil_state.fail_op];
                frontStencilDescriptor.depthStencilPassOperation = SDLToMetal_StencilOp[createinfo->depth_stencil_state.front_stencil_state.pass_op];
                frontStencilDescriptor.depthFailureOperation = SDLToMetal_StencilOp[createinfo->depth_stencil_state.front_stencil_state.depth_fail_op];
                frontStencilDescriptor.readMask = createinfo->depth_stencil_state.compare_mask;
                frontStencilDescriptor.writeMask = createinfo->depth_stencil_state.write_mask;

                backStencilDescriptor = [MTLStencilDescriptor new];
                backStencilDescriptor.stencilCompareFunction = SDLToMetal_CompareOp[createinfo->depth_stencil_state.back_stencil_state.compare_op];
                backStencilDescriptor.stencilFailureOperation = SDLToMetal_StencilOp[createinfo->depth_stencil_state.back_stencil_state.fail_op];
                backStencilDescriptor.depthStencilPassOperation = SDLToMetal_StencilOp[createinfo->depth_stencil_state.back_stencil_state.pass_op];
                backStencilDescriptor.depthFailureOperation = SDLToMetal_StencilOp[createinfo->depth_stencil_state.back_stencil_state.depth_fail_op];
                backStencilDescriptor.readMask = createinfo->depth_stencil_state.compare_mask;
                backStencilDescriptor.writeMask = createinfo->depth_stencil_state.write_mask;
            }

            depthStencilDescriptor = [MTLDepthStencilDescriptor new];
            depthStencilDescriptor.depthCompareFunction = createinfo->depth_stencil_state.enable_depth_test ? SDLToMetal_CompareOp[createinfo->depth_stencil_state.compare_op] : MTLCompareFunctionAlways;
            // Disable write when test is disabled, to match other APIs' behavior
            depthStencilDescriptor.depthWriteEnabled = createinfo->depth_stencil_state.enable_depth_write && createinfo->depth_stencil_state.enable_depth_test;
            depthStencilDescriptor.frontFaceStencil = frontStencilDescriptor;
            depthStencilDescriptor.backFaceStencil = backStencilDescriptor;

            depthStencilState = [renderer->device newDepthStencilStateWithDescriptor:depthStencilDescriptor];
        }

        // Shaders

        pipelineDescriptor.vertexFunction = vertexShader->function;
        pipelineDescriptor.fragmentFunction = fragmentShader->function;

        // Vertex Descriptor

        if (createinfo->vertex_input_state.num_vertex_buffers > 0) {
            vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];

            for (Uint32 i = 0; i < createinfo->vertex_input_state.num_vertex_attributes; i += 1) {
                Uint32 loc = createinfo->vertex_input_state.vertex_attributes[i].location;
                vertexDescriptor.attributes[loc].format = SDLToMetal_VertexFormat[createinfo->vertex_input_state.vertex_attributes[i].format];
                vertexDescriptor.attributes[loc].offset = createinfo->vertex_input_state.vertex_attributes[i].offset;
                vertexDescriptor.attributes[loc].bufferIndex =
                    METAL_FIRST_VERTEX_BUFFER_SLOT + createinfo->vertex_input_state.vertex_attributes[i].buffer_slot;
            }

            for (Uint32 i = 0; i < createinfo->vertex_input_state.num_vertex_buffers; i += 1) {
                binding = METAL_FIRST_VERTEX_BUFFER_SLOT + createinfo->vertex_input_state.vertex_buffer_descriptions[i].slot;
                vertexDescriptor.layouts[binding].stepFunction = SDLToMetal_StepFunction[createinfo->vertex_input_state.vertex_buffer_descriptions[i].input_rate];
                vertexDescriptor.layouts[binding].stepRate = 1;
                vertexDescriptor.layouts[binding].stride = createinfo->vertex_input_state.vertex_buffer_descriptions[i].pitch;
            }

            pipelineDescriptor.vertexDescriptor = vertexDescriptor;
        }

        if (renderer->debugMode && SDL_HasProperty(createinfo->props, SDL_PROP_GPU_GRAPHICSPIPELINE_CREATE_NAME_STRING)) {
            const char *name = SDL_GetStringProperty(createinfo->props, SDL_PROP_GPU_GRAPHICSPIPELINE_CREATE_NAME_STRING, NULL);
            pipelineDescriptor.label = @(name);
        }

        // Create the graphics pipeline

        const Uint64 afterglowPipelineStart = renderer->afterglowDiagnosticsEnabled ? SDL_GetTicksNS() : 0;
        pipelineState = [renderer->device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
        if (renderer->afterglowDiagnosticsEnabled) {
            const SDL_GPUColorTargetDescription *target = createinfo->target_info.num_color_targets > 0
                ? &createinfo->target_info.color_target_descriptions[0] : NULL;
            SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
                "AfterglowMetal/pipeline_create duration_ms=%.3f fragment=%08x vertex=%08x primitive=%u target=%u blend=%u src=%u dst=%u success=%u",
                (double)(SDL_GetTicksNS() - afterglowPipelineStart) / 1000000.0,
                fragmentShader->afterglowSourceHash, vertexShader->afterglowSourceHash,
                createinfo->primitive_type, target ? target->format : 0,
                target ? target->blend_state.enable_blend : 0,
                target ? target->blend_state.src_color_blendfactor : 0,
                target ? target->blend_state.dst_color_blendfactor : 0,
                pipelineState != nil);
        }
        if (error != NULL) {
            SET_ERROR_AND_RETURN("Creating render pipeline failed: %s", [[error description] UTF8String], NULL);
        }

        result = SDL_calloc(1, sizeof(MetalGraphicsPipeline));
        result->handle = pipelineState;
        result->depth_stencil_state = depthStencilState;
        result->rasterizerState = createinfo->rasterizer_state;
        result->primitiveType = createinfo->primitive_type;
        result->afterglowFragmentHash = fragmentShader->afterglowSourceHash;
        result->header.num_vertex_samplers = vertexShader->numSamplers;
        result->header.num_vertex_uniform_buffers = vertexShader->numUniformBuffers;
        result->header.num_vertex_storage_buffers = vertexShader->numStorageBuffers;
        result->header.num_vertex_storage_textures = vertexShader->numStorageTextures;
        result->header.num_fragment_samplers = fragmentShader->numSamplers;
        result->header.num_fragment_uniform_buffers = fragmentShader->numUniformBuffers;
        result->header.num_fragment_storage_buffers = fragmentShader->numStorageBuffers;
        result->header.num_fragment_storage_textures = fragmentShader->numStorageTextures;
        return (SDL_GPUGraphicsPipeline *)result;
    }
}

// Debug Naming

static void METAL_SetBufferName(
    SDL_GPURenderer *driverData,
    SDL_GPUBuffer *buffer,
    const char *text)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalBufferContainer *container = (MetalBufferContainer *)buffer;

        if (renderer->debugMode && text != NULL) {
            if (container->debugName != NULL) {
                SDL_free(container->debugName);
            }

            container->debugName = SDL_strdup(text);

            for (Uint32 i = 0; i < container->bufferCount; i += 1) {
                container->buffers[i]->handle.label = @(text);
            }
        }
    }
}

static void METAL_SetTextureName(
    SDL_GPURenderer *driverData,
    SDL_GPUTexture *texture,
    const char *text)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalTextureContainer *container = (MetalTextureContainer *)texture;

        if (renderer->debugMode && text != NULL) {
            if (container->debugName != NULL) {
                SDL_free(container->debugName);
            }

            container->debugName = SDL_strdup(text);

            for (Uint32 i = 0; i < container->textureCount; i += 1) {
                container->textures[i]->handle.label = @(text);
            }
        }
    }
}

static void METAL_InsertDebugLabel(
    SDL_GPUCommandBuffer *commandBuffer,
    const char *text)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        NSString *label = @(text);

        if (metalCommandBuffer->renderEncoder) {
            [metalCommandBuffer->renderEncoder insertDebugSignpost:label];
        } else if (metalCommandBuffer->blitEncoder) {
            [metalCommandBuffer->blitEncoder insertDebugSignpost:label];
        } else if (metalCommandBuffer->computeEncoder) {
            [metalCommandBuffer->computeEncoder insertDebugSignpost:label];
        } else {
            // Metal doesn't have insertDebugSignpost for command buffers...
            [metalCommandBuffer->handle pushDebugGroup:label];
            [metalCommandBuffer->handle popDebugGroup];
        }
    }
}

static void METAL_PushDebugGroup(
    SDL_GPUCommandBuffer *commandBuffer,
    const char *name)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        NSString *label = @(name);

        if (metalCommandBuffer->renderEncoder) {
            [metalCommandBuffer->renderEncoder pushDebugGroup:label];
        } else if (metalCommandBuffer->blitEncoder) {
            [metalCommandBuffer->blitEncoder pushDebugGroup:label];
        } else if (metalCommandBuffer->computeEncoder) {
            [metalCommandBuffer->computeEncoder pushDebugGroup:label];
        } else {
            [metalCommandBuffer->handle pushDebugGroup:label];
        }
    }
}

static void METAL_PopDebugGroup(
    SDL_GPUCommandBuffer *commandBuffer)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;

        if (metalCommandBuffer->renderEncoder) {
            [metalCommandBuffer->renderEncoder popDebugGroup];
        } else if (metalCommandBuffer->blitEncoder) {
            [metalCommandBuffer->blitEncoder popDebugGroup];
        } else if (metalCommandBuffer->computeEncoder) {
            [metalCommandBuffer->computeEncoder popDebugGroup];
        } else {
            [metalCommandBuffer->handle popDebugGroup];
        }
    }
}

// Resource Creation

static SDL_GPUSampler *METAL_CreateSampler(
    SDL_GPURenderer *driverData,
    const SDL_GPUSamplerCreateInfo *createinfo)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MTLSamplerDescriptor *samplerDesc = [MTLSamplerDescriptor new];
        id<MTLSamplerState> sampler;
        MetalSampler *metalSampler;

        samplerDesc.sAddressMode = SDLToMetal_SamplerAddressMode[createinfo->address_mode_u];
        samplerDesc.tAddressMode = SDLToMetal_SamplerAddressMode[createinfo->address_mode_v];
        samplerDesc.rAddressMode = SDLToMetal_SamplerAddressMode[createinfo->address_mode_w];
        samplerDesc.minFilter = SDLToMetal_MinMagFilter[createinfo->min_filter];
        samplerDesc.magFilter = SDLToMetal_MinMagFilter[createinfo->mag_filter];
        samplerDesc.mipFilter = SDLToMetal_MipFilter[createinfo->mipmap_mode]; // FIXME: Is this right with non-mipmapped samplers?
        samplerDesc.lodMinClamp = createinfo->min_lod;
        samplerDesc.lodMaxClamp = createinfo->max_lod;
        samplerDesc.maxAnisotropy = (NSUInteger)((createinfo->enable_anisotropy) ? createinfo->max_anisotropy : 1);
        samplerDesc.compareFunction = (createinfo->enable_compare) ? SDLToMetal_CompareOp[createinfo->compare_op] : MTLCompareFunctionAlways;

        if (renderer->debugMode && SDL_HasProperty(createinfo->props, SDL_PROP_GPU_SAMPLER_CREATE_NAME_STRING)) {
            const char *name = SDL_GetStringProperty(createinfo->props, SDL_PROP_GPU_SAMPLER_CREATE_NAME_STRING, NULL);
            samplerDesc.label = @(name);
        }

        sampler = [renderer->device newSamplerStateWithDescriptor:samplerDesc];
        if (sampler == NULL) {
            SET_STRING_ERROR_AND_RETURN("Failed to create sampler", NULL);
        }

        metalSampler = (MetalSampler *)SDL_calloc(1, sizeof(MetalSampler));
        metalSampler->handle = sampler;
        return (SDL_GPUSampler *)metalSampler;
    }
}

static SDL_GPUShader *METAL_CreateShader(
    SDL_GPURenderer *driverData,
    const SDL_GPUShaderCreateInfo *createinfo)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalLibraryFunction libraryFunction;
        MetalShader *result;

        libraryFunction = METAL_INTERNAL_CompileShader(
            (MetalRenderer *)driverData,
            createinfo->format,
            createinfo->code,
            createinfo->code_size,
            createinfo->entrypoint);

        if (libraryFunction.library == nil || libraryFunction.function == nil) {
            return NULL;
        }

        result = SDL_calloc(1, sizeof(MetalShader));
        result->library = libraryFunction.library;
        result->function = libraryFunction.function;
        result->stage = createinfo->stage;
        result->numSamplers = createinfo->num_samplers;
        result->numStorageBuffers = createinfo->num_storage_buffers;
        result->numStorageTextures = createinfo->num_storage_textures;
        if (renderer->afterglowDiagnosticsEnabled) {
            Uint32 hash = 2166136261U;
            for (size_t i = 0; i < createinfo->code_size; i += 1) {
                hash = (hash ^ createinfo->code[i]) * 16777619U;
            }
            result->afterglowSourceHash = hash;
            SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
                "AfterglowMetal/pass_shader hash=%08x stage=%u entry=%s bytes=%u",
                hash, createinfo->stage, createinfo->entrypoint, (Uint32)createinfo->code_size);
        }
        result->numUniformBuffers = createinfo->num_uniform_buffers;
        return (SDL_GPUShader *)result;
    }
}

// This function assumes that it's called from within an autorelease pool
static MetalTexture *METAL_INTERNAL_CreateTexture(
    MetalRenderer *renderer,
    const SDL_GPUTextureCreateInfo *createinfo)
{
    MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor new];
    id<MTLTexture> texture;
    MetalTexture *metalTexture;

    textureDescriptor.textureType = SDLToMetal_TextureType(createinfo->type, createinfo->sample_count > SDL_GPU_SAMPLECOUNT_1);
    textureDescriptor.pixelFormat = SDLToMetal_TextureFormat(createinfo->format);
    // This format isn't natively supported so let's swizzle!
    if (createinfo->format == SDL_GPU_TEXTUREFORMAT_B4G4R4A4_UNORM) {
        if (@available(macOS 10.15, iOS 13.0, tvOS 13.0, *)) {
            textureDescriptor.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleBlue,
                                                                      MTLTextureSwizzleGreen,
                                                                      MTLTextureSwizzleRed,
                                                                      MTLTextureSwizzleAlpha);
        } else {
            SET_STRING_ERROR_AND_RETURN("SDL_GPU_TEXTUREFORMAT_B4G4R4A4_UNORM is not supported", NULL);
        }
    }

    textureDescriptor.width = createinfo->width;
    textureDescriptor.height = createinfo->height;
    textureDescriptor.depth = (createinfo->type == SDL_GPU_TEXTURETYPE_3D) ? createinfo->layer_count_or_depth : 1;
    textureDescriptor.mipmapLevelCount = createinfo->num_levels;
    textureDescriptor.sampleCount = SDLToMetal_SampleCount[createinfo->sample_count];
    textureDescriptor.arrayLength =
        (createinfo->type == SDL_GPU_TEXTURETYPE_2D_ARRAY || createinfo->type == SDL_GPU_TEXTURETYPE_CUBE_ARRAY)
            ? createinfo->layer_count_or_depth
            : 1;
    textureDescriptor.storageMode = MTLStorageModePrivate;

    textureDescriptor.usage = 0;
    if (createinfo->usage & (SDL_GPU_TEXTUREUSAGE_COLOR_TARGET |
                             SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET)) {
        textureDescriptor.usage |= MTLTextureUsageRenderTarget;
    }
    if (createinfo->usage & (SDL_GPU_TEXTUREUSAGE_SAMPLER |
                             SDL_GPU_TEXTUREUSAGE_GRAPHICS_STORAGE_READ |
                             SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_READ)) {
        textureDescriptor.usage |= MTLTextureUsageShaderRead;
    }
    if (createinfo->usage & (SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE |
                             SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE)) {
        textureDescriptor.usage |= MTLTextureUsageShaderWrite;
    }

    texture = [renderer->device newTextureWithDescriptor:textureDescriptor];
    if (texture == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to create MTLTexture!");
        return NULL;
    }

    metalTexture = (MetalTexture *)SDL_calloc(1, sizeof(MetalTexture));
    metalTexture->handle = texture;
    SDL_SetAtomicInt(&metalTexture->referenceCount, 0);

    if (renderer->debugMode && SDL_HasProperty(createinfo->props, SDL_PROP_GPU_TEXTURE_CREATE_NAME_STRING)) {
        metalTexture->handle.label = @(SDL_GetStringProperty(createinfo->props, SDL_PROP_GPU_TEXTURE_CREATE_NAME_STRING, NULL));
    }

    return metalTexture;
}

static bool METAL_SupportsSampleCount(
    SDL_GPURenderer *driverData,
    SDL_GPUTextureFormat format,
    SDL_GPUSampleCount sampleCount)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        NSUInteger mtlSampleCount = SDLToMetal_SampleCount[sampleCount];
        return [renderer->device supportsTextureSampleCount:mtlSampleCount];
    }
}

static SDL_GPUTexture *METAL_CreateTexture(
    SDL_GPURenderer *driverData,
    const SDL_GPUTextureCreateInfo *createinfo)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalTextureContainer *container;
        MetalTexture *texture;

        texture = METAL_INTERNAL_CreateTexture(
            renderer,
            createinfo);

        if (texture == NULL) {
            SET_STRING_ERROR_AND_RETURN("Failed to create texture", NULL);
        }

        container = SDL_calloc(1, sizeof(MetalTextureContainer));
        container->canBeCycled = 1;

        // Copy properties so we don't lose information when the client destroys them
        container->header.info = *createinfo;
        container->header.info.props = SDL_CreateProperties();
        if (createinfo->props) {
            SDL_CopyProperties(createinfo->props, container->header.info.props);
        }

        container->activeTexture = texture;
        container->textureCapacity = 1;
        container->textureCount = 1;
        container->textures = SDL_calloc(
            container->textureCapacity, sizeof(MetalTexture *));
        container->textures[0] = texture;
        container->debugName = NULL;

        if (SDL_HasProperty(createinfo->props, SDL_PROP_GPU_TEXTURE_CREATE_NAME_STRING)) {
            container->debugName = SDL_strdup(SDL_GetStringProperty(createinfo->props, SDL_PROP_GPU_TEXTURE_CREATE_NAME_STRING, NULL));
        }

        return (SDL_GPUTexture *)container;
    }
}

// This function assumes that it's called from within an autorelease pool
static MetalTexture *METAL_INTERNAL_PrepareTextureForWrite(
    MetalRenderer *renderer,
    MetalTextureContainer *container,
    bool cycle)
{
    Uint32 i;

    // Cycle the active texture handle if needed
    if (cycle && container->canBeCycled) {
        for (i = 0; i < container->textureCount; i += 1) {
            if (SDL_GetAtomicInt(&container->textures[i]->referenceCount) == 0) {
                container->activeTexture = container->textures[i];
                return container->activeTexture;
            }
        }

        EXPAND_ARRAY_IF_NEEDED(
            container->textures,
            MetalTexture *,
            container->textureCount + 1,
            container->textureCapacity,
            container->textureCapacity + 1);

        container->textures[container->textureCount] = METAL_INTERNAL_CreateTexture(
            renderer,
            &container->header.info);
        container->textureCount += 1;

        container->activeTexture = container->textures[container->textureCount - 1];
    }

    return container->activeTexture;
}

// This function assumes that it's called from within an autorelease pool
static bool METAL_INTERNAL_InitBuffer(
    MetalRenderer *renderer,
    MetalBuffer *metalBuffer,
    Uint32 size,
    MTLResourceOptions resourceOptions,
    const char *debugName)
{
    id<MTLBuffer> bufferHandle;

    // Storage buffers have to be 4-aligned, so might as well align them all
    size = METAL_INTERNAL_NextHighestAlignment(size, 4);

    bufferHandle = [renderer->device newBufferWithLength:size options:resourceOptions];
    if (bufferHandle == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Could not create buffer");
        return false;
    }

    metalBuffer->handle = bufferHandle;
    SDL_SetAtomicInt(&metalBuffer->referenceCount, 0);

    if (debugName != NULL) {
        metalBuffer->handle.label = @(debugName);
    }

    return true;
}

static MetalBuffer *METAL_INTERNAL_CreateBuffer(
    MetalRenderer *renderer,
    Uint32 size,
    MTLResourceOptions resourceOptions,
    const char *debugName)
{
    MetalBuffer *metalBuffer = SDL_calloc(1, sizeof(MetalBuffer));
    if (metalBuffer == NULL) {
        return NULL;
    }
    if (!METAL_INTERNAL_InitBuffer(
            renderer, metalBuffer, size, resourceOptions, debugName)) {
        SDL_free(metalBuffer);
        return NULL;
    }
    return metalBuffer;
}

// This function assumes that it's called from within an autorelease pool
static MetalBufferContainer *METAL_INTERNAL_CreateBufferContainer(
    MetalRenderer *renderer,
    Uint32 size,
    bool isPrivate,
    bool isWriteOnly,
    const char *debugName)
{
    MetalBufferContainer *container = SDL_calloc(1, sizeof(MetalBufferContainer));
    MTLResourceOptions resourceOptions;

    container->size = size;
    container->bufferCapacity = METAL_INLINE_CYCLED_BUFFER_CAPACITY;
    container->bufferCount = 1;
    container->buffers = container->inlineBufferPointers;
    container->isPrivate = isPrivate;
    container->isWriteOnly = isWriteOnly;
    container->debugName = NULL;
    if (container->debugName != NULL) {
        container->debugName = SDL_strdup(debugName);
    }

    if (isPrivate) {
        resourceOptions = MTLResourceStorageModePrivate;
    } else {
        if (isWriteOnly) {
            resourceOptions = MTLResourceCPUCacheModeWriteCombined;
        } else {
            resourceOptions = MTLResourceCPUCacheModeDefaultCache;
        }
    }

    container->buffers[0] = &container->inlineBuffers[0];
    if (!METAL_INTERNAL_InitBuffer(
            renderer, container->buffers[0], size, resourceOptions,
            debugName)) {
        SDL_free(container);
        return NULL;
    }

    container->activeBuffer = container->buffers[0];

    return container;
}

static SDL_GPUBuffer *METAL_CreateBuffer(
    SDL_GPURenderer *driverData,
    SDL_GPUBufferUsageFlags usage,
    Uint32 size,
    const char *debugName)
{
    @autoreleasepool {
        return (SDL_GPUBuffer *)METAL_INTERNAL_CreateBufferContainer(
            (MetalRenderer *)driverData,
            size,
            true,
            false,
            debugName);
    }
}

static SDL_GPUTransferBuffer *METAL_CreateTransferBuffer(
    SDL_GPURenderer *driverData,
    SDL_GPUTransferBufferUsage usage,
    Uint32 size,
    const char *debugName)
{
    @autoreleasepool {
        return (SDL_GPUTransferBuffer *)METAL_INTERNAL_CreateBufferContainer(
            (MetalRenderer *)driverData,
            size,
            false,
            usage == SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            debugName);
    }
}

// This function assumes that it's called from within an autorelease pool
static MetalUniformBuffer *METAL_INTERNAL_CreateUniformBuffer(
    MetalRenderer *renderer,
    Uint32 size)
{
    MetalUniformBuffer *uniformBuffer;
    id<MTLBuffer> bufferHandle;

    bufferHandle = [renderer->device newBufferWithLength:size options:MTLResourceCPUCacheModeWriteCombined];
    if (bufferHandle == nil) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Could not create uniform buffer");
        return NULL;
    }

    uniformBuffer = SDL_calloc(1, sizeof(MetalUniformBuffer));
    uniformBuffer->handle = bufferHandle;
    uniformBuffer->writeOffset = 0;
    uniformBuffer->drawOffset = 0;

    return uniformBuffer;
}

// This function assumes that it's called from within an autorelease pool
static MetalBuffer *METAL_INTERNAL_PrepareBufferForWrite(
    MetalRenderer *renderer,
    MetalBufferContainer *container,
    bool cycle)
{
    MTLResourceOptions resourceOptions;
    Uint32 i;

    // Cycle if needed
    if (cycle && SDL_GetAtomicInt(&container->activeBuffer->referenceCount) > 0) {
        for (i = 0; i < container->bufferCount; i += 1) {
            if (SDL_GetAtomicInt(&container->buffers[i]->referenceCount) == 0) {
                container->activeBuffer = container->buffers[i];
                return container->activeBuffer;
            }
        }

        if (container->bufferCount == container->bufferCapacity) {
            if (container->bufferCapacity > SDL_MAX_UINT32 / 2 ||
                (size_t)(container->bufferCapacity * 2) >
                    SDL_SIZE_MAX / sizeof(MetalBuffer *)) {
                SDL_OutOfMemory();
                return container->activeBuffer;
            }
            const Uint32 newCapacity = container->bufferCapacity * 2;
            MetalBuffer **newBuffers;
            if (container->buffers == container->inlineBufferPointers) {
                newBuffers = (MetalBuffer **)SDL_malloc(
                    newCapacity * sizeof(MetalBuffer *));
                if (newBuffers != NULL) {
                    SDL_memcpy(newBuffers, container->inlineBufferPointers,
                               container->bufferCount *
                                   sizeof(MetalBuffer *));
                }
            } else {
                newBuffers = (MetalBuffer **)SDL_realloc(
                    container->buffers,
                    newCapacity * sizeof(MetalBuffer *));
            }
            if (newBuffers == NULL) {
                return container->activeBuffer;
            }
            container->buffers = newBuffers;
            container->bufferCapacity = newCapacity;
        }

        if (container->isPrivate) {
            resourceOptions = MTLResourceStorageModePrivate;
        } else {
            if (container->isWriteOnly) {
                resourceOptions = MTLResourceCPUCacheModeWriteCombined;
            } else {
                resourceOptions = MTLResourceCPUCacheModeDefaultCache;
            }
        }

        MetalBuffer *newBuffer;
        if (container->bufferCount <
            METAL_INLINE_CYCLED_BUFFER_CAPACITY) {
            newBuffer =
                &container->inlineBuffers[container->bufferCount];
            if (!METAL_INTERNAL_InitBuffer(
                    renderer, newBuffer, container->size, resourceOptions,
                    container->debugName)) {
                return container->activeBuffer;
            }
        } else {
            newBuffer = METAL_INTERNAL_CreateBuffer(
                renderer, container->size, resourceOptions,
                container->debugName);
            if (newBuffer == NULL) {
                return container->activeBuffer;
            }
        }
        container->buffers[container->bufferCount] = newBuffer;
        container->bufferCount += 1;

        container->activeBuffer = container->buffers[container->bufferCount - 1];
    }

    return container->activeBuffer;
}

// TransferBuffer Data

static void *METAL_MapTransferBuffer(
    SDL_GPURenderer *driverData,
    SDL_GPUTransferBuffer *transferBuffer,
    bool cycle)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalBufferContainer *container = (MetalBufferContainer *)transferBuffer;
        MetalBuffer *buffer = METAL_INTERNAL_PrepareBufferForWrite(renderer, container, cycle);
        return [buffer->handle contents];
    }
}

static void METAL_UnmapTransferBuffer(
    SDL_GPURenderer *driverData,
    SDL_GPUTransferBuffer *transferBuffer)
{
#ifdef SDL_PLATFORM_MACOS
    @autoreleasepool {
        // FIXME: Is this necessary?
        MetalBufferContainer *container = (MetalBufferContainer *)transferBuffer;
        MetalBuffer *buffer = container->activeBuffer;
        if (buffer->handle.storageMode == MTLStorageModeManaged) {
            [buffer->handle didModifyRange:NSMakeRange(0, container->size)];
        }
    }
#endif
}

// Copy Pass

static void METAL_BeginCopyPass(
    SDL_GPUCommandBuffer *commandBuffer)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        metalCommandBuffer->blitEncoder = [metalCommandBuffer->handle blitCommandEncoder];
    }
}

static void METAL_UploadToTexture(
    SDL_GPUCommandBuffer *commandBuffer,
    const SDL_GPUTextureTransferInfo *source,
    const SDL_GPUTextureRegion *destination,
    bool cycle)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;
        MetalBufferContainer *bufferContainer = (MetalBufferContainer *)source->transfer_buffer;
        MetalTextureContainer *textureContainer = (MetalTextureContainer *)destination->texture;

        MetalTexture *metalTexture = METAL_INTERNAL_PrepareTextureForWrite(renderer, textureContainer, cycle);

        [metalCommandBuffer->blitEncoder
                 copyFromBuffer:bufferContainer->activeBuffer->handle
                   sourceOffset:source->offset
              sourceBytesPerRow:BytesPerRow(destination->w, textureContainer->header.info.format)
            // sourceBytesPerImage expects the stride between 2D images (slices) of a 3D texture, not the size of the entire region
            sourceBytesPerImage:SDL_CalculateGPUTextureFormatSize(textureContainer->header.info.format, destination->w, destination->h, 1)
                     sourceSize:MTLSizeMake(destination->w, destination->h, destination->d)
                      toTexture:metalTexture->handle
               destinationSlice:destination->layer
               destinationLevel:destination->mip_level
              destinationOrigin:MTLOriginMake(destination->x, destination->y, destination->z)];

        METAL_INTERNAL_TrackTexture(metalCommandBuffer, metalTexture);
        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, bufferContainer->activeBuffer);
    }
}

static void METAL_UploadToBuffer(
    SDL_GPUCommandBuffer *commandBuffer,
    const SDL_GPUTransferBufferLocation *source,
    const SDL_GPUBufferRegion *destination,
    bool cycle)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;
        MetalBufferContainer *transferContainer = (MetalBufferContainer *)source->transfer_buffer;
        MetalBufferContainer *bufferContainer = (MetalBufferContainer *)destination->buffer;

        MetalBuffer *metalBuffer = METAL_INTERNAL_PrepareBufferForWrite(
            renderer,
            bufferContainer,
            cycle);

        [metalCommandBuffer->blitEncoder
               copyFromBuffer:transferContainer->activeBuffer->handle
                 sourceOffset:source->offset
                     toBuffer:metalBuffer->handle
            destinationOffset:destination->offset
                         size:destination->size];

        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalBuffer);
        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, transferContainer->activeBuffer);
    }
}

static void METAL_CopyTextureToTexture(
    SDL_GPUCommandBuffer *commandBuffer,
    const SDL_GPUTextureLocation *source,
    const SDL_GPUTextureLocation *destination,
    Uint32 w,
    Uint32 h,
    Uint32 d,
    bool cycle)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;
        MetalTextureContainer *srcContainer = (MetalTextureContainer *)source->texture;
        MetalTextureContainer *dstContainer = (MetalTextureContainer *)destination->texture;

        MetalTexture *srcTexture = srcContainer->activeTexture;
        MetalTexture *dstTexture = METAL_INTERNAL_PrepareTextureForWrite(
            renderer,
            dstContainer,
            cycle);

        [metalCommandBuffer->blitEncoder
              copyFromTexture:srcTexture->handle
                  sourceSlice:source->layer
                  sourceLevel:source->mip_level
                 sourceOrigin:MTLOriginMake(source->x, source->y, source->z)
                   sourceSize:MTLSizeMake(w, h, d)
                    toTexture:dstTexture->handle
             destinationSlice:destination->layer
             destinationLevel:destination->mip_level
            destinationOrigin:MTLOriginMake(destination->x, destination->y, destination->z)];

        METAL_INTERNAL_TrackTexture(metalCommandBuffer, srcTexture);
        METAL_INTERNAL_TrackTexture(metalCommandBuffer, dstTexture);
    }
}

static void METAL_CopyBufferToBuffer(
    SDL_GPUCommandBuffer *commandBuffer,
    const SDL_GPUBufferLocation *source,
    const SDL_GPUBufferLocation *destination,
    Uint32 size,
    bool cycle)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;
        MetalBufferContainer *srcContainer = (MetalBufferContainer *)source->buffer;
        MetalBufferContainer *dstContainer = (MetalBufferContainer *)destination->buffer;

        MetalBuffer *srcBuffer = srcContainer->activeBuffer;
        MetalBuffer *dstBuffer = METAL_INTERNAL_PrepareBufferForWrite(
            renderer,
            dstContainer,
            cycle);

        [metalCommandBuffer->blitEncoder
               copyFromBuffer:srcBuffer->handle
                 sourceOffset:source->offset
                     toBuffer:dstBuffer->handle
            destinationOffset:destination->offset
                         size:size];

        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, srcBuffer);
        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, dstBuffer);
    }
}

static void METAL_DownloadFromTexture(
    SDL_GPUCommandBuffer *commandBuffer,
    const SDL_GPUTextureRegion *source,
    const SDL_GPUTextureTransferInfo *destination)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;
        MetalTextureContainer *textureContainer = (MetalTextureContainer *)source->texture;
        MetalTexture *metalTexture = textureContainer->activeTexture;
        MetalBufferContainer *bufferContainer = (MetalBufferContainer *)destination->transfer_buffer;
        Uint32 bufferStride = destination->pixels_per_row;
        Uint32 bufferImageHeight = destination->rows_per_layer;
        Uint32 bytesPerRow, bytesPerDepthSlice;

        MetalBuffer *dstBuffer = METAL_INTERNAL_PrepareBufferForWrite(
            renderer,
            bufferContainer,
            false);

        MTLOrigin regionOrigin = MTLOriginMake(
            source->x,
            source->y,
            source->z);

        MTLSize regionSize = MTLSizeMake(
            source->w,
            source->h,
            source->d);

        if (bufferStride == 0 || bufferImageHeight == 0) {
            bufferStride = source->w;
            bufferImageHeight = source->h;
        }

        bytesPerRow = BytesPerRow(bufferStride, textureContainer->header.info.format);
        bytesPerDepthSlice = bytesPerRow * bufferImageHeight;

        [metalCommandBuffer->blitEncoder
                     copyFromTexture:metalTexture->handle
                         sourceSlice:source->layer
                         sourceLevel:source->mip_level
                        sourceOrigin:regionOrigin
                          sourceSize:regionSize
                            toBuffer:dstBuffer->handle
                   destinationOffset:destination->offset
              destinationBytesPerRow:bytesPerRow
            destinationBytesPerImage:bytesPerDepthSlice];

        METAL_INTERNAL_TrackTexture(metalCommandBuffer, metalTexture);
        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, dstBuffer);
    }
}

static void METAL_DownloadFromBuffer(
    SDL_GPUCommandBuffer *commandBuffer,
    const SDL_GPUBufferRegion *source,
    const SDL_GPUTransferBufferLocation *destination)
{
    SDL_GPUBufferLocation sourceLocation;
    sourceLocation.buffer = source->buffer;
    sourceLocation.offset = source->offset;

    METAL_CopyBufferToBuffer(
        commandBuffer,
        &sourceLocation,
        (SDL_GPUBufferLocation *)destination,
        source->size,
        false);
}

static void METAL_EndCopyPass(
    SDL_GPUCommandBuffer *commandBuffer)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        [metalCommandBuffer->blitEncoder endEncoding];
        metalCommandBuffer->blitEncoder = nil;
    }
}

static void METAL_GenerateMipmaps(
    SDL_GPUCommandBuffer *commandBuffer,
    SDL_GPUTexture *texture)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalTextureContainer *container = (MetalTextureContainer *)texture;
        MetalTexture *metalTexture = container->activeTexture;

        METAL_BeginCopyPass(commandBuffer);
        [metalCommandBuffer->blitEncoder
            generateMipmapsForTexture:metalTexture->handle];
        METAL_EndCopyPass(commandBuffer);

        METAL_INTERNAL_TrackTexture(metalCommandBuffer, metalTexture);
    }
}

// Graphics State

static void METAL_INTERNAL_AllocateCommandBuffers(
    MetalRenderer *renderer,
    Uint32 allocateCount)
{
    MetalCommandBuffer *commandBuffer;

    renderer->availableCommandBufferCapacity += allocateCount;

    renderer->availableCommandBuffers = SDL_realloc(
        renderer->availableCommandBuffers,
        sizeof(MetalCommandBuffer *) * renderer->availableCommandBufferCapacity);

    for (Uint32 i = 0; i < allocateCount; i += 1) {
        commandBuffer = SDL_calloc(1, sizeof(MetalCommandBuffer));
        commandBuffer->renderer = renderer;
        METAL_INTERNAL_AfterglowCreatePassSamples(renderer, commandBuffer);

        // The native Metal command buffer is created in METAL_AcquireCommandBuffer

        commandBuffer->windowDataCapacity = 1;
        commandBuffer->windowDataCount = 0;
        commandBuffer->windowDatas = SDL_calloc(
            commandBuffer->windowDataCapacity, sizeof(MetalWindowData *));

        // Reference Counting
        commandBuffer->usedBufferCapacity = METAL_INLINE_USED_BUFFER_CAPACITY;
        commandBuffer->usedBufferCount = 0;
        commandBuffer->usedBuffers = commandBuffer->inlineUsedBuffers;

        commandBuffer->usedTextureCapacity = METAL_INLINE_USED_TEXTURE_CAPACITY;
        commandBuffer->usedTextureCount = 0;
        commandBuffer->usedTextures = commandBuffer->inlineUsedTextures;

        commandBuffer->usedUniformBufferCapacity = METAL_INLINE_USED_UNIFORM_BUFFER_CAPACITY;
        commandBuffer->usedUniformBufferCount = 0;
        commandBuffer->usedUniformBuffers = commandBuffer->inlineUsedUniformBuffers;

        renderer->availableCommandBuffers[renderer->availableCommandBufferCount] = commandBuffer;
        renderer->availableCommandBufferCount += 1;
    }
}

static MetalCommandBuffer *METAL_INTERNAL_GetInactiveCommandBufferFromPool(
    MetalRenderer *renderer)
{
    MetalCommandBuffer *commandBuffer;

    if (renderer->availableCommandBufferCount == 0) {
        METAL_INTERNAL_AllocateCommandBuffers(
            renderer,
            renderer->availableCommandBufferCapacity);
    }

    commandBuffer = renderer->availableCommandBuffers[renderer->availableCommandBufferCount - 1];
    renderer->availableCommandBufferCount -= 1;

    return commandBuffer;
}

static Uint8 METAL_INTERNAL_CreateFence(
    MetalRenderer *renderer)
{
    MetalFence *fence;

    fence = SDL_calloc(1, sizeof(MetalFence));
    SDL_SetAtomicInt(&fence->referenceCount, 0);

    // Add it to the available pool
    // FIXME: Should this be EXPAND_IF_NEEDED?
    if (renderer->availableFenceCount >= renderer->availableFenceCapacity) {
        renderer->availableFenceCapacity *= 2;

        renderer->availableFences = SDL_realloc(
            renderer->availableFences,
            sizeof(MetalFence *) * renderer->availableFenceCapacity);
    }

    renderer->availableFences[renderer->availableFenceCount] = fence;
    renderer->availableFenceCount += 1;

    return 1;
}

static bool METAL_INTERNAL_AcquireFence(
    MetalRenderer *renderer,
    MetalCommandBuffer *commandBuffer)
{
    MetalFence *fence;

    // Acquire a fence from the pool
    SDL_LockMutex(renderer->fenceLock);

    if (renderer->availableFenceCount == 0) {
        if (!METAL_INTERNAL_CreateFence(renderer)) {
            SDL_UnlockMutex(renderer->fenceLock);
            SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to create fence!");
            return false;
        }
    }

    fence = renderer->availableFences[renderer->availableFenceCount - 1];
    renderer->availableFenceCount -= 1;

    SDL_UnlockMutex(renderer->fenceLock);

    // Associate the fence with the command buffer
    commandBuffer->fence = fence;
    fence->commandBuffer = commandBuffer->handle;
    (void)SDL_AtomicIncRef(&commandBuffer->fence->referenceCount);

    return true;
}

static SDL_GPUCommandBuffer *METAL_AcquireCommandBuffer(
    SDL_GPURenderer *driverData)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalCommandBuffer *commandBuffer;
        const bool trace = METAL_INTERNAL_TimingActive(renderer);
        const Uint64 start = trace ? SDL_GetTicksNS() : 0;

        SDL_LockMutex(renderer->acquireCommandBufferLock);

        commandBuffer = METAL_INTERNAL_GetInactiveCommandBufferFromPool(renderer);
        METAL_INTERNAL_AfterglowAcquireNativeCommandBuffer(renderer, commandBuffer);
        METAL_INTERNAL_AfterglowAcquirePassSamples(renderer, commandBuffer);

        commandBuffer->graphics_pipeline = NULL;
        commandBuffer->compute_pipeline = NULL;
        for (Uint32 i = 0; i < MAX_UNIFORM_BUFFERS_PER_STAGE; i += 1) {
            commandBuffer->vertexUniformBuffers[i] = NULL;
            commandBuffer->fragmentUniformBuffers[i] = NULL;
            commandBuffer->computeUniformBuffers[i] = NULL;
        }

        SDL_UnlockMutex(renderer->acquireCommandBufferLock);

        if (trace) METAL_INTERNAL_TimingAdd(renderer, SDL_ACCELERANDO_GPU_ACQUIRE_COMMAND_BUFFER, SDL_GetTicksNS() - start);

        return (SDL_GPUCommandBuffer *)commandBuffer;
    }
}

// This function assumes that it's called from within an autorelease pool
static MetalUniformBuffer *METAL_INTERNAL_AcquireUniformBufferFromPool(
    MetalCommandBuffer *commandBuffer)
{
    MetalRenderer *renderer = commandBuffer->renderer;
    MetalUniformBuffer *uniformBuffer;

    SDL_LockMutex(renderer->acquireUniformBufferLock);

    if (renderer->uniformBufferPoolCount > 0) {
        uniformBuffer = renderer->uniformBufferPool[renderer->uniformBufferPoolCount - 1];
        renderer->uniformBufferPoolCount -= 1;
    } else {
        uniformBuffer = METAL_INTERNAL_CreateUniformBuffer(
            renderer,
            UNIFORM_BUFFER_SIZE);
    }

    SDL_UnlockMutex(renderer->acquireUniformBufferLock);

    METAL_INTERNAL_TrackUniformBuffer(commandBuffer, uniformBuffer);

    return uniformBuffer;
}

static void METAL_INTERNAL_ReturnUniformBufferToPool(
    MetalRenderer *renderer,
    MetalUniformBuffer *uniformBuffer)
{
    if (renderer->uniformBufferPoolCount >= renderer->uniformBufferPoolCapacity) {
        renderer->uniformBufferPoolCapacity *= 2;
        renderer->uniformBufferPool = SDL_realloc(
            renderer->uniformBufferPool,
            renderer->uniformBufferPoolCapacity * sizeof(MetalUniformBuffer *));
    }

    renderer->uniformBufferPool[renderer->uniformBufferPoolCount] = uniformBuffer;
    renderer->uniformBufferPoolCount += 1;

    uniformBuffer->writeOffset = 0;
    uniformBuffer->drawOffset = 0;
}

static void METAL_SetViewport(
    SDL_GPUCommandBuffer *commandBuffer,
    const SDL_GPUViewport *viewport)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MTLViewport metalViewport;

        metalViewport.originX = viewport->x;
        metalViewport.originY = viewport->y;
        metalViewport.width = viewport->w;
        metalViewport.height = viewport->h;
        metalViewport.znear = viewport->min_depth;
        metalViewport.zfar = viewport->max_depth;

        [metalCommandBuffer->renderEncoder setViewport:metalViewport];
    }
}

static void METAL_SetScissor(
    SDL_GPUCommandBuffer *commandBuffer,
    const SDL_Rect *scissor)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MTLScissorRect metalScissor;

        metalScissor.x = scissor->x;
        metalScissor.y = scissor->y;
        metalScissor.width = scissor->w;
        metalScissor.height = scissor->h;

        [metalCommandBuffer->renderEncoder setScissorRect:metalScissor];
    }
}

static void METAL_SetBlendConstants(
    SDL_GPUCommandBuffer *commandBuffer,
    SDL_FColor blendConstants)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        [metalCommandBuffer->renderEncoder setBlendColorRed:blendConstants.r
                                                      green:blendConstants.g
                                                       blue:blendConstants.b
                                                      alpha:blendConstants.a];
    }
}

static void METAL_SetStencilReference(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint8 reference)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        [metalCommandBuffer->renderEncoder setStencilReferenceValue:reference];
    }
}

static void METAL_BeginRenderPass(
    SDL_GPUCommandBuffer *commandBuffer,
    const SDL_GPUColorTargetInfo *colorTargetInfos,
    Uint32 numColorTargets,
    const SDL_GPUDepthStencilTargetInfo *depthStencilTargetInfo)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;
        MTLRenderPassDescriptor *passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        Uint32 vpWidth = UINT_MAX;
        Uint32 vpHeight = UINT_MAX;
        SDL_GPUViewport viewport;
        SDL_Rect scissorRect;
        SDL_FColor blendConstants;

        for (Uint32 i = 0; i < numColorTargets; i += 1) {
            MetalTextureContainer *container = (MetalTextureContainer *)colorTargetInfos[i].texture;
            MetalTexture *texture = METAL_INTERNAL_PrepareTextureForWrite(
                renderer,
                container,
                colorTargetInfos[i].cycle);

            passDescriptor.colorAttachments[i].texture = texture->handle;
            passDescriptor.colorAttachments[i].level = colorTargetInfos[i].mip_level;
            if (container->header.info.type == SDL_GPU_TEXTURETYPE_3D) {
                passDescriptor.colorAttachments[i].depthPlane = colorTargetInfos[i].layer_or_depth_plane;
            } else {
                passDescriptor.colorAttachments[i].slice = colorTargetInfos[i].layer_or_depth_plane;
            }
            passDescriptor.colorAttachments[i].clearColor = MTLClearColorMake(
                colorTargetInfos[i].clear_color.r,
                colorTargetInfos[i].clear_color.g,
                colorTargetInfos[i].clear_color.b,
                colorTargetInfos[i].clear_color.a);
            passDescriptor.colorAttachments[i].loadAction = SDLToMetal_LoadOp[colorTargetInfos[i].load_op];
            passDescriptor.colorAttachments[i].storeAction = SDLToMetal_StoreOp[colorTargetInfos[i].store_op];

            METAL_INTERNAL_TrackTexture(metalCommandBuffer, texture);

            if (colorTargetInfos[i].store_op == SDL_GPU_STOREOP_RESOLVE || colorTargetInfos[i].store_op == SDL_GPU_STOREOP_RESOLVE_AND_STORE) {
                MetalTextureContainer *resolveContainer = (MetalTextureContainer *)colorTargetInfos[i].resolve_texture;
                MetalTexture *resolveTexture = METAL_INTERNAL_PrepareTextureForWrite(
                    renderer,
                    resolveContainer,
                    colorTargetInfos[i].cycle_resolve_texture);

                passDescriptor.colorAttachments[i].resolveTexture = resolveTexture->handle;
                passDescriptor.colorAttachments[i].resolveSlice = colorTargetInfos[i].resolve_layer;
                passDescriptor.colorAttachments[i].resolveLevel = colorTargetInfos[i].resolve_mip_level;

                METAL_INTERNAL_TrackTexture(metalCommandBuffer, resolveTexture);
            }
        }

        if (depthStencilTargetInfo != NULL) {
            MetalTextureContainer *container = (MetalTextureContainer *)depthStencilTargetInfo->texture;
            MetalTexture *texture = METAL_INTERNAL_PrepareTextureForWrite(
                renderer,
                container,
                depthStencilTargetInfo->cycle);

            passDescriptor.depthAttachment.texture = texture->handle;
            passDescriptor.depthAttachment.level = depthStencilTargetInfo->mip_level;
            passDescriptor.depthAttachment.slice = depthStencilTargetInfo->layer;
            passDescriptor.depthAttachment.loadAction = SDLToMetal_LoadOp[depthStencilTargetInfo->load_op];
            passDescriptor.depthAttachment.storeAction = SDLToMetal_StoreOp[depthStencilTargetInfo->store_op];
            passDescriptor.depthAttachment.clearDepth = depthStencilTargetInfo->clear_depth;

            if (IsStencilFormat(container->header.info.format)) {
                passDescriptor.stencilAttachment.texture = texture->handle;
                passDescriptor.stencilAttachment.loadAction = SDLToMetal_LoadOp[depthStencilTargetInfo->stencil_load_op];
                passDescriptor.stencilAttachment.storeAction = SDLToMetal_StoreOp[depthStencilTargetInfo->stencil_store_op];
                passDescriptor.stencilAttachment.clearStencil = depthStencilTargetInfo->clear_stencil;
            }

            METAL_INTERNAL_TrackTexture(metalCommandBuffer, texture);
        }

        metalCommandBuffer->afterglowActiveTimedPass = -1;
        if (metalCommandBuffer->afterglowPassSampling) {
            AfterglowMetalPassSamples *samples = metalCommandBuffer->afterglowPassSamples;
            if (samples->passCount < AFTERGLOW_MAX_TIMED_PASSES) {
                const Uint32 index = samples->passCount++;
                metalCommandBuffer->afterglowActiveTimedPass = (Sint32)index;
                if (numColorTargets > 0) {
                    samples->passes[index].width = (Uint32)passDescriptor.colorAttachments[0].texture.width >> colorTargetInfos[0].mip_level;
                    samples->passes[index].height = (Uint32)passDescriptor.colorAttachments[0].texture.height >> colorTargetInfos[0].mip_level;
                } else if (depthStencilTargetInfo) {
                    samples->passes[index].width = (Uint32)passDescriptor.depthAttachment.texture.width >> depthStencilTargetInfo->mip_level;
                    samples->passes[index].height = (Uint32)passDescriptor.depthAttachment.texture.height >> depthStencilTargetInfo->mip_level;
                }
                if (@available(macOS 11.0, iOS 14.0, tvOS 14.0, *)) {
                    MTLRenderPassSampleBufferAttachmentDescriptor *attachment = passDescriptor.sampleBufferAttachments[0];
                    attachment.sampleBuffer = samples->buffer;
                    attachment.startOfVertexSampleIndex = index * 4;
                    attachment.endOfVertexSampleIndex = index * 4 + 1;
                    attachment.startOfFragmentSampleIndex = index * 4 + 2;
                    attachment.endOfFragmentSampleIndex = index * 4 + 3;
                }
            } else {
                samples->droppedPasses += 1;
            }
        }
        metalCommandBuffer->renderEncoder = [metalCommandBuffer->handle renderCommandEncoderWithDescriptor:passDescriptor];

        // The viewport cannot be larger than the smallest target.
        for (Uint32 i = 0; i < numColorTargets; i += 1) {
            MetalTextureContainer *container = (MetalTextureContainer *)colorTargetInfos[i].texture;
            Uint32 w = container->header.info.width >> colorTargetInfos[i].mip_level;
            Uint32 h = container->header.info.height >> colorTargetInfos[i].mip_level;

            if (w < vpWidth) {
                vpWidth = w;
            }

            if (h < vpHeight) {
                vpHeight = h;
            }
        }

        if (depthStencilTargetInfo != NULL) {
            MetalTextureContainer *container = (MetalTextureContainer *)depthStencilTargetInfo->texture;
            Uint32 w = container->header.info.width >> depthStencilTargetInfo->mip_level;
            Uint32 h = container->header.info.height >> depthStencilTargetInfo->mip_level;

            if (w < vpWidth) {
                vpWidth = w;
            }

            if (h < vpHeight) {
                vpHeight = h;
            }
        }

        // Set sensible default states
        viewport.x = 0;
        viewport.y = 0;
        viewport.w = vpWidth;
        viewport.h = vpHeight;
        viewport.min_depth = 0;
        viewport.max_depth = 1;
        METAL_SetViewport(commandBuffer, &viewport);

        scissorRect.x = 0;
        scissorRect.y = 0;
        scissorRect.w = vpWidth;
        scissorRect.h = vpHeight;
        METAL_SetScissor(commandBuffer, &scissorRect);

        blendConstants.r = 1.0f;
        blendConstants.g = 1.0f;
        blendConstants.b = 1.0f;
        blendConstants.a = 1.0f;
        METAL_SetBlendConstants(
            commandBuffer,
            blendConstants);

        METAL_SetStencilReference(
            commandBuffer,
            0);
    }
}

static void METAL_BindGraphicsPipeline(
    SDL_GPUCommandBuffer *commandBuffer,
    SDL_GPUGraphicsPipeline *graphicsPipeline)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalGraphicsPipeline *previousPipeline = metalCommandBuffer->graphics_pipeline;
        MetalGraphicsPipeline *pipeline = (MetalGraphicsPipeline *)graphicsPipeline;
        SDL_GPURasterizerState *rast = &pipeline->rasterizerState;
        Uint32 i;

        metalCommandBuffer->graphics_pipeline = pipeline;

        [metalCommandBuffer->renderEncoder setRenderPipelineState:pipeline->handle];

        // Apply rasterizer state
        [metalCommandBuffer->renderEncoder setTriangleFillMode:SDLToMetal_PolygonMode[pipeline->rasterizerState.fill_mode]];
        [metalCommandBuffer->renderEncoder setCullMode:SDLToMetal_CullMode[pipeline->rasterizerState.cull_mode]];
        [metalCommandBuffer->renderEncoder setFrontFacingWinding:SDLToMetal_FrontFace[pipeline->rasterizerState.front_face]];
#ifndef SDL_PLATFORM_VISIONOS
        [metalCommandBuffer->renderEncoder setDepthClipMode:SDLToMetal_DepthClipMode(pipeline->rasterizerState.enable_depth_clip)];
#endif
        [metalCommandBuffer->renderEncoder
            setDepthBias:((rast->enable_depth_bias) ? rast->depth_bias_constant_factor : 0)
              slopeScale:((rast->enable_depth_bias) ? rast->depth_bias_slope_factor : 0)
              clamp:((rast->enable_depth_bias) ? rast->depth_bias_clamp : 0)];

        // Apply depth-stencil state
        if (pipeline->depth_stencil_state != NULL) {
            [metalCommandBuffer->renderEncoder
                setDepthStencilState:pipeline->depth_stencil_state];
        }

        for (i = 0; i < MAX_UNIFORM_BUFFERS_PER_STAGE; i += 1) {
            metalCommandBuffer->needVertexUniformBufferBind[i] = true;
            metalCommandBuffer->needFragmentUniformBufferBind[i] = true;
        }

        for (i = 0; i < pipeline->header.num_vertex_uniform_buffers; i += 1) {
            if (metalCommandBuffer->vertexUniformBuffers[i] == NULL) {
                metalCommandBuffer->vertexUniformBuffers[i] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                    metalCommandBuffer);
            }
        }

        for (i = 0; i < pipeline->header.num_fragment_uniform_buffers; i += 1) {
            if (metalCommandBuffer->fragmentUniformBuffers[i] == NULL) {
                metalCommandBuffer->fragmentUniformBuffers[i] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                    metalCommandBuffer);
            }
        }

        if (previousPipeline && previousPipeline != pipeline) {
            // if the number of uniform buffers has changed, the storage buffers will move as well
            // and need a rebind at their new locations
            if (previousPipeline->header.num_vertex_uniform_buffers != pipeline->header.num_vertex_uniform_buffers) {
                metalCommandBuffer->needVertexStorageBufferBind = true;
            }
            if (previousPipeline->header.num_fragment_uniform_buffers != pipeline->header.num_fragment_uniform_buffers) {
                metalCommandBuffer->needFragmentStorageBufferBind = true;
            }
        }
    }
}

static void METAL_BindVertexBuffers(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    const SDL_GPUBufferBinding *bindings,
    Uint32 numBindings)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;

    for (Uint32 i = 0; i < numBindings; i += 1) {
        MetalBuffer *currentBuffer = ((MetalBufferContainer *)bindings[i].buffer)->activeBuffer;
        if (metalCommandBuffer->vertexBuffers[firstSlot + i] != currentBuffer->handle || metalCommandBuffer->vertexBufferOffsets[firstSlot + i] != bindings[i].offset) {
            metalCommandBuffer->vertexBuffers[firstSlot + i] = currentBuffer->handle;
            metalCommandBuffer->vertexBufferOffsets[firstSlot + i] = bindings[i].offset;
            metalCommandBuffer->needVertexBufferBind = true;
            METAL_INTERNAL_TrackBuffer(metalCommandBuffer, currentBuffer);
        }
    }

    metalCommandBuffer->vertexBufferCount =
        SDL_max(metalCommandBuffer->vertexBufferCount, firstSlot + numBindings);
}

static void METAL_BindIndexBuffer(
    SDL_GPUCommandBuffer *commandBuffer,
    const SDL_GPUBufferBinding *binding,
    SDL_GPUIndexElementSize indexElementSize)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    metalCommandBuffer->indexBuffer = ((MetalBufferContainer *)binding->buffer)->activeBuffer;
    metalCommandBuffer->indexBufferOffset = binding->offset;
    metalCommandBuffer->index_element_size = indexElementSize;

    METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalCommandBuffer->indexBuffer);
}

static void METAL_BindVertexSamplers(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    const SDL_GPUTextureSamplerBinding *textureSamplerBindings,
    Uint32 numBindings)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;
    MetalSampler *sampler;

    for (Uint32 i = 0; i < numBindings; i += 1) {
        textureContainer = (MetalTextureContainer *)textureSamplerBindings[i].texture;
        sampler = (MetalSampler *)textureSamplerBindings[i].sampler;

        if (metalCommandBuffer->vertexSamplers[firstSlot + i] != sampler->handle) {
            metalCommandBuffer->vertexSamplers[firstSlot + i] = sampler->handle;
            metalCommandBuffer->needVertexSamplerBind  = true;
        }

        if (metalCommandBuffer->vertexTextures[firstSlot + i] != textureContainer->activeTexture->handle) {
            METAL_INTERNAL_TrackTexture(
                metalCommandBuffer,
                textureContainer->activeTexture);

            metalCommandBuffer->vertexTextures[firstSlot + i] =
                textureContainer->activeTexture->handle;

            metalCommandBuffer->needVertexSamplerBind  = true;
        }
    }
}

static void METAL_BindVertexStorageTextures(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    SDL_GPUTexture *const *storageTextures,
    Uint32 numBindings)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;

    for (Uint32 i = 0; i < numBindings; i += 1) {
        textureContainer = (MetalTextureContainer *)storageTextures[i];

        if (metalCommandBuffer->vertexStorageTextures[firstSlot + i] != textureContainer->activeTexture->handle) {
            METAL_INTERNAL_TrackTexture(
                metalCommandBuffer,
                textureContainer->activeTexture);

            metalCommandBuffer->vertexStorageTextures[firstSlot + i] =
                textureContainer->activeTexture->handle;

            metalCommandBuffer->needVertexStorageTextureBind = true;
        }
    }
}

static void METAL_BindVertexStorageBuffers(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    SDL_GPUBuffer *const *storageBuffers,
    Uint32 numBindings)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalBufferContainer *bufferContainer;

    for (Uint32 i = 0; i < numBindings; i += 1) {
        bufferContainer = (MetalBufferContainer *)storageBuffers[i];

        if (metalCommandBuffer->vertexStorageBuffers[firstSlot + i] != bufferContainer->activeBuffer->handle) {
            METAL_INTERNAL_TrackBuffer(
                metalCommandBuffer,
                bufferContainer->activeBuffer);

            metalCommandBuffer->vertexStorageBuffers[firstSlot + i] =
                bufferContainer->activeBuffer->handle;

            metalCommandBuffer->needVertexStorageBufferBind = true;
        }
    }
}

static void METAL_BindFragmentSamplers(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    const SDL_GPUTextureSamplerBinding *textureSamplerBindings,
    Uint32 numBindings)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;
    MetalSampler *sampler;

    for (Uint32 i = 0; i < numBindings; i += 1) {
        textureContainer = (MetalTextureContainer *)textureSamplerBindings[i].texture;
        sampler = (MetalSampler *)textureSamplerBindings[i].sampler;

        if (metalCommandBuffer->fragmentSamplers[firstSlot + i] != sampler->handle) {
            metalCommandBuffer->fragmentSamplers[firstSlot + i] = sampler->handle;
            metalCommandBuffer->needFragmentSamplerBind  = true;
        }

        if (metalCommandBuffer->fragmentTextures[firstSlot + i] != textureContainer->activeTexture->handle) {
            METAL_INTERNAL_TrackTexture(
                metalCommandBuffer,
                textureContainer->activeTexture);

            metalCommandBuffer->fragmentTextures[firstSlot + i] =
                textureContainer->activeTexture->handle;

            metalCommandBuffer->needFragmentSamplerBind  = true;
        }
    }
}

static void METAL_BindFragmentStorageTextures(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    SDL_GPUTexture *const *storageTextures,
    Uint32 numBindings)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;

    for (Uint32 i = 0; i < numBindings; i += 1) {
        textureContainer = (MetalTextureContainer *)storageTextures[i];

        if (metalCommandBuffer->fragmentStorageTextures[firstSlot + i] != textureContainer->activeTexture->handle) {
            METAL_INTERNAL_TrackTexture(
                metalCommandBuffer,
                textureContainer->activeTexture);

            metalCommandBuffer->fragmentStorageTextures[firstSlot + i] =
                textureContainer->activeTexture->handle;

            metalCommandBuffer->needFragmentStorageTextureBind = true;
        }
    }
}

static void METAL_BindFragmentStorageBuffers(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    SDL_GPUBuffer *const *storageBuffers,
    Uint32 numBindings)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalBufferContainer *bufferContainer;

    for (Uint32 i = 0; i < numBindings; i += 1) {
        bufferContainer = (MetalBufferContainer *)storageBuffers[i];

        if (metalCommandBuffer->fragmentStorageBuffers[firstSlot + i] != bufferContainer->activeBuffer->handle) {
            METAL_INTERNAL_TrackBuffer(
                metalCommandBuffer,
                bufferContainer->activeBuffer);

            metalCommandBuffer->fragmentStorageBuffers[firstSlot + i] =
                bufferContainer->activeBuffer->handle;

            metalCommandBuffer->needFragmentStorageBufferBind = true;
        }
    }
}

// This function assumes that it's called from within an autorelease pool
static void METAL_INTERNAL_BindGraphicsResources(
    MetalCommandBuffer *commandBuffer)
{
    MetalGraphicsPipeline *graphicsPipeline = commandBuffer->graphics_pipeline;
    NSUInteger offsets[MAX_STORAGE_BUFFERS_PER_STAGE] = { 0 };

    // Vertex Buffers
    if (commandBuffer->needVertexBufferBind) {
        id<MTLBuffer> metalBuffers[MAX_VERTEX_BUFFERS];
        NSUInteger bufferOffsets[MAX_VERTEX_BUFFERS];
        NSRange range = NSMakeRange(METAL_FIRST_VERTEX_BUFFER_SLOT, commandBuffer->vertexBufferCount);
        for (Uint32 i = 0; i < commandBuffer->vertexBufferCount; i += 1) {
            metalBuffers[i] = commandBuffer->vertexBuffers[i];
            bufferOffsets[i] = commandBuffer->vertexBufferOffsets[i];
        }
        [commandBuffer->renderEncoder setVertexBuffers:metalBuffers offsets:bufferOffsets withRange:range];
        commandBuffer->needVertexBufferBind = false;
    }

    // Vertex Samplers+Textures

    if (commandBuffer->needVertexSamplerBind) {
        if (graphicsPipeline->header.num_vertex_samplers > 0) {
            [commandBuffer->renderEncoder setVertexSamplerStates:commandBuffer->vertexSamplers
                                                       withRange:NSMakeRange(0, graphicsPipeline->header.num_vertex_samplers)];
            [commandBuffer->renderEncoder setVertexTextures:commandBuffer->vertexTextures
                                                  withRange:NSMakeRange(0, graphicsPipeline->header.num_vertex_samplers)];
        }
        commandBuffer->needVertexSamplerBind = false;
    }

    // Vertex Storage Textures

    if (commandBuffer->needVertexStorageTextureBind) {
        if (graphicsPipeline->header.num_vertex_storage_textures > 0) {
            [commandBuffer->renderEncoder setVertexTextures:commandBuffer->vertexStorageTextures
                                                  withRange:NSMakeRange(graphicsPipeline->header.num_vertex_samplers,
                                                                        graphicsPipeline->header.num_vertex_storage_textures)];
        }
        commandBuffer->needVertexStorageTextureBind = false;
    }

    // Vertex Storage Buffers

    if (commandBuffer->needVertexStorageBufferBind) {
        if (graphicsPipeline->header.num_vertex_storage_buffers > 0) {
            [commandBuffer->renderEncoder setVertexBuffers:commandBuffer->vertexStorageBuffers
                                                   offsets:offsets
                                                 withRange:NSMakeRange(graphicsPipeline->header.num_vertex_uniform_buffers,
                                                                       graphicsPipeline->header.num_vertex_storage_buffers)];
        }
        commandBuffer->needVertexStorageBufferBind = false;
    }

    // Vertex Uniform Buffers

    for (Uint32 i = 0; i < graphicsPipeline->header.num_vertex_uniform_buffers; i += 1) {
        if (commandBuffer->needVertexUniformBufferBind[i]) {
            if (graphicsPipeline->header.num_vertex_uniform_buffers > i) {
                [commandBuffer->renderEncoder
                    setVertexBuffer:commandBuffer->vertexUniformBuffers[i]->handle
                             offset:commandBuffer->vertexUniformBuffers[i]->drawOffset
                            atIndex:i];
            }
            commandBuffer->needVertexUniformBufferBind[i] = false;
        }
    }

    // Fragment Samplers+Textures

    if (commandBuffer->needFragmentSamplerBind) {
        if (graphicsPipeline->header.num_fragment_samplers > 0) {
            [commandBuffer->renderEncoder setFragmentSamplerStates:commandBuffer->fragmentSamplers
                                                         withRange:NSMakeRange(0, graphicsPipeline->header.num_fragment_samplers)];
            [commandBuffer->renderEncoder setFragmentTextures:commandBuffer->fragmentTextures
                                                    withRange:NSMakeRange(0, graphicsPipeline->header.num_fragment_samplers)];
        }
        commandBuffer->needFragmentSamplerBind = false;
    }

    // Fragment Storage Textures

    if (commandBuffer->needFragmentStorageTextureBind) {
        if (graphicsPipeline->header.num_fragment_storage_textures > 0) {
            [commandBuffer->renderEncoder setFragmentTextures:commandBuffer->fragmentStorageTextures
                                                    withRange:NSMakeRange(graphicsPipeline->header.num_fragment_samplers,
                                                                          graphicsPipeline->header.num_fragment_storage_textures)];
        }
        commandBuffer->needFragmentStorageTextureBind = false;
    }

    // Fragment Storage Buffers

    if (commandBuffer->needFragmentStorageBufferBind) {
        if (graphicsPipeline->header.num_fragment_storage_buffers > 0) {
            [commandBuffer->renderEncoder setFragmentBuffers:commandBuffer->fragmentStorageBuffers
                                                     offsets:offsets
                                                   withRange:NSMakeRange(graphicsPipeline->header.num_fragment_uniform_buffers,
                                                                         graphicsPipeline->header.num_fragment_storage_buffers)];
        }
        commandBuffer->needFragmentStorageBufferBind = false;
    }

    // Fragment Uniform Buffers

    for (Uint32 i = 0; i < graphicsPipeline->header.num_fragment_uniform_buffers; i += 1) {
        if (commandBuffer->needFragmentUniformBufferBind[i]) {
            if (graphicsPipeline->header.num_fragment_uniform_buffers > i) {
                [commandBuffer->renderEncoder
                    setFragmentBuffer:commandBuffer->fragmentUniformBuffers[i]->handle
                            offset:commandBuffer->fragmentUniformBuffers[i]->drawOffset
                            atIndex:i];
            }
            commandBuffer->needFragmentUniformBufferBind[i] = false;
        }
    }
}

// This function assumes that it's called from within an autorelease pool
static void METAL_INTERNAL_BindComputeResources(
    MetalCommandBuffer *commandBuffer)
{
    MetalComputePipeline *computePipeline = commandBuffer->compute_pipeline;
    NSUInteger offsets[MAX_STORAGE_BUFFERS_PER_STAGE] = { 0 };

    if (commandBuffer->needComputeSamplerBind) {
        if (computePipeline->header.numSamplers > 0) {
            [commandBuffer->computeEncoder setTextures:commandBuffer->computeSamplerTextures
                                             withRange:NSMakeRange(0, computePipeline->header.numSamplers)];
            [commandBuffer->computeEncoder setSamplerStates:commandBuffer->computeSamplers
                                                  withRange:NSMakeRange(0, computePipeline->header.numSamplers)];
        }
        commandBuffer->needComputeSamplerBind = false;
    }

    if (commandBuffer->needComputeReadOnlyStorageTextureBind) {
        if (computePipeline->header.numReadonlyStorageTextures > 0) {
            [commandBuffer->computeEncoder setTextures:commandBuffer->computeReadOnlyTextures
                                             withRange:NSMakeRange(
                                                           computePipeline->header.numSamplers,
                                                           computePipeline->header.numReadonlyStorageTextures)];
        }
        commandBuffer->needComputeReadOnlyStorageTextureBind = false;
    }

    if (commandBuffer->needComputeReadOnlyStorageBufferBind) {
        if (computePipeline->header.numReadonlyStorageBuffers > 0) {
            [commandBuffer->computeEncoder setBuffers:commandBuffer->computeReadOnlyBuffers
                                              offsets:offsets
                                            withRange:NSMakeRange(computePipeline->header.numUniformBuffers,
                                                                  computePipeline->header.numReadonlyStorageBuffers)];
        }
        commandBuffer->needComputeReadOnlyStorageBufferBind = false;
    }

    for (Uint32 i = 0; i < MAX_UNIFORM_BUFFERS_PER_STAGE; i += 1) {
        if (commandBuffer->needComputeUniformBufferBind[i]) {
            if (computePipeline->header.numUniformBuffers > i) {
                [commandBuffer->computeEncoder
                    setBuffer:commandBuffer->computeUniformBuffers[i]->handle
                    offset:commandBuffer->computeUniformBuffers[i]->drawOffset
                    atIndex:i];
            }
        }
        commandBuffer->needComputeUniformBufferBind[i] = false;
    }
}

static void METAL_DrawIndexedPrimitives(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 numIndices,
    Uint32 numInstances,
    Uint32 firstIndex,
    Sint32 vertexOffset,
    Uint32 firstInstance)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        SDL_GPUPrimitiveType primitiveType = metalCommandBuffer->graphics_pipeline->primitiveType;
        Uint32 indexSize = IndexSize(metalCommandBuffer->index_element_size);
        METAL_INTERNAL_AfterglowRecordPassDraw(metalCommandBuffer, 1, (Uint64)numIndices * numInstances);

        METAL_INTERNAL_BindGraphicsResources(metalCommandBuffer);

        [metalCommandBuffer->renderEncoder
            drawIndexedPrimitives:SDLToMetal_PrimitiveType[primitiveType]
                       indexCount:numIndices
                        indexType:SDLToMetal_IndexType[metalCommandBuffer->index_element_size]
                      indexBuffer:metalCommandBuffer->indexBuffer->handle
                indexBufferOffset:metalCommandBuffer->indexBufferOffset + (firstIndex * indexSize)
                    instanceCount:numInstances
                       baseVertex:vertexOffset
                     baseInstance:firstInstance];
    }
}

static void METAL_DrawPrimitives(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 numVertices,
    Uint32 numInstances,
    Uint32 firstVertex,
    Uint32 firstInstance)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        SDL_GPUPrimitiveType primitiveType = metalCommandBuffer->graphics_pipeline->primitiveType;
        METAL_INTERNAL_AfterglowRecordPassDraw(metalCommandBuffer, 1, (Uint64)numVertices * numInstances);

        METAL_INTERNAL_BindGraphicsResources(metalCommandBuffer);

        [metalCommandBuffer->renderEncoder
            drawPrimitives:SDLToMetal_PrimitiveType[primitiveType]
               vertexStart:firstVertex
               vertexCount:numVertices
             instanceCount:numInstances
              baseInstance:firstInstance];
    }
}

static void METAL_DrawPrimitivesIndirect(
    SDL_GPUCommandBuffer *commandBuffer,
    SDL_GPUBuffer *buffer,
    Uint32 offset,
    Uint32 drawCount)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalBuffer *metalBuffer = ((MetalBufferContainer *)buffer)->activeBuffer;
        SDL_GPUPrimitiveType primitiveType = metalCommandBuffer->graphics_pipeline->primitiveType;
        METAL_INTERNAL_AfterglowRecordPassDraw(metalCommandBuffer, drawCount, 0);

        METAL_INTERNAL_BindGraphicsResources(metalCommandBuffer);

        /* Metal: "We have multi-draw at home!"
         * Multi-draw at home:
         */
        for (Uint32 i = 0; i < drawCount; i += 1) {
            [metalCommandBuffer->renderEncoder
                      drawPrimitives:SDLToMetal_PrimitiveType[primitiveType]
                      indirectBuffer:metalBuffer->handle
                indirectBufferOffset:offset + (sizeof(SDL_GPUIndirectDrawCommand) * i)];
        }

        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalBuffer);
    }
}

static void METAL_DrawIndexedPrimitivesIndirect(
    SDL_GPUCommandBuffer *commandBuffer,
    SDL_GPUBuffer *buffer,
    Uint32 offset,
    Uint32 drawCount)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalBuffer *metalBuffer = ((MetalBufferContainer *)buffer)->activeBuffer;
        SDL_GPUPrimitiveType primitiveType = metalCommandBuffer->graphics_pipeline->primitiveType;
        METAL_INTERNAL_AfterglowRecordPassDraw(metalCommandBuffer, drawCount, 0);

        METAL_INTERNAL_BindGraphicsResources(metalCommandBuffer);

        for (Uint32 i = 0; i < drawCount; i += 1) {
            [metalCommandBuffer->renderEncoder
                drawIndexedPrimitives:SDLToMetal_PrimitiveType[primitiveType]
                            indexType:SDLToMetal_IndexType[metalCommandBuffer->index_element_size]
                          indexBuffer:metalCommandBuffer->indexBuffer->handle
                    indexBufferOffset:metalCommandBuffer->indexBufferOffset
                       indirectBuffer:metalBuffer->handle
                 indirectBufferOffset:offset + (sizeof(SDL_GPUIndexedIndirectDrawCommand) * i)];
        }

        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalBuffer);
    }
}

static void METAL_EndRenderPass(
    SDL_GPUCommandBuffer *commandBuffer)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        [metalCommandBuffer->renderEncoder endEncoding];
        metalCommandBuffer->renderEncoder = nil;
        metalCommandBuffer->afterglowActiveTimedPass = -1;

        for (Uint32 i = 0; i < MAX_VERTEX_BUFFERS; i += 1) {
            metalCommandBuffer->vertexBuffers[i] = nil;
            metalCommandBuffer->vertexBufferOffsets[i] = 0;
            metalCommandBuffer->vertexBufferCount = 0;
        }
        for (Uint32 i = 0; i < MAX_TEXTURE_SAMPLERS_PER_STAGE; i += 1) {
            metalCommandBuffer->vertexSamplers[i] = nil;
            metalCommandBuffer->vertexTextures[i] = nil;
            metalCommandBuffer->fragmentSamplers[i] = nil;
            metalCommandBuffer->fragmentTextures[i] = nil;
        }
        for (Uint32 i = 0; i < MAX_STORAGE_TEXTURES_PER_STAGE; i += 1) {
            metalCommandBuffer->vertexStorageTextures[i] = nil;
            metalCommandBuffer->fragmentStorageTextures[i] = nil;
        }
        for (Uint32 i = 0; i < MAX_STORAGE_BUFFERS_PER_STAGE; i += 1) {
            metalCommandBuffer->vertexStorageBuffers[i] = nil;
            metalCommandBuffer->fragmentStorageBuffers[i] = nil;
        }
    }
}

// This function assumes that it's called from within an autorelease pool
static void METAL_INTERNAL_PushUniformData(
    MetalCommandBuffer *metalCommandBuffer,
    SDL_GPUShaderStage shaderStage,
    Uint32 slotIndex,
    const void *data,
    Uint32 length)
{
    MetalUniformBuffer *metalUniformBuffer;
    Uint32 alignedDataLength;

    if (shaderStage == SDL_GPU_SHADERSTAGE_VERTEX) {
        if (metalCommandBuffer->vertexUniformBuffers[slotIndex] == NULL) {
            metalCommandBuffer->vertexUniformBuffers[slotIndex] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                metalCommandBuffer);
        }
        metalUniformBuffer = metalCommandBuffer->vertexUniformBuffers[slotIndex];
    } else if (shaderStage == SDL_GPU_SHADERSTAGE_FRAGMENT) {
        if (metalCommandBuffer->fragmentUniformBuffers[slotIndex] == NULL) {
            metalCommandBuffer->fragmentUniformBuffers[slotIndex] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                metalCommandBuffer);
        }
        metalUniformBuffer = metalCommandBuffer->fragmentUniformBuffers[slotIndex];
    } else if (shaderStage == SDL_GPU_SHADERSTAGE_COMPUTE) {
        if (metalCommandBuffer->computeUniformBuffers[slotIndex] == NULL) {
            metalCommandBuffer->computeUniformBuffers[slotIndex] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                metalCommandBuffer);
        }
        metalUniformBuffer = metalCommandBuffer->computeUniformBuffers[slotIndex];
    } else {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Unrecognized shader stage!");
        return;
    }

    alignedDataLength = METAL_INTERNAL_NextHighestAlignment(
        length,
        256);

    if (metalUniformBuffer->writeOffset + alignedDataLength >= UNIFORM_BUFFER_SIZE) {
        metalUniformBuffer = METAL_INTERNAL_AcquireUniformBufferFromPool(
            metalCommandBuffer);

        metalUniformBuffer->writeOffset = 0;
        metalUniformBuffer->drawOffset = 0;

        if (shaderStage == SDL_GPU_SHADERSTAGE_VERTEX) {
            metalCommandBuffer->vertexUniformBuffers[slotIndex] = metalUniformBuffer;
        } else if (shaderStage == SDL_GPU_SHADERSTAGE_FRAGMENT) {
            metalCommandBuffer->fragmentUniformBuffers[slotIndex] = metalUniformBuffer;
        } else if (shaderStage == SDL_GPU_SHADERSTAGE_COMPUTE) {
            metalCommandBuffer->computeUniformBuffers[slotIndex] = metalUniformBuffer;
        } else {
            SDL_LogError(SDL_LOG_CATEGORY_GPU, "Unrecognized shader stage!");
            return;
        }
    }

    metalUniformBuffer->drawOffset = metalUniformBuffer->writeOffset;

    SDL_memcpy(
        (metalUniformBuffer->handle).contents + metalUniformBuffer->writeOffset,
        data,
        length);

    metalUniformBuffer->writeOffset += alignedDataLength;

    if (shaderStage == SDL_GPU_SHADERSTAGE_VERTEX) {
        metalCommandBuffer->needVertexUniformBufferBind[slotIndex] = true;
    } else if (shaderStage == SDL_GPU_SHADERSTAGE_FRAGMENT) {
        metalCommandBuffer->needFragmentUniformBufferBind[slotIndex] = true;
    } else if (shaderStage == SDL_GPU_SHADERSTAGE_COMPUTE) {
        metalCommandBuffer->needComputeUniformBufferBind[slotIndex] = true;
    } else {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Unrecognized shader stage!");
    }
}

static void METAL_PushVertexUniformData(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 slotIndex,
    const void *data,
    Uint32 length)
{
    @autoreleasepool {
        METAL_INTERNAL_PushUniformData(
            (MetalCommandBuffer *)commandBuffer,
            SDL_GPU_SHADERSTAGE_VERTEX,
            slotIndex,
            data,
            length);
    }
}

static void METAL_PushFragmentUniformData(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 slotIndex,
    const void *data,
    Uint32 length)
{
    @autoreleasepool {
        METAL_INTERNAL_PushUniformData(
            (MetalCommandBuffer *)commandBuffer,
            SDL_GPU_SHADERSTAGE_FRAGMENT,
            slotIndex,
            data,
            length);
    }
}

// Blit

static void METAL_Blit(
    SDL_GPUCommandBuffer *commandBuffer,
    const SDL_GPUBlitInfo *info)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalRenderer *renderer = (MetalRenderer *)metalCommandBuffer->renderer;

    SDL_GPU_BlitCommon(
        commandBuffer,
        info,
        renderer->blitLinearSampler,
        renderer->blitNearestSampler,
        renderer->blitVertexShader,
        renderer->blitFrom2DShader,
        renderer->blitFrom2DArrayShader,
        renderer->blitFrom3DShader,
        renderer->blitFromCubeShader,
        renderer->blitFromCubeArrayShader,
        &renderer->blitPipelines,
        &renderer->blitPipelineCount,
        &renderer->blitPipelineCapacity);
}

// Compute State

static void METAL_BeginComputePass(
    SDL_GPUCommandBuffer *commandBuffer,
    const SDL_GPUStorageTextureReadWriteBinding *storageTextureBindings,
    Uint32 numStorageTextureBindings,
    const SDL_GPUStorageBufferReadWriteBinding *storageBufferBindings,
    Uint32 numStorageBufferBindings)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalTextureContainer *textureContainer;
        MetalTexture *texture;
        id<MTLTexture> textureView;
        MetalBufferContainer *bufferContainer;
        MetalBuffer *buffer;

        metalCommandBuffer->computeEncoder = [metalCommandBuffer->handle computeCommandEncoder];

        for (Uint32 i = 0; i < numStorageTextureBindings; i += 1) {
            textureContainer = (MetalTextureContainer *)storageTextureBindings[i].texture;

            texture = METAL_INTERNAL_PrepareTextureForWrite(
                metalCommandBuffer->renderer,
                textureContainer,
                storageTextureBindings[i].cycle);

            METAL_INTERNAL_TrackTexture(metalCommandBuffer, texture);

            textureView = [texture->handle newTextureViewWithPixelFormat:SDLToMetal_TextureFormat(textureContainer->header.info.format)
                                                             textureType:SDLToMetal_TextureType(textureContainer->header.info.type, false)
                                                                  levels:NSMakeRange(storageTextureBindings[i].mip_level, 1)
                                                                  slices:NSMakeRange(storageTextureBindings[i].layer, 1)];

            metalCommandBuffer->computeReadWriteTextures[i] = textureView;
        }

        for (Uint32 i = 0; i < numStorageBufferBindings; i += 1) {
            bufferContainer = (MetalBufferContainer *)storageBufferBindings[i].buffer;

            buffer = METAL_INTERNAL_PrepareBufferForWrite(
                metalCommandBuffer->renderer,
                bufferContainer,
                storageBufferBindings[i].cycle);

            METAL_INTERNAL_TrackBuffer(
                metalCommandBuffer,
                buffer);

            metalCommandBuffer->computeReadWriteBuffers[i] = buffer->handle;
        }
    }
}

static void METAL_BindComputePipeline(
    SDL_GPUCommandBuffer *commandBuffer,
    SDL_GPUComputePipeline *computePipeline)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalComputePipeline *pipeline = (MetalComputePipeline *)computePipeline;

        metalCommandBuffer->compute_pipeline = pipeline;

        [metalCommandBuffer->computeEncoder setComputePipelineState:pipeline->handle];

        for (Uint32 i = 0; i < MAX_UNIFORM_BUFFERS_PER_STAGE; i += 1) {
            metalCommandBuffer->needComputeUniformBufferBind[i] = true;
        }

        for (Uint32 i = 0; i < pipeline->header.numUniformBuffers; i += 1) {
            if (metalCommandBuffer->computeUniformBuffers[i] == NULL) {
                metalCommandBuffer->computeUniformBuffers[i] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                    metalCommandBuffer);
            }
        }

        // Bind write-only resources
        if (pipeline->header.numReadWriteStorageTextures > 0) {
            [metalCommandBuffer->computeEncoder setTextures:metalCommandBuffer->computeReadWriteTextures
                                                  withRange:NSMakeRange(
                                                        pipeline->header.numSamplers +
                                                            pipeline->header.numReadonlyStorageTextures,
                                                        pipeline->header.numReadWriteStorageTextures)];
        }

        NSUInteger offsets[MAX_COMPUTE_WRITE_BUFFERS] = { 0 };
        if (pipeline->header.numReadWriteStorageBuffers > 0) {
            [metalCommandBuffer->computeEncoder setBuffers:metalCommandBuffer->computeReadWriteBuffers
                                                   offsets:offsets
                                                 withRange:NSMakeRange(
                                                        pipeline->header.numUniformBuffers +
                                                            pipeline->header.numReadonlyStorageBuffers,
                                                        pipeline->header.numReadWriteStorageBuffers)];
        }
    }
}

static void METAL_BindComputeSamplers(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    const SDL_GPUTextureSamplerBinding *textureSamplerBindings,
    Uint32 numBindings)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;
    MetalSampler *sampler;

    for (Uint32 i = 0; i < numBindings; i += 1) {
        textureContainer = (MetalTextureContainer *)textureSamplerBindings[i].texture;
        sampler = (MetalSampler *)textureSamplerBindings[i].sampler;

        if (metalCommandBuffer->computeSamplers[firstSlot + i] != sampler->handle) {
            metalCommandBuffer->computeSamplers[firstSlot + i] = sampler->handle;
            metalCommandBuffer->needComputeSamplerBind = true;
        }

        if (metalCommandBuffer->computeSamplerTextures[firstSlot + i] != textureContainer->activeTexture->handle) {
            METAL_INTERNAL_TrackTexture(
                metalCommandBuffer,
                textureContainer->activeTexture);

            metalCommandBuffer->computeSamplerTextures[firstSlot + i] =
                textureContainer->activeTexture->handle;

            metalCommandBuffer->needComputeSamplerBind = true;
        }
    }
}

static void METAL_BindComputeStorageTextures(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    SDL_GPUTexture *const *storageTextures,
    Uint32 numBindings)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;

    for (Uint32 i = 0; i < numBindings; i += 1) {
        textureContainer = (MetalTextureContainer *)storageTextures[i];

        if (metalCommandBuffer->computeReadOnlyTextures[firstSlot + i] != textureContainer->activeTexture->handle) {
            METAL_INTERNAL_TrackTexture(
                metalCommandBuffer,
                textureContainer->activeTexture);

            metalCommandBuffer->computeReadOnlyTextures[firstSlot + i] =
                textureContainer->activeTexture->handle;

            metalCommandBuffer->needComputeReadOnlyStorageTextureBind = true;
        }
    }
}

static void METAL_BindComputeStorageBuffers(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    SDL_GPUBuffer *const *storageBuffers,
    Uint32 numBindings)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalBufferContainer *bufferContainer;

    for (Uint32 i = 0; i < numBindings; i += 1) {
        bufferContainer = (MetalBufferContainer *)storageBuffers[i];

        if (metalCommandBuffer->computeReadOnlyBuffers[firstSlot + i] != bufferContainer->activeBuffer->handle) {
            METAL_INTERNAL_TrackBuffer(
                metalCommandBuffer,
                bufferContainer->activeBuffer);

            metalCommandBuffer->computeReadOnlyBuffers[firstSlot + i] =
                bufferContainer->activeBuffer->handle;

            metalCommandBuffer->needComputeReadOnlyStorageBufferBind = true;
        }
    }
}

static void METAL_PushComputeUniformData(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 slotIndex,
    const void *data,
    Uint32 length)
{
    @autoreleasepool {
        METAL_INTERNAL_PushUniformData(
            (MetalCommandBuffer *)commandBuffer,
            SDL_GPU_SHADERSTAGE_COMPUTE,
            slotIndex,
            data,
            length);
    }
}

static void METAL_DispatchCompute(
    SDL_GPUCommandBuffer *commandBuffer,
    Uint32 groupcountX,
    Uint32 groupcountY,
    Uint32 groupcountZ)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MTLSize threadgroups = MTLSizeMake(groupcountX, groupcountY, groupcountZ);
        MTLSize threadsPerThreadgroup = MTLSizeMake(
            metalCommandBuffer->compute_pipeline->threadcountX,
            metalCommandBuffer->compute_pipeline->threadcountY,
            metalCommandBuffer->compute_pipeline->threadcountZ);

        METAL_INTERNAL_BindComputeResources(metalCommandBuffer);

        [metalCommandBuffer->computeEncoder
             dispatchThreadgroups:threadgroups
            threadsPerThreadgroup:threadsPerThreadgroup];
    }
}

static void METAL_DispatchComputeIndirect(
    SDL_GPUCommandBuffer *commandBuffer,
    SDL_GPUBuffer *buffer,
    Uint32 offset)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalBuffer *metalBuffer = ((MetalBufferContainer *)buffer)->activeBuffer;
        MTLSize threadsPerThreadgroup = MTLSizeMake(
            metalCommandBuffer->compute_pipeline->threadcountX,
            metalCommandBuffer->compute_pipeline->threadcountY,
            metalCommandBuffer->compute_pipeline->threadcountZ);

        METAL_INTERNAL_BindComputeResources(metalCommandBuffer);

        [metalCommandBuffer->computeEncoder
            dispatchThreadgroupsWithIndirectBuffer:metalBuffer->handle
                              indirectBufferOffset:offset
                             threadsPerThreadgroup:threadsPerThreadgroup];

        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalBuffer);
    }
}

static void METAL_EndComputePass(
    SDL_GPUCommandBuffer *commandBuffer)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        [metalCommandBuffer->computeEncoder endEncoding];
        metalCommandBuffer->computeEncoder = nil;

        for (Uint32 i = 0; i < MAX_TEXTURE_SAMPLERS_PER_STAGE; i += 1) {
            metalCommandBuffer->computeSamplers[i] = nil;
            metalCommandBuffer->computeSamplerTextures[i] = nil;
        }
        for (Uint32 i = 0; i < MAX_COMPUTE_WRITE_TEXTURES; i += 1) {
            metalCommandBuffer->computeReadWriteTextures[i] = nil;
        }
        for (Uint32 i = 0; i < MAX_COMPUTE_WRITE_BUFFERS; i += 1) {
            metalCommandBuffer->computeReadWriteBuffers[i] = nil;
        }
        for (Uint32 i = 0; i < MAX_STORAGE_TEXTURES_PER_STAGE; i += 1) {
            metalCommandBuffer->computeReadOnlyTextures[i] = nil;
        }
        for (Uint32 i = 0; i < MAX_STORAGE_BUFFERS_PER_STAGE; i += 1) {
            metalCommandBuffer->computeReadOnlyBuffers[i] = nil;
        }
    }
}

// Fence Cleanup

static void METAL_INTERNAL_ReleaseFenceToPool(
    MetalRenderer *renderer,
    MetalFence *fence)
{
    SDL_LockMutex(renderer->fenceLock);

    // FIXME: Should this use EXPAND_IF_NEEDED?
    if (renderer->availableFenceCount == renderer->availableFenceCapacity) {
        renderer->availableFenceCapacity *= 2;
        renderer->availableFences = SDL_realloc(
            renderer->availableFences,
            renderer->availableFenceCapacity * sizeof(MetalFence *));
    }
    renderer->availableFences[renderer->availableFenceCount] = fence;
    renderer->availableFenceCount += 1;

    SDL_UnlockMutex(renderer->fenceLock);
}

static void METAL_ReleaseFence(
    SDL_GPURenderer *driverData,
    SDL_GPUFence *fence)
{
    MetalFence *metalFence = (MetalFence *)fence;
    if (SDL_AtomicDecRef(&metalFence->referenceCount)) {
        // Nothing references the fence anymore, so the command buffer can go too.
        metalFence->commandBuffer = nil;
        METAL_INTERNAL_ReleaseFenceToPool(
            (MetalRenderer *)driverData,
            (MetalFence *)fence);
    }
}

// Cleanup

static void METAL_INTERNAL_CleanCommandBuffer(
    MetalRenderer *renderer,
    MetalCommandBuffer *commandBuffer,
    bool cancel)
{
    Uint32 i;

    // End any active passes
    if (commandBuffer->renderEncoder) {
        [commandBuffer->renderEncoder endEncoding];
        commandBuffer->renderEncoder = nil;
    }
    if (commandBuffer->computeEncoder) {
        [commandBuffer->computeEncoder endEncoding];
        commandBuffer->computeEncoder = nil;
    }
    if (commandBuffer->blitEncoder) {
        [commandBuffer->blitEncoder endEncoding];
        commandBuffer->blitEncoder = nil;
    }

    // Uniform buffers are now available

    SDL_LockMutex(renderer->acquireUniformBufferLock);

    for (i = 0; i < commandBuffer->usedUniformBufferCount; i += 1) {
        METAL_INTERNAL_ReturnUniformBufferToPool(
            renderer,
            commandBuffer->usedUniformBuffers[i]);
    }
    commandBuffer->usedUniformBufferCount = 0;

    SDL_UnlockMutex(renderer->acquireUniformBufferLock);

    // Reference Counting

    for (i = 0; i < commandBuffer->usedBufferCount; i += 1) {
        (void)SDL_AtomicDecRef(&commandBuffer->usedBuffers[i]->referenceCount);
    }
    commandBuffer->usedBufferCount = 0;

    for (i = 0; i < commandBuffer->usedTextureCount; i += 1) {
        (void)SDL_AtomicDecRef(&commandBuffer->usedTextures[i]->referenceCount);
    }
    commandBuffer->usedTextureCount = 0;

    // Reset presentation
    commandBuffer->windowDataCount = 0;

    // Reset bindings
    for (i = 0; i < MAX_VERTEX_BUFFERS; i += 1) {
        commandBuffer->vertexBuffers[i] = nil;
        commandBuffer->vertexBufferOffsets[i] = 0;
    }
    commandBuffer->vertexBufferCount = 0;
    commandBuffer->indexBuffer = NULL;
    for (i = 0; i < MAX_TEXTURE_SAMPLERS_PER_STAGE; i += 1) {
        commandBuffer->vertexSamplers[i] = nil;
        commandBuffer->vertexTextures[i] = nil;
        commandBuffer->fragmentSamplers[i] = nil;
        commandBuffer->fragmentTextures[i] = nil;
        commandBuffer->computeSamplers[i] = nil;
        commandBuffer->computeSamplerTextures[i] = nil;
    }
    for (i = 0; i < MAX_STORAGE_TEXTURES_PER_STAGE; i += 1) {
        commandBuffer->vertexStorageTextures[i] = nil;
        commandBuffer->fragmentStorageTextures[i] = nil;
        commandBuffer->computeReadOnlyTextures[i] = nil;
    }
    for (i = 0; i < MAX_STORAGE_BUFFERS_PER_STAGE; i += 1) {
        commandBuffer->vertexStorageBuffers[i] = nil;
        commandBuffer->fragmentStorageBuffers[i] = nil;
        commandBuffer->computeReadOnlyBuffers[i] = nil;
    }
    for (i = 0; i < MAX_COMPUTE_WRITE_TEXTURES; i += 1) {
        commandBuffer->computeReadWriteTextures[i] = nil;
    }
    for (i = 0; i < MAX_COMPUTE_WRITE_BUFFERS; i += 1) {
        commandBuffer->computeReadWriteBuffers[i] = nil;
    }

    commandBuffer->needVertexBufferBind = false;
    commandBuffer->needVertexSamplerBind = false;
    commandBuffer->needVertexStorageBufferBind = false;
    commandBuffer->needVertexStorageTextureBind = false;
    SDL_zeroa(commandBuffer->needVertexUniformBufferBind);

    commandBuffer->needFragmentSamplerBind = false;
    commandBuffer->needFragmentStorageBufferBind = false;
    commandBuffer->needFragmentStorageTextureBind = false;
    SDL_zeroa(commandBuffer->needFragmentUniformBufferBind);

    commandBuffer->needComputeSamplerBind = false;
    commandBuffer->needComputeReadOnlyStorageBufferBind = false;
    commandBuffer->needComputeReadOnlyStorageTextureBind = false;
    SDL_zeroa(commandBuffer->needComputeUniformBufferBind);

    if (cancel && commandBuffer->afterglowPassSampling) {
        SDL_SetAtomicInt(&commandBuffer->afterglowPassSamples->busy, 0);
        commandBuffer->afterglowPassSampling = false;
    }

    // Drop the command buffer's reference to the fence. A cancelled
    // command buffer never acquired one.
    if (!cancel) {
        METAL_ReleaseFence(
            (SDL_GPURenderer *)renderer,
            (SDL_GPUFence *)commandBuffer->fence);
    }

    // Return command buffer to pool
    SDL_LockMutex(renderer->acquireCommandBufferLock);
    // FIXME: Should this use EXPAND_IF_NEEDED?
    if (renderer->availableCommandBufferCount == renderer->availableCommandBufferCapacity) {
        renderer->availableCommandBufferCapacity += 1;
        renderer->availableCommandBuffers = SDL_realloc(
            renderer->availableCommandBuffers,
            renderer->availableCommandBufferCapacity * sizeof(MetalCommandBuffer *));
    }
    renderer->availableCommandBuffers[renderer->availableCommandBufferCount] = commandBuffer;
    renderer->availableCommandBufferCount += 1;
    SDL_UnlockMutex(renderer->acquireCommandBufferLock);

    // Remove this command buffer from the submitted list
    if (!cancel) {
        for (i = 0; i < renderer->submittedCommandBufferCount; i += 1) {
            if (renderer->submittedCommandBuffers[i] == commandBuffer) {
                renderer->submittedCommandBuffers[i] = renderer->submittedCommandBuffers[renderer->submittedCommandBufferCount - 1];
                renderer->submittedCommandBufferCount -= 1;
            }
        }
    }
}

// This function assumes that it's called from within an autorelease pool
static void METAL_INTERNAL_PerformPendingDestroys(
    MetalRenderer *renderer)
{
    Sint32 referenceCount = 0;
    Sint32 i;
    Uint32 j;

    SDL_LockMutex(renderer->disposeLock);

    for (i = renderer->bufferContainersToDestroyCount - 1; i >= 0; i -= 1) {
        referenceCount = 0;
        for (j = 0; j < renderer->bufferContainersToDestroy[i]->bufferCount; j += 1) {
            referenceCount += SDL_GetAtomicInt(&renderer->bufferContainersToDestroy[i]->buffers[j]->referenceCount);
        }

        if (referenceCount == 0) {
            METAL_INTERNAL_DestroyBufferContainer(
                renderer->bufferContainersToDestroy[i]);

            renderer->bufferContainersToDestroy[i] = renderer->bufferContainersToDestroy[renderer->bufferContainersToDestroyCount - 1];
            renderer->bufferContainersToDestroyCount -= 1;
        }
    }

    for (i = renderer->textureContainersToDestroyCount - 1; i >= 0; i -= 1) {
        referenceCount = 0;
        for (j = 0; j < renderer->textureContainersToDestroy[i]->textureCount; j += 1) {
            referenceCount += SDL_GetAtomicInt(&renderer->textureContainersToDestroy[i]->textures[j]->referenceCount);
        }

        if (referenceCount == 0) {
            METAL_INTERNAL_DestroyTextureContainer(
                renderer->textureContainersToDestroy[i]);

            renderer->textureContainersToDestroy[i] = renderer->textureContainersToDestroy[renderer->textureContainersToDestroyCount - 1];
            renderer->textureContainersToDestroyCount -= 1;
        }
    }

    SDL_UnlockMutex(renderer->disposeLock);
}

// Fences
static bool METAL_INTERNAL_IsFenceBusy(
        MetalFence *fence
) {
    MTLCommandBufferStatus status = fence->commandBuffer.status;
    return status == MTLCommandBufferStatusCommitted || status == MTLCommandBufferStatusScheduled;
}

static bool METAL_WaitForFences(
    SDL_GPURenderer *driverData,
    bool waitAll,
    SDL_GPUFence *const *fences,
    Uint32 numFences)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        const bool diagnose = renderer->afterglowDiagnosticsEnabled;
        // AFTERGLOW TEMPORARY DIAGNOSTIC: negative uses the upstream blocking
        // wait; zero polls, and positive values sleep between status polls.
        // Read once per wait. The default preserves the upstream behavior.
        const Sint64 requestedSleepNs = SDL_GetNumberProperty(
            renderer->props, "afterglow.metal.fence_sleep_ns", -1);
        const Uint64 sleepNs = requestedSleepNs > 0 ? (Uint64)requestedSleepNs : 0;
        const Uint64 waitStart = diagnose ? SDL_GetTicksNS() : 0;
        const Uint64 submission = diagnose && numFences > 0
            ? ((MetalFence *)fences[0])->afterglowDiagnosticSubmission : 0;
        const bool trace = METAL_INTERNAL_TimingActive(renderer);
        Uint64 start = 0;
        if (trace) {
            METAL_INTERNAL_TimingSignpost(renderer, SDL_ACCELERANDO_GPU_FENCE_WAIT, true);
            start = SDL_GetTicksNS();
        }

        if (waitAll) {
            for (Uint32 i = 0; i < numFences; i += 1) {
                MetalFence *fence = (MetalFence *)fences[i];
                if (requestedSleepNs < 0) {
                    [fence->commandBuffer waitUntilCompleted];
                } else {
                    while (METAL_INTERNAL_IsFenceBusy(fence)) {
                        if (sleepNs > 0) {
                            SDL_DelayNS(sleepNs);
                        }
                    }
                }
            }
        } else {
            // Metal cannot attach completion handlers after submission, so
            // upstream also polls when waiting for any fence, even in block mode.
            bool waiting = true;
            while (waiting) {
                for (Uint32 i = 0; i < numFences; i += 1) {
                    MetalFence *fence = (MetalFence *)fences[i];
                    if (!METAL_INTERNAL_IsFenceBusy(fence)) {
                        waiting = false;
                        break;
                    }
                }
                if (waiting && sleepNs > 0) {
                    SDL_DelayNS(sleepNs);
                }
            }
        }

        if (trace) {
            METAL_INTERNAL_TimingAdd(renderer, SDL_ACCELERANDO_GPU_FENCE_WAIT, SDL_GetTicksNS() - start);
            METAL_INTERNAL_TimingSignpost(renderer, SDL_ACCELERANDO_GPU_FENCE_WAIT, false);
        }

        // Time only the fence wait, excluding pending-destroy cleanup and
        // this diagnostic's own logging cost.
        if (diagnose) {
            const Uint64 waitEnd = SDL_GetTicksNS();
            if (waitEnd - waitStart > 12000000ULL) {
                SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
                    "AfterglowMetal/fence_wait submission=%" SDL_PRIu64
                    " start_ns=%" SDL_PRIu64 " end_ns=%" SDL_PRIu64
                    " wait_ms=%.3f fences=%u all=%d",
                    submission, waitStart, waitEnd,
                    (double)(waitEnd - waitStart) / 1000000.0,
                    numFences, waitAll);
            }
        }

        if (trace) start = SDL_GetTicksNS();
        METAL_INTERNAL_PerformPendingDestroys(renderer);
        if (trace) METAL_INTERNAL_TimingAdd(renderer, SDL_ACCELERANDO_GPU_FENCE_CLEANUP, SDL_GetTicksNS() - start);

        return true;
    }
}

static bool METAL_QueryFence(
    SDL_GPURenderer *driverData,
    SDL_GPUFence *fence)
{
    MetalFence *metalFence = (MetalFence *)fence;
    return !METAL_INTERNAL_IsFenceBusy(metalFence);
}

// Window and Swapchain Management

static MetalWindowData *METAL_INTERNAL_FetchWindowData(SDL_Window *window)
{
    SDL_PropertiesID properties = SDL_GetWindowProperties(window);
    return (MetalWindowData *)SDL_GetPointerProperty(properties, WINDOW_PROPERTY_DATA, NULL);
}

static bool METAL_SupportsSwapchainComposition(
    SDL_GPURenderer *driverData,
    SDL_Window *window,
    SDL_GPUSwapchainComposition swapchainComposition)
{
#ifndef SDL_PLATFORM_MACOS
    if (swapchainComposition == SDL_GPU_SWAPCHAINCOMPOSITION_HDR10_ST2084) {
        return false;
    }
#endif

    if (@available(macOS 11.0, *)) {
        return true;
    } else {
        return swapchainComposition != SDL_GPU_SWAPCHAINCOMPOSITION_HDR10_ST2084;
    }
}

// This function assumes that it's called from within an autorelease pool
static bool METAL_INTERNAL_CreateSwapchain(
    MetalRenderer *renderer,
    MetalWindowData *windowData,
    SDL_GPUSwapchainComposition swapchainComposition,
    SDL_GPUPresentMode presentMode)
{
    CGColorSpaceRef colorspace;
    CGSize drawableSize;

    windowData->view = SDL_Metal_CreateView(windowData->window);
    windowData->drawable = nil;
    windowData->presentMode = SDL_GPU_PRESENTMODE_VSYNC;
    windowData->frameCounter = 0;

    for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; i += 1) {
        windowData->inFlightFences[i] = NULL;
    }

    windowData->layer = (__bridge CAMetalLayer *)(SDL_Metal_GetLayer(windowData->view));
    windowData->layer.device = renderer->device;
#ifdef SDL_PLATFORM_MACOS
    if (@available(macOS 10.13, *)) {
        windowData->layer.displaySyncEnabled = (presentMode != SDL_GPU_PRESENTMODE_IMMEDIATE);
        windowData->presentMode = presentMode;
    }
#endif
    windowData->layer.pixelFormat = SDLToMetal_TextureFormat(SwapchainCompositionToFormat[swapchainComposition]);
#ifndef SDL_PLATFORM_TVOS
    if (@available(iOS 16.0, *)) {
        windowData->layer.wantsExtendedDynamicRangeContent = (swapchainComposition != SDL_GPU_SWAPCHAINCOMPOSITION_SDR);
    }
#endif

    colorspace = CGColorSpaceCreateWithName(SwapchainCompositionToColorSpace[swapchainComposition]);
    windowData->layer.colorspace = colorspace;
    CGColorSpaceRelease(colorspace);

    windowData->texture.handle = nil; // This will be set in AcquireSwapchainTexture.

    // Precache blit pipelines for the swapchain format
    for (Uint32 i = 0; i < 4; i += 1) {
        SDL_GPU_FetchBlitPipeline(
            renderer->sdlGPUDevice,
            (SDL_GPUTextureType)i,
            SwapchainCompositionToFormat[swapchainComposition],
            renderer->blitVertexShader,
            renderer->blitFrom2DShader,
            renderer->blitFrom2DArrayShader,
            renderer->blitFrom3DShader,
            renderer->blitFromCubeShader,
            renderer->blitFromCubeArrayShader,
            &renderer->blitPipelines,
            &renderer->blitPipelineCount,
            &renderer->blitPipelineCapacity);
    }

    // Set up the texture container
    SDL_zero(windowData->textureContainer);
    windowData->textureContainer.canBeCycled = 0;
    windowData->textureContainer.activeTexture = &windowData->texture;
    windowData->textureContainer.textureCapacity = 1;
    windowData->textureContainer.textureCount = 1;
    windowData->textureContainer.header.info.format = SwapchainCompositionToFormat[swapchainComposition];
    windowData->textureContainer.header.info.num_levels = 1;
    windowData->textureContainer.header.info.layer_count_or_depth = 1;
    windowData->textureContainer.header.info.type = SDL_GPU_TEXTURETYPE_2D;
    windowData->textureContainer.header.info.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;

    drawableSize = windowData->layer.drawableSize;
    windowData->textureContainer.header.info.width = (Uint32)drawableSize.width;
    windowData->textureContainer.header.info.height = (Uint32)drawableSize.height;

    return true;
}

static bool METAL_SupportsPresentMode(
    SDL_GPURenderer *driverData,
    SDL_Window *window,
    SDL_GPUPresentMode presentMode)
{
    switch (presentMode) {
#ifdef SDL_PLATFORM_MACOS
    case SDL_GPU_PRESENTMODE_IMMEDIATE:
#endif
    case SDL_GPU_PRESENTMODE_VSYNC:
        return true;
    default:
        return false;
    }
}

static bool METAL_ClaimWindow(
    SDL_GPURenderer *driverData,
    SDL_Window *window)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);

        if (windowData == NULL) {
            windowData = (MetalWindowData *)SDL_calloc(1, sizeof(MetalWindowData));
            windowData->window = window;
            windowData->renderer = renderer;
            windowData->refcount = 1;

            if (METAL_INTERNAL_CreateSwapchain(renderer, windowData, SDL_GPU_SWAPCHAINCOMPOSITION_SDR, SDL_GPU_PRESENTMODE_VSYNC)) {
                SDL_SetPointerProperty(SDL_GetWindowProperties(window), WINDOW_PROPERTY_DATA, windowData);

                SDL_LockMutex(renderer->windowLock);

                if (renderer->claimedWindowCount >= renderer->claimedWindowCapacity) {
                    renderer->claimedWindowCapacity *= 2;
                    renderer->claimedWindows = SDL_realloc(
                        renderer->claimedWindows,
                        renderer->claimedWindowCapacity * sizeof(MetalWindowData *));
                }
                renderer->claimedWindows[renderer->claimedWindowCount] = windowData;
                renderer->claimedWindowCount += 1;

                SDL_UnlockMutex(renderer->windowLock);

                return true;
            } else {
                SDL_free(windowData);
                return false;
            }
        } else if (windowData->renderer == renderer) {
            ++windowData->refcount;
            return true;
        } else {
            SET_STRING_ERROR_AND_RETURN("Window already claimed", false);
        }
    }
}

static void METAL_ReleaseWindow(
    SDL_GPURenderer *driverData,
    SDL_Window *window)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);

        if (windowData == NULL) {
            return;
        }
        if (windowData->renderer != renderer) {
            SDL_SetError("Window not claimed by this device");
            return;
        }
        if (windowData->refcount > 1) {
            --windowData->refcount;
            return;
        }

        METAL_Wait(driverData);
        SDL_Metal_DestroyView(windowData->view);
        for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; i += 1) {
            if (windowData->inFlightFences[i] != NULL) {
                METAL_ReleaseFence(
                    (SDL_GPURenderer *)renderer,
                    windowData->inFlightFences[i]);
            }
        }

        SDL_LockMutex(renderer->windowLock);
        for (Uint32 i = 0; i < renderer->claimedWindowCount; i += 1) {
            if (renderer->claimedWindows[i]->window == window) {
                renderer->claimedWindows[i] = renderer->claimedWindows[renderer->claimedWindowCount - 1];
                renderer->claimedWindowCount -= 1;
                break;
            }
        }
        SDL_UnlockMutex(renderer->windowLock);

        SDL_free(windowData);

        SDL_ClearProperty(SDL_GetWindowProperties(window), WINDOW_PROPERTY_DATA);
    }
}

static bool METAL_WaitForSwapchain(
    SDL_GPURenderer *driverData,
    SDL_Window *window)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);

        if (windowData == NULL) {
            SET_STRING_ERROR_AND_RETURN("Cannot wait for a swapchain from an unclaimed window!", false);
        }

        if (windowData->inFlightFences[windowData->frameCounter] != NULL) {
            if (!METAL_WaitForFences(
                driverData,
                true,
                &windowData->inFlightFences[windowData->frameCounter],
                1)) {
                return false;
            }
        }

        return true;
    }
}

static bool METAL_INTERNAL_AcquireSwapchainTextureImpl(
    bool block,
    SDL_GPUCommandBuffer *commandBuffer,
    SDL_Window *window,
    SDL_GPUTexture **texture,
    Uint32 *swapchainTextureWidth,
    Uint32 *swapchainTextureHeight)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;
        MetalWindowData *windowData;
        CGSize drawableSize;
        const bool diagnose = renderer->afterglowDiagnosticsEnabled;
        Uint64 previousSubmission = 0;

        *texture = NULL;
        if (swapchainTextureWidth) {
            *swapchainTextureWidth = 0;
        }
        if (swapchainTextureHeight) {
            *swapchainTextureHeight = 0;
        }

        windowData = METAL_INTERNAL_FetchWindowData(window);
        if (windowData == NULL) {
            SET_STRING_ERROR_AND_RETURN("Window is not claimed by this SDL_GPUDevice", false);
        }

        // Update the window size
        drawableSize = windowData->layer.drawableSize;
        windowData->textureContainer.header.info.width = (Uint32)drawableSize.width;
        windowData->textureContainer.header.info.height = (Uint32)drawableSize.height;
        if (swapchainTextureWidth) {
            *swapchainTextureWidth = (Uint32)drawableSize.width;
        }
        if (swapchainTextureHeight) {
            *swapchainTextureHeight = (Uint32)drawableSize.height;
        }

        if (windowData->inFlightFences[windowData->frameCounter] != NULL) {
            if (diagnose) {
                previousSubmission = ((MetalFence *)windowData->inFlightFences[
                    windowData->frameCounter])->afterglowDiagnosticSubmission;
            }
            if (block) {
                // If we are blocking, just wait for the fence!
                if (!METAL_WaitForFences(
                    (SDL_GPURenderer *)renderer,
                    true,
                    &windowData->inFlightFences[windowData->frameCounter],
                    1)) {
                    return false;
                }
            } else {
                // If we are not blocking and the least recent fence is not signaled,
                // return true to indicate that there is no error but rendering should be skipped.
                if (!METAL_QueryFence(
                        (SDL_GPURenderer *)metalCommandBuffer->renderer,
                        windowData->inFlightFences[windowData->frameCounter])) {
                    return true;
                }
            }

            METAL_ReleaseFence(
                (SDL_GPURenderer *)metalCommandBuffer->renderer,
                windowData->inFlightFences[windowData->frameCounter]);

            windowData->inFlightFences[windowData->frameCounter] = NULL;
        }

        // Get the drawable and its underlying texture
        const bool trace = METAL_INTERNAL_TimingActive(renderer);
        if (trace) {
            METAL_INTERNAL_TimingSignpost(renderer, SDL_ACCELERANDO_GPU_NEXT_DRAWABLE, true);
        }
        const Uint64 drawableStart = (diagnose || trace) ? SDL_GetTicksNS() : 0;
        windowData->drawable = [windowData->layer nextDrawable];
        if (trace) {
            METAL_INTERNAL_TimingAdd(renderer, SDL_ACCELERANDO_GPU_NEXT_DRAWABLE, SDL_GetTicksNS() - drawableStart);
            METAL_INTERNAL_TimingSignpost(renderer, SDL_ACCELERANDO_GPU_NEXT_DRAWABLE, false);
        }
        if (diagnose) {
            const Uint64 drawableEnd = SDL_GetTicksNS();
            if (drawableEnd - drawableStart > 12000000ULL) {
                SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
                    "AfterglowMetal/next_drawable previous_submission=%" SDL_PRIu64
                    " start_ns=%" SDL_PRIu64 " end_ns=%" SDL_PRIu64
                    " wait_ms=%.3f block=%d drawable=%d",
                    previousSubmission, drawableStart, drawableEnd,
                    (double)(drawableEnd - drawableStart) / 1000000.0,
                    block, windowData->drawable != nil);
            }
        }
        windowData->texture.handle = [windowData->drawable texture];

        // Set up presentation
        if (metalCommandBuffer->windowDataCount == metalCommandBuffer->windowDataCapacity) {
            metalCommandBuffer->windowDataCapacity += 1;
            metalCommandBuffer->windowDatas = SDL_realloc(
                metalCommandBuffer->windowDatas,
                metalCommandBuffer->windowDataCapacity * sizeof(MetalWindowData *));
        }
        metalCommandBuffer->windowDatas[metalCommandBuffer->windowDataCount] = windowData;
        metalCommandBuffer->windowDataCount += 1;

        // Return the swapchain texture
        *texture = (SDL_GPUTexture *)&windowData->textureContainer;
        return true;
    }
}

static bool METAL_INTERNAL_AcquireSwapchainTexture(
    bool block, SDL_GPUCommandBuffer *commandBuffer, SDL_Window *window,
    SDL_GPUTexture **texture, Uint32 *width, Uint32 *height)
{
    MetalRenderer *renderer = ((MetalCommandBuffer *)commandBuffer)->renderer;
    const bool trace = METAL_INTERNAL_TimingActive(renderer);
    const Uint64 start = trace ? SDL_GetTicksNS() : 0;
    const bool result = METAL_INTERNAL_AcquireSwapchainTextureImpl(block, commandBuffer, window, texture, width, height);
    if (trace) METAL_INTERNAL_TimingAdd(renderer, SDL_ACCELERANDO_GPU_ACQUIRE_SWAPCHAIN, SDL_GetTicksNS() - start);
    return result;
}

static bool METAL_AcquireSwapchainTexture(
    SDL_GPUCommandBuffer *command_buffer,
    SDL_Window *window,
    SDL_GPUTexture **swapchain_texture,
    Uint32 *swapchain_texture_width,
    Uint32 *swapchain_texture_height
) {
    return METAL_INTERNAL_AcquireSwapchainTexture(
        false,
        command_buffer,
        window,
        swapchain_texture,
        swapchain_texture_width,
        swapchain_texture_height);
}

static bool METAL_WaitAndAcquireSwapchainTexture(
    SDL_GPUCommandBuffer *command_buffer,
    SDL_Window *window,
    SDL_GPUTexture **swapchain_texture,
    Uint32 *swapchain_texture_width,
    Uint32 *swapchain_texture_height
) {
    return METAL_INTERNAL_AcquireSwapchainTexture(
        true,
        command_buffer,
        window,
        swapchain_texture,
        swapchain_texture_width,
        swapchain_texture_height);
}

static SDL_GPUTextureFormat METAL_GetSwapchainTextureFormat(
    SDL_GPURenderer *driverData,
    SDL_Window *window)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);

    if (windowData == NULL) {
        SET_STRING_ERROR_AND_RETURN("Cannot get swapchain format, window has not been claimed", SDL_GPU_TEXTUREFORMAT_INVALID);
    }

    return windowData->textureContainer.header.info.format;
}

static bool METAL_SetSwapchainParameters(
    SDL_GPURenderer *driverData,
    SDL_Window *window,
    SDL_GPUSwapchainComposition swapchainComposition,
    SDL_GPUPresentMode presentMode)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);
        CGColorSpaceRef colorspace;

        if (windowData == NULL) {
            SET_STRING_ERROR_AND_RETURN("Cannot set swapchain parameters, window has not been claimed!", false);
        }

        if (!METAL_SupportsSwapchainComposition(driverData, window, swapchainComposition)) {
            SET_STRING_ERROR_AND_RETURN("Swapchain composition not supported", false);
        }

        if (!METAL_SupportsPresentMode(driverData, window, presentMode)) {
            SET_STRING_ERROR_AND_RETURN("Present mode not supported", false);
        }

        METAL_Wait(driverData);

        windowData->presentMode = SDL_GPU_PRESENTMODE_VSYNC;

#ifdef SDL_PLATFORM_MACOS
        if (@available(macOS 10.13, *)) {
            windowData->layer.displaySyncEnabled = (presentMode != SDL_GPU_PRESENTMODE_IMMEDIATE);
            windowData->presentMode = presentMode;
        }
#endif
        windowData->layer.pixelFormat = SDLToMetal_TextureFormat(SwapchainCompositionToFormat[swapchainComposition]);
#ifndef SDL_PLATFORM_TVOS
        if (@available(iOS 16.0, *)) {
            windowData->layer.wantsExtendedDynamicRangeContent = (swapchainComposition != SDL_GPU_SWAPCHAINCOMPOSITION_SDR);
        }
#endif

        colorspace = CGColorSpaceCreateWithName(SwapchainCompositionToColorSpace[swapchainComposition]);
        windowData->layer.colorspace = colorspace;
        CGColorSpaceRelease(colorspace);

        windowData->textureContainer.header.info.format = SwapchainCompositionToFormat[swapchainComposition];

        return true;
    }
}

static bool METAL_SetAllowedFramesInFlight(
    SDL_GPURenderer *driverData,
    Uint32 allowedFramesInFlight)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;

        if (!METAL_Wait(driverData)) {
            return false;
        }

        renderer->allowedFramesInFlight = allowedFramesInFlight;
        SDL_SetNumberProperty(renderer->props,
            "afterglow.metal.frames_in_flight", allowedFramesInFlight);
        return true;
    }
}

// Submission

static bool METAL_SubmitImpl(
    SDL_GPUCommandBuffer *commandBuffer,
    SDL_GPUFence **fence)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;
        const bool trace = METAL_INTERNAL_TimingActive(renderer);
        Uint64 start = 0;

        if (trace) {
            METAL_INTERNAL_TimingSignpost(renderer, SDL_ACCELERANDO_GPU_SUBMIT_LOCK, true);
            start = SDL_GetTicksNS();
        }
        SDL_LockMutex(renderer->submitLock);
        if (trace) {
            METAL_INTERNAL_TimingAdd(renderer, SDL_ACCELERANDO_GPU_SUBMIT_LOCK, SDL_GetTicksNS() - start);
            METAL_INTERNAL_TimingSignpost(renderer, SDL_ACCELERANDO_GPU_SUBMIT_LOCK, false);
        }

        if (!METAL_INTERNAL_AcquireFence(renderer, metalCommandBuffer)) {
            if (metalCommandBuffer->afterglowPassSampling) {
                SDL_SetAtomicInt(&metalCommandBuffer->afterglowPassSamples->busy, 0);
                metalCommandBuffer->afterglowPassSampling = false;
            }
            SDL_UnlockMutex(renderer->submitLock);
            return false;
        }

        const bool diagnose = renderer->afterglowDiagnosticsEnabled;
        const Uint64 diagnosticSubmission = (diagnose || renderer->afterglowPresentations)
            ? ++renderer->afterglowDiagnosticSubmission : 0;
        metalCommandBuffer->fence->afterglowDiagnosticSubmission =
            diagnosticSubmission;

        // AFTERGLOW TEMPORARY DIAGNOSTIC: sample on the main thread at most
        // once per second, logging only the first sample or a state change.
        // This runs under submitLock and never from a completion handler.
        if (diagnose && SDL_IsMainThread()) {
            const Uint64 now = SDL_GetTicksNS();
            if (now >= renderer->afterglowNextThermalSampleNS) {
                renderer->afterglowNextThermalSampleNS = now + 1000000000ULL;
                NSProcessInfo *processInfo = [NSProcessInfo processInfo];
                const Sint32 thermal = (Sint32)processInfo.thermalState;
                Sint32 lowPower = -1;
                if (@available(macOS 12.0, iOS 9.0, tvOS 9.0, *)) {
                    lowPower = processInfo.lowPowerModeEnabled ? 1 : 0;
                }
                if (thermal != renderer->afterglowThermalState ||
                    lowPower != renderer->afterglowLowPowerModeState) {
                    static const char *thermalNames[] = {
                        "nominal", "fair", "serious", "critical"
                    };
                    SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
                        "AfterglowMetal/thermal submission=%" SDL_PRIu64
                        " ticks_ns=%" SDL_PRIu64 " state=%d name=%s low_power=%d",
                        diagnosticSubmission, now, thermal,
                        thermal >= 0 && thermal < 4 ? thermalNames[thermal] : "unknown",
                        lowPower);
                    renderer->afterglowThermalState = thermal;
                    renderer->afterglowLowPowerModeState = lowPower;
                }
            }
        }

        // Give the caller its own reference while submitLock is held, another
        // thread could recycle this command buffer as soon as the lock is released.
        if (fence) {
            (void)SDL_AtomicIncRef(&metalCommandBuffer->fence->referenceCount);
            *fence = (SDL_GPUFence *)metalCommandBuffer->fence;
        }

        // Enqueue present requests, if applicable
        for (Uint32 i = 0; i < metalCommandBuffer->windowDataCount; i += 1) {
            MetalWindowData *windowData = metalCommandBuffer->windowDatas[i];
            if (renderer->afterglowPresentations) {
                if (windowData->afterglowPresentationLayer == 0) {
                    windowData->afterglowPresentationLayer = ++renderer->afterglowNextPresentationLayer;
                }
                METAL_INTERNAL_AfterglowRecordPresentation(renderer->afterglowPresentations,
                    windowData->drawable, diagnosticSubmission, windowData->afterglowPresentationLayer);
            }
            if (trace) {
                METAL_INTERNAL_TimingSignpost(renderer, SDL_ACCELERANDO_GPU_PRESENT_DRAWABLE, true);
                start = SDL_GetTicksNS();
            }
            [metalCommandBuffer->handle presentDrawable:windowData->drawable];
            if (trace) {
                METAL_INTERNAL_TimingAdd(renderer, SDL_ACCELERANDO_GPU_PRESENT_DRAWABLE, SDL_GetTicksNS() - start);
                METAL_INTERNAL_TimingSignpost(renderer, SDL_ACCELERANDO_GPU_PRESENT_DRAWABLE, false);
            }
            windowData->drawable = nil;

            windowData->inFlightFences[windowData->frameCounter] = (SDL_GPUFence *)metalCommandBuffer->fence;

            (void)SDL_AtomicIncRef(&metalCommandBuffer->fence->referenceCount);

            windowData->frameCounter = (windowData->frameCounter + 1) % renderer->allowedFramesInFlight;
        }

        // AFTERGLOW TEMPORARY DIAGNOSTICS: capture only immutable scalars.
        // Native command-buffer status now drives fence completion. SDL's
        // command buffer, renderer, window, and fence may already be recycled
        // or destroyed when this callback runs; never access them here.
        const Uint64 submitStart = diagnose ? SDL_GetTicksNS() : 0;
        const Uint32 presentCount = metalCommandBuffer->windowDataCount;
        const Uint64 diagnosticSampleInterval = renderer->afterglowDiagnosticSampleInterval;
        if (diagnose) {
            [metalCommandBuffer->handle addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
              const Uint64 completeTime = SDL_GetTicksNS();
              CFTimeInterval gpuStart = 0.0, gpuEnd = 0.0;
              CFTimeInterval kernelStart = 0.0, kernelEnd = 0.0;
              if (@available(macOS 10.15, iOS 10.3, tvOS 10.3, *)) {
                  gpuStart = buffer.GPUStartTime;
                  gpuEnd = buffer.GPUEndTime;
                  kernelStart = buffer.kernelStartTime;
                  kernelEnd = buffer.kernelEndTime;
              }
              const int status = (int)buffer.status;
              const double gpuMs = gpuStart > 0.0 && gpuEnd >= gpuStart
                  ? (gpuEnd - gpuStart) * 1000.0 : -1.0;
              const double kernelMs = kernelStart > 0.0 && kernelEnd >= kernelStart
                  ? (kernelEnd - kernelStart) * 1000.0 : -1.0;
              const double wallMs = (double)(completeTime - submitStart) / 1000000.0;
              if (gpuMs > 12.0 || kernelMs > 12.0 || wallMs > 12.0 ||
                  (diagnosticSampleInterval > 0 && diagnosticSubmission % diagnosticSampleInterval == 0)) {
                  SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
                      "AfterglowMetal/completed submission=%" SDL_PRIu64
                      " submit_ns=%" SDL_PRIu64 " complete_ns=%" SDL_PRIu64
                      " wall_ms=%.3f gpu_ms=%.3f kernel_ms=%.3f"
                      " gpu_start_s=%.6f gpu_end_s=%.6f"
                      " kernel_start_s=%.6f kernel_end_s=%.6f presents=%u status=%d",
                      diagnosticSubmission, submitStart, completeTime,
                      wallMs, gpuMs, kernelMs, gpuStart, gpuEnd,
                      kernelStart, kernelEnd, presentCount, status);
              }
            }];
        }

        if (metalCommandBuffer->afterglowPassSampling) {
            AfterglowMetalPassSamples *samples = metalCommandBuffer->afterglowPassSamples;
            const bool logPeriodic = renderer->afterglowPassTimestampMode == 1 ||
                diagnosticSubmission % 30 == 0;
            [metalCommandBuffer->handle addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
                METAL_INTERNAL_AfterglowCompletePassSamples(samples, buffer, diagnosticSubmission, logPeriodic);
            }];
            // The retained native owner, not this wrapper, now owns the lease.
            metalCommandBuffer->afterglowPassSampling = false;
        }

        // Submit the command buffer
        if (trace) {
            METAL_INTERNAL_TimingSignpost(renderer, SDL_ACCELERANDO_GPU_COMMIT, true);
            start = SDL_GetTicksNS();
        }
        [metalCommandBuffer->handle commit];
        if (trace) {
            METAL_INTERNAL_TimingAdd(renderer, SDL_ACCELERANDO_GPU_COMMIT, SDL_GetTicksNS() - start);
            METAL_INTERNAL_TimingSignpost(renderer, SDL_ACCELERANDO_GPU_COMMIT, false);
            METAL_INTERNAL_TimingSignpost(renderer, SDL_ACCELERANDO_GPU_SUBMIT_CLEANUP, true);
            start = SDL_GetTicksNS();
        }
        metalCommandBuffer->handle = nil;
        if (metalCommandBuffer->windowDataCount > 0 &&
            metalCommandBuffer->afterglowCaptureGeneration != 0) {
            METAL_INTERNAL_AfterglowStopCapture(
                renderer, metalCommandBuffer->afterglowCaptureGeneration);
        }

        // Mark the command buffer as submitted
        if (renderer->submittedCommandBufferCount >= renderer->submittedCommandBufferCapacity) {
            renderer->submittedCommandBufferCapacity = renderer->submittedCommandBufferCount + 1;

            renderer->submittedCommandBuffers = SDL_realloc(
                renderer->submittedCommandBuffers,
                sizeof(MetalCommandBuffer *) * renderer->submittedCommandBufferCapacity);
        }
        renderer->submittedCommandBuffers[renderer->submittedCommandBufferCount] = metalCommandBuffer;
        renderer->submittedCommandBufferCount += 1;

        // Check if we can perform any cleanups
        for (Sint32 i = renderer->submittedCommandBufferCount - 1; i >= 0; i -= 1) {
            if (!METAL_INTERNAL_IsFenceBusy(renderer->submittedCommandBuffers[i]->fence)) {
                METAL_INTERNAL_CleanCommandBuffer(
                    renderer,
                    renderer->submittedCommandBuffers[i],
                    false);
            }
        }

        METAL_INTERNAL_PerformPendingDestroys(renderer);

        SDL_UnlockMutex(renderer->submitLock);

        if (trace) {
            METAL_INTERNAL_TimingAdd(renderer, SDL_ACCELERANDO_GPU_SUBMIT_CLEANUP, SDL_GetTicksNS() - start);
            METAL_INTERNAL_TimingSignpost(renderer, SDL_ACCELERANDO_GPU_SUBMIT_CLEANUP, false);
        }

        return true;
    }
}

static bool METAL_INTERNAL_Submit(
    SDL_GPUCommandBuffer *commandBuffer,
    SDL_GPUFence **fence)
{
    MetalRenderer *renderer = ((MetalCommandBuffer *)commandBuffer)->renderer;
    const bool trace = METAL_INTERNAL_TimingActive(renderer);
    const Uint64 start = trace ? SDL_GetTicksNS() : 0;
    const bool result = METAL_SubmitImpl(commandBuffer, fence);
    if (trace) METAL_INTERNAL_TimingAdd(renderer, SDL_ACCELERANDO_GPU_SUBMIT, SDL_GetTicksNS() - start);
    return result;
}

static bool METAL_Submit(
    SDL_GPUCommandBuffer *commandBuffer)
{
    return METAL_INTERNAL_Submit(commandBuffer, NULL);
}

static SDL_GPUFence *METAL_SubmitAndAcquireFence(
    SDL_GPUCommandBuffer *commandBuffer)
{
    SDL_GPUFence *fence = NULL;
    if (!METAL_INTERNAL_Submit(commandBuffer, &fence)) {
        return NULL;
    }
    return fence;
}

static bool METAL_Cancel(
    SDL_GPUCommandBuffer *commandBuffer)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalRenderer *renderer = metalCommandBuffer->renderer;

    SDL_LockMutex(renderer->submitLock);
    METAL_INTERNAL_CleanCommandBuffer(renderer, metalCommandBuffer, true);
    SDL_UnlockMutex(renderer->submitLock);

    return true;
}

static bool METAL_Wait(
    SDL_GPURenderer *driverData)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalCommandBuffer *commandBuffer;

        /*
         * Wait for all submitted command buffers to complete.
         * Sort of equivalent to vkDeviceWaitIdle.
         */
        for (Uint32 i = 0; i < renderer->submittedCommandBufferCount; i += 1) {
            SDL_GPUFence *opaqueFence = (SDL_GPUFence *)renderer->submittedCommandBuffers[i]->fence;
            METAL_WaitForFences(driverData, true, &opaqueFence, 1);
        }

        SDL_LockMutex(renderer->submitLock);

        for (Sint32 i = renderer->submittedCommandBufferCount - 1; i >= 0; i -= 1) {
            commandBuffer = renderer->submittedCommandBuffers[i];
            METAL_INTERNAL_CleanCommandBuffer(renderer, commandBuffer, false);
        }

        METAL_INTERNAL_PerformPendingDestroys(renderer);

        SDL_UnlockMutex(renderer->submitLock);

        return true;
    }
}

// Format Info

// FIXME: Check simultaneous read-write support
static bool METAL_SupportsTextureFormat(
    SDL_GPURenderer *driverData,
    SDL_GPUTextureFormat format,
    SDL_GPUTextureType type,
    SDL_GPUTextureUsageFlags usage)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;

        // Only depth textures can be used as... depth textures
        if ((usage & SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET)) {
            if (!IsDepthFormat(format)) {
                return false;
            }
        }

        // Cube arrays are not supported on older iOS devices
        if (type == SDL_GPU_TEXTURETYPE_CUBE_ARRAY) {
#ifdef SDL_PLATFORM_MACOS
            return true;
#else
            if (@available(iOS 13.0, tvOS 13.0, *)) {
                if (!([renderer->device supportsFamily:MTLGPUFamilyCommon2] ||
                      [renderer->device supportsFamily:MTLGPUFamilyApple4])) {
                    return false;
                }
            } else {
                return false;
            }
#endif
        }

        switch (format) {
        // Apple GPU exclusive
        case SDL_GPU_TEXTUREFORMAT_B5G6R5_UNORM:
        case SDL_GPU_TEXTUREFORMAT_B5G5R5A1_UNORM:
        case SDL_GPU_TEXTUREFORMAT_B4G4R4A4_UNORM:
            if (@available(macOS 10.15, iOS 13.0, tvOS 13.0, *)) {
                return [renderer->device supportsFamily:MTLGPUFamilyApple1];
            } else {
                return false;
            }

        // Requires BC compression support
        case SDL_GPU_TEXTUREFORMAT_BC1_RGBA_UNORM:
        case SDL_GPU_TEXTUREFORMAT_BC2_RGBA_UNORM:
        case SDL_GPU_TEXTUREFORMAT_BC3_RGBA_UNORM:
        case SDL_GPU_TEXTUREFORMAT_BC4_R_UNORM:
        case SDL_GPU_TEXTUREFORMAT_BC5_RG_UNORM:
        case SDL_GPU_TEXTUREFORMAT_BC7_RGBA_UNORM:
        case SDL_GPU_TEXTUREFORMAT_BC6H_RGB_FLOAT:
        case SDL_GPU_TEXTUREFORMAT_BC6H_RGB_UFLOAT:
        case SDL_GPU_TEXTUREFORMAT_BC1_RGBA_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_BC2_RGBA_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_BC3_RGBA_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_BC7_RGBA_UNORM_SRGB:
            if (@available(iOS 16.4, tvOS 16.4, *)) {
                if (usage & SDL_GPU_TEXTUREUSAGE_COLOR_TARGET) {
                    return false;
                }
                if (@available(macOS 11.0, *)) {
                    return [renderer->device supportsBCTextureCompression];
                } else {
                    return true;
                }
            } else {
                return false;
            }

        // Requires D24S8 support
        case SDL_GPU_TEXTUREFORMAT_D24_UNORM:
        case SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT:
#ifdef SDL_PLATFORM_MACOS
            return [renderer->device isDepth24Stencil8PixelFormatSupported];
#else
            return false;
#endif

        case SDL_GPU_TEXTUREFORMAT_D16_UNORM:
            if (@available(macOS 10.12, iOS 13.0, tvOS 13.0, *)) {
                return true;
            } else {
                return false;
            }

        case SDL_GPU_TEXTUREFORMAT_ASTC_4x4_UNORM:
        case SDL_GPU_TEXTUREFORMAT_ASTC_5x4_UNORM:
        case SDL_GPU_TEXTUREFORMAT_ASTC_5x5_UNORM:
        case SDL_GPU_TEXTUREFORMAT_ASTC_6x5_UNORM:
        case SDL_GPU_TEXTUREFORMAT_ASTC_6x6_UNORM:
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x5_UNORM:
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x6_UNORM:
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x8_UNORM:
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x5_UNORM:
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x6_UNORM:
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x8_UNORM:
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x10_UNORM:
        case SDL_GPU_TEXTUREFORMAT_ASTC_12x10_UNORM:
        case SDL_GPU_TEXTUREFORMAT_ASTC_12x12_UNORM:
        case SDL_GPU_TEXTUREFORMAT_ASTC_4x4_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_ASTC_5x4_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_ASTC_5x5_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_ASTC_6x5_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_ASTC_6x6_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x5_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x6_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x8_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x5_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x6_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x8_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x10_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_ASTC_12x10_UNORM_SRGB:
        case SDL_GPU_TEXTUREFORMAT_ASTC_12x12_UNORM_SRGB:
#ifdef SDL_PLATFORM_MACOS
            if (@available(macOS 11.0, *)) {
                return [renderer->device supportsFamily:MTLGPUFamilyApple7];
            } else {
                return false;
            }
#else
            return true;
#endif
        case SDL_GPU_TEXTUREFORMAT_ASTC_4x4_FLOAT:
        case SDL_GPU_TEXTUREFORMAT_ASTC_5x4_FLOAT:
        case SDL_GPU_TEXTUREFORMAT_ASTC_5x5_FLOAT:
        case SDL_GPU_TEXTUREFORMAT_ASTC_6x5_FLOAT:
        case SDL_GPU_TEXTUREFORMAT_ASTC_6x6_FLOAT:
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x5_FLOAT:
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x6_FLOAT:
        case SDL_GPU_TEXTUREFORMAT_ASTC_8x8_FLOAT:
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x5_FLOAT:
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x6_FLOAT:
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x8_FLOAT:
        case SDL_GPU_TEXTUREFORMAT_ASTC_10x10_FLOAT:
        case SDL_GPU_TEXTUREFORMAT_ASTC_12x10_FLOAT:
        case SDL_GPU_TEXTUREFORMAT_ASTC_12x12_FLOAT:
#ifdef SDL_PLATFORM_MACOS
            if (@available(macOS 11.0, *)) {
                return [renderer->device supportsFamily:MTLGPUFamilyApple7];
            } else {
                return false;
            }
#else
            if (@available(iOS 13.0, tvOS 13.0, *)) {
                return [renderer->device supportsFamily:MTLGPUFamilyApple6];
            } else {
                return false;
            }
#endif
        default:
            return true;
        }
    }
}

// Device Creation

static bool METAL_PrepareDriver(SDL_VideoDevice *this, SDL_PropertiesID props)
{
    if (!SDL_GetBooleanProperty(props, SDL_PROP_GPU_DEVICE_CREATE_SHADERS_MSL_BOOLEAN, false) &&
        !SDL_GetBooleanProperty(props, SDL_PROP_GPU_DEVICE_CREATE_SHADERS_METALLIB_BOOLEAN, false)) {
        return false;
    }

    if (@available(macOS 10.14, iOS 13.0, tvOS 13.0, *)) {
        return (this->Metal_CreateView != NULL);
    }
    return false;
}

static void METAL_INTERNAL_InitBlitResources(
    MetalRenderer *renderer)
{
    SDL_GPUShaderCreateInfo shaderModuleCreateInfo;
    SDL_GPUSamplerCreateInfo createinfo;

    // Allocate the dynamic blit pipeline list
    renderer->blitPipelineCapacity = 2;
    renderer->blitPipelineCount = 0;
    renderer->blitPipelines = SDL_calloc(
        renderer->blitPipelineCapacity, sizeof(BlitPipelineCacheEntry));

    // Fullscreen vertex shader
    SDL_zero(shaderModuleCreateInfo);
    shaderModuleCreateInfo.code = FullscreenVert_metallib;
    shaderModuleCreateInfo.code_size = FullscreenVert_metallib_len;
    shaderModuleCreateInfo.stage = SDL_GPU_SHADERSTAGE_VERTEX;
    shaderModuleCreateInfo.format = SDL_GPU_SHADERFORMAT_METALLIB;
    shaderModuleCreateInfo.entrypoint = "FullscreenVert";

    renderer->blitVertexShader = METAL_CreateShader(
        (SDL_GPURenderer *)renderer,
        &shaderModuleCreateInfo);

    if (renderer->blitVertexShader == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to compile vertex shader for blit!");
    }

    // BlitFrom2D fragment shader
    shaderModuleCreateInfo.code = BlitFrom2D_metallib;
    shaderModuleCreateInfo.code_size = BlitFrom2D_metallib_len;
    shaderModuleCreateInfo.stage = SDL_GPU_SHADERSTAGE_FRAGMENT;
    shaderModuleCreateInfo.entrypoint = "BlitFrom2D";
    shaderModuleCreateInfo.num_samplers = 1;
    shaderModuleCreateInfo.num_uniform_buffers = 1;

    renderer->blitFrom2DShader = METAL_CreateShader(
        (SDL_GPURenderer *)renderer,
        &shaderModuleCreateInfo);

    if (renderer->blitFrom2DShader == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to compile BlitFrom2D fragment shader!");
    }

    // BlitFrom2DArray fragment shader
    shaderModuleCreateInfo.code = BlitFrom2DArray_metallib;
    shaderModuleCreateInfo.code_size = BlitFrom2DArray_metallib_len;
    shaderModuleCreateInfo.entrypoint = "BlitFrom2DArray";

    renderer->blitFrom2DArrayShader = METAL_CreateShader(
        (SDL_GPURenderer *)renderer,
        &shaderModuleCreateInfo);

    if (renderer->blitFrom2DArrayShader == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to compile BlitFrom2DArray fragment shader!");
    }

    // BlitFrom3D fragment shader
    shaderModuleCreateInfo.code = BlitFrom3D_metallib;
    shaderModuleCreateInfo.code_size = BlitFrom3D_metallib_len;
    shaderModuleCreateInfo.entrypoint = "BlitFrom3D";

    renderer->blitFrom3DShader = METAL_CreateShader(
        (SDL_GPURenderer *)renderer,
        &shaderModuleCreateInfo);

    if (renderer->blitFrom3DShader == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to compile BlitFrom3D fragment shader!");
    }

    // BlitFromCube fragment shader
    shaderModuleCreateInfo.code = BlitFromCube_metallib;
    shaderModuleCreateInfo.code_size = BlitFromCube_metallib_len;
    shaderModuleCreateInfo.entrypoint = "BlitFromCube";

    renderer->blitFromCubeShader = METAL_CreateShader(
        (SDL_GPURenderer *)renderer,
        &shaderModuleCreateInfo);

    if (renderer->blitFromCubeShader == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to compile BlitFromCube fragment shader!");
    }

    // BlitFromCubeArray fragment shader
    shaderModuleCreateInfo.code = BlitFromCubeArray_metallib;
    shaderModuleCreateInfo.code_size = BlitFromCubeArray_metallib_len;
    shaderModuleCreateInfo.entrypoint = "BlitFromCubeArray";

    renderer->blitFromCubeArrayShader = METAL_CreateShader(
        (SDL_GPURenderer *)renderer,
        &shaderModuleCreateInfo);

    if (renderer->blitFromCubeArrayShader == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to compile BlitFromCubeArray fragment shader!");
    }

    // Create samplers
    createinfo.address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    createinfo.address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    createinfo.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    createinfo.enable_anisotropy = 0;
    createinfo.enable_compare = 0;
    createinfo.mag_filter = SDL_GPU_FILTER_NEAREST;
    createinfo.min_filter = SDL_GPU_FILTER_NEAREST;
    createinfo.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
    createinfo.mip_lod_bias = 0.0f;
    createinfo.min_lod = 0;
    createinfo.max_lod = 1000;
    createinfo.max_anisotropy = 1.0f;
    createinfo.compare_op = SDL_GPU_COMPAREOP_ALWAYS;

    renderer->blitNearestSampler = METAL_CreateSampler(
        (SDL_GPURenderer *)renderer,
        &createinfo);

    if (renderer->blitNearestSampler == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to create blit nearest sampler!");
    }

    createinfo.mag_filter = SDL_GPU_FILTER_LINEAR;
    createinfo.min_filter = SDL_GPU_FILTER_LINEAR;
    createinfo.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_LINEAR;

    renderer->blitLinearSampler = METAL_CreateSampler(
        (SDL_GPURenderer *)renderer,
        &createinfo);

    if (renderer->blitLinearSampler == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to create blit linear sampler!");
    }
}

static void METAL_INTERNAL_DestroyBlitResources(
    SDL_GPURenderer *driverData)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    METAL_ReleaseSampler(driverData, renderer->blitLinearSampler);
    METAL_ReleaseSampler(driverData, renderer->blitNearestSampler);
    METAL_ReleaseShader(driverData, renderer->blitVertexShader);
    METAL_ReleaseShader(driverData, renderer->blitFrom2DShader);
    METAL_ReleaseShader(driverData, renderer->blitFrom2DArrayShader);
    METAL_ReleaseShader(driverData, renderer->blitFrom3DShader);
    METAL_ReleaseShader(driverData, renderer->blitFromCubeShader);
    METAL_ReleaseShader(driverData, renderer->blitFromCubeArrayShader);

    for (Uint32 i = 0; i < renderer->blitPipelineCount; i += 1) {
        METAL_ReleaseGraphicsPipeline(driverData, renderer->blitPipelines[i].pipeline);
    }
    SDL_free(renderer->blitPipelines);
}

static SDL_GPUDevice *METAL_CreateDevice(bool debugMode, bool preferLowPower, SDL_PropertiesID props)
{
    @autoreleasepool {
        MetalRenderer *renderer;
        id<MTLDevice> device = NULL;
        bool hasHardwareSupport = false;

        bool verboseLogs = SDL_GetBooleanProperty(
            props,
            SDL_PROP_GPU_DEVICE_CREATE_VERBOSE_BOOLEAN,
            true);

        if (debugMode) {
            /* Due to a Metal driver quirk, once a MTLDevice has been created
             * with this environment variable set, the Metal validation layers
             * will remain enabled for the rest of the application's lifespan,
             * even if the device is destroyed and recreated.
             */
            SDL_setenv_unsafe("MTL_DEBUG_LAYER", "1", 0);
        }

        // Create the Metal device and command queue
#ifdef SDL_PLATFORM_MACOS
        if (preferLowPower) {
            NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
            for (id<MTLDevice> candidate in devices) {
                if (candidate.isLowPower) {
                    device = candidate;
                    break;
                }
            }
        }
#endif
        if (device == NULL) {
            device = MTLCreateSystemDefaultDevice();
            if (device == NULL) {
                SDL_SetError("Failed to create Metal device");
                return NULL;
            }
        }

#ifdef SDL_PLATFORM_MACOS
        hasHardwareSupport = true;
        bool allowMacFamily1 = SDL_GetBooleanProperty(
            props,
            SDL_PROP_GPU_DEVICE_CREATE_METAL_ALLOW_MACFAMILY1_BOOLEAN,
            false);
        if (@available(macOS 10.15, *)) {
            hasHardwareSupport = allowMacFamily1 ?
                [device supportsFamily:MTLGPUFamilyMac1] :
                [device supportsFamily:MTLGPUFamilyMac2];
        } else if (@available(macOS 10.14, *)) {
            hasHardwareSupport = allowMacFamily1 ?
                [device supportsFeatureSet:MTLFeatureSet_macOS_GPUFamily1_v4] :
                [device supportsFeatureSet:MTLFeatureSet_macOS_GPUFamily2_v1];
        }
#elif defined(SDL_PLATFORM_VISIONOS)
        hasHardwareSupport = true;
#else
        if (@available(iOS 13.0, tvOS 13.0, *)) {
            hasHardwareSupport = [device supportsFamily:MTLGPUFamilyApple3];
        }
#endif

        if (!hasHardwareSupport) {
            SDL_SetError("Device does not meet the hardware requirements for SDL_GPU Metal");
            return NULL;
        }

        // Allocate and zero out the renderer
        renderer = (MetalRenderer *)SDL_calloc(1, sizeof(MetalRenderer));

        renderer->device = device;
        renderer->queue = [device newCommandQueue];

        renderer->props = SDL_CreateProperties();
        if (verboseLogs) {
            SDL_LogInfo(SDL_LOG_CATEGORY_GPU, "SDL_GPU Driver: Metal");
        }

        // Expose raw Metal handles for platform-specific features (MetalFX, etc.).
        // These are intentionally __bridge (non-retained) pointers; their lifetime
        // is owned by the MetalRenderer struct. Apps must not release them.
        SDL_SetPointerProperty(
            renderer->props,
            "SDL.gpu.device.metal.device",
            (__bridge void *)device);
        SDL_SetPointerProperty(
            renderer->props,
            "SDL.gpu.device.metal.command_queue",
            (__bridge void *)renderer->queue);

        // Record device name
        const char *deviceName = [device.name UTF8String];
        SDL_SetStringProperty(
            renderer->props,
            SDL_PROP_GPU_DEVICE_NAME_STRING,
            deviceName);
        if (verboseLogs) {
            SDL_LogInfo(SDL_LOG_CATEGORY_GPU, "Metal Device: %s", deviceName);
        }

        // Remember debug mode
        renderer->debugMode = debugMode;
        const char *afterglowDiagnostics = SDL_getenv("AFTERGLOW_METAL_DIAGNOSTICS");
        renderer->afterglowDiagnosticsEnabled = afterglowDiagnostics != NULL &&
            SDL_strcmp(afterglowDiagnostics, "1") == 0;
        renderer->afterglowDiagnosticSampleInterval = 0;
        renderer->afterglowThermalState = -1;
        renderer->afterglowLowPowerModeState = -1;
        if (renderer->afterglowDiagnosticsEnabled) {
            const char *sampleInterval = SDL_getenv("AFTERGLOW_METAL_SAMPLE_INTERVAL");
            if (sampleInterval != NULL && sampleInterval[0] >= '0' && sampleInterval[0] <= '9') {
                char *end = NULL;
                const Uint64 interval = SDL_strtoull(sampleInterval, &end, 10);
                if (interval > 0 && end != NULL && *end == '\0') {
                    renderer->afterglowDiagnosticSampleInterval = interval;
                }
            }
            const char *passMode = SDL_getenv("AFTERGLOW_METAL_PASS_TIMESTAMPS");
            if (passMode && (SDL_strcmp(passMode, "1") == 0 || SDL_strcmp(passMode, "2") == 0)) {
                if (@available(macOS 11.0, iOS 14.0, tvOS 14.0, *)) {
                    if ([device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) {
                        for (id<MTLCounterSet> set in device.counterSets) {
                            if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) {
                                for (id<MTLCounter> counter in set.counters) {
                                    if ([counter.name isEqualToString:MTLCommonCounterTimestamp]) {
                                        renderer->afterglowTimestampCounterSet = set;
                                        renderer->afterglowPassTimestampMode = (Uint32)(passMode[0] - '0');
                                        break;
                                    }
                                }
                                break;
                            }
                        }
                    }
                }
                SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
                    "AfterglowMetal/pass_timestamps enabled=%u requested=%s max_passes=%u samples=%u"
                    " cadence=%s timing_includes_counter_overhead=1",
                    renderer->afterglowPassTimestampMode, passMode, AFTERGLOW_MAX_TIMED_PASSES,
                    AFTERGLOW_MAX_TIMED_PASSES * 4,
                    renderer->afterglowPassTimestampMode == 2 ? "all_native_buffers" : "every_30th_native_buffer");
            }
        }
        renderer->allowedFramesInFlight = 2;
        SDL_SetNumberProperty(renderer->props,
            "afterglow.metal.frames_in_flight", renderer->allowedFramesInFlight);

        const char *timing = SDL_getenv("ACCEL_METAL_DIAGNOSTICS");
        renderer->timingEnabled = timing && SDL_strcmp(timing, "1") == 0;
        if (renderer->timingEnabled) {
            renderer->timingOwner = SDL_GetCurrentThreadID();
            const char *signposts = SDL_getenv("ACCEL_METAL_SIGNPOSTS");
            if (signposts && SDL_strcmp(signposts, "1") == 0) {
                if (@available(macOS 10.14, iOS 12.0, tvOS 12.0, *)) {
                    renderer->timingLog = os_log_create("com.vectorbreach.accelerando", "SDL Metal phases");
                    renderer->timingSignpostID = os_signpost_id_generate(renderer->timingLog);
                    renderer->timingSignposts = true;
                }
            }
            SDL_SetPointerProperty(renderer->props, SDL_PROP_GPU_ACCELERANDO_TIMING_POINTER, (void *)&metalTimingAPI);
        }

        // Set up colorspace array
        SwapchainCompositionToColorSpace[0] = kCGColorSpaceSRGB;
        SwapchainCompositionToColorSpace[1] = kCGColorSpaceSRGB;
        SwapchainCompositionToColorSpace[2] = kCGColorSpaceExtendedLinearSRGB;
        if (@available(macOS 11.0, iOS 14.0, tvOS 14.0, *)) {
            SwapchainCompositionToColorSpace[3] = kCGColorSpaceITUR_2100_PQ;
        } else {
            SwapchainCompositionToColorSpace[3] = NULL;
        }

        // Create mutexes
        renderer->submitLock = SDL_CreateMutex();
        renderer->acquireCommandBufferLock = SDL_CreateMutex();
        renderer->acquireUniformBufferLock = SDL_CreateMutex();
        renderer->disposeLock = SDL_CreateMutex();
        renderer->fenceLock = SDL_CreateMutex();
        renderer->windowLock = SDL_CreateMutex();
        if (renderer->afterglowDiagnosticsEnabled) {
            renderer->afterglowCaptureLock = SDL_CreateMutex();
            bool captureSupported = false;
            if (@available(macOS 10.15, iOS 13.0, tvOS 13.0, *)) {
                captureSupported = [[MTLCaptureManager sharedCaptureManager]
                    supportsDestination:MTLCaptureDestinationGPUTraceDocument];
            }
            SDL_SetBooleanProperty(renderer->props,
                "afterglow.metal.capture_enabled", renderer->afterglowCaptureLock != NULL);
            SDL_SetBooleanProperty(renderer->props,
                "afterglow.metal.capture_supported", captureSupported);
            SDL_SetStringProperty(renderer->props, "afterglow.metal.capture_status",
                renderer->afterglowCaptureLock ? "idle" : "error: capture mutex creation failed");
            SDL_LogInfo(SDL_LOG_CATEGORY_GPU,
                "AfterglowMetal/capture available=%d supported=%d",
                renderer->afterglowCaptureLock != NULL, captureSupported);
        }

        // Create command buffer pool
        METAL_INTERNAL_AllocateCommandBuffers(renderer, 2);

        // Create fence pool
        renderer->availableFenceCapacity = 2;
        renderer->availableFences = SDL_calloc(
            renderer->availableFenceCapacity, sizeof(MetalFence *));

        // Create uniform buffer pool
        renderer->uniformBufferPoolCapacity = 32;
        renderer->uniformBufferPoolCount = 32;
        renderer->uniformBufferPool = SDL_calloc(
            renderer->uniformBufferPoolCapacity, sizeof(MetalUniformBuffer *));

        for (Uint32 i = 0; i < renderer->uniformBufferPoolCount; i += 1) {
            renderer->uniformBufferPool[i] = METAL_INTERNAL_CreateUniformBuffer(
                renderer,
                UNIFORM_BUFFER_SIZE);
        }

        // Create deferred destroy arrays
        renderer->bufferContainersToDestroyCapacity = 2;
        renderer->bufferContainersToDestroyCount = 0;
        renderer->bufferContainersToDestroy = SDL_calloc(
            renderer->bufferContainersToDestroyCapacity, sizeof(MetalBufferContainer *));

        renderer->textureContainersToDestroyCapacity = 2;
        renderer->textureContainersToDestroyCount = 0;
        renderer->textureContainersToDestroy = SDL_calloc(
            renderer->textureContainersToDestroyCapacity, sizeof(MetalTextureContainer *));

        // Create claimed window list
        renderer->claimedWindowCapacity = 1;
        renderer->claimedWindows = SDL_calloc(
            renderer->claimedWindowCapacity, sizeof(MetalWindowData *));

        // Initialize blit resources
        METAL_INTERNAL_InitBlitResources(renderer);

        SDL_GPUDevice *result = SDL_calloc(1, sizeof(SDL_GPUDevice));
        ASSIGN_DRIVER(METAL)
        result->driverData = (SDL_GPURenderer *)renderer;
        result->shader_formats = SDL_GPU_SHADERFORMAT_MSL | SDL_GPU_SHADERFORMAT_METALLIB;
        renderer->sdlGPUDevice = result;
        renderer->afterglowPresentations = METAL_INTERNAL_AfterglowCreatePresentations();

        return result;
    }
}

// AFTERGLOW LOCAL PATCH: expose the active native Metal texture used by an
// SDL GPU texture for platform post-processing. Query after rendering so a
// cycled texture returns the slot containing the current content.
void *SDL_GetGPUTextureMetalHandle(SDL_GPUTexture *texture)
{
    if (texture == NULL) {
        return NULL;
    }
    @autoreleasepool {
        MetalTextureContainer *container = (MetalTextureContainer *)texture;
        if (container->activeTexture == NULL) {
            return NULL;
        }
        return (__bridge void *)container->activeTexture->handle;
    }
}

// COUNTERPOINT LOCAL PATCH: append a native texture effect between SDL GPU
// passes. Track active backings exactly like a normal SDL pass, including
// deferred destruction. No cycling: the shared queue orders writes after
// every earlier consumer, and Metal's tracked private textures order hazards.
// The callback may encode only, never submit, wait, or leave an encoder open.
bool SDL_EncodeGPUTextureMetalInterop(SDL_GPUCommandBuffer *commandBuffer,
                                     SDL_GPUTexture *input,
                                     SDL_GPUTexture *output,
                                     void (*encode)(void *, void *, void *, void *),
                                     void *userdata)
{
    if (commandBuffer == NULL || input == NULL || output == NULL || encode == NULL) {
        return SDL_InvalidParamError("Metal interop arguments");
    }
    CommandBufferCommonHeader *common = (CommandBufferCommonHeader *)commandBuffer;
    if (SDL_strcmp(SDL_GetGPUDeviceDriver(common->device), "metal") != 0) {
        return SDL_SetError("Metal interop requires a Metal command buffer");
    }
    @autoreleasepool {
        MetalCommandBuffer *commands = (MetalCommandBuffer *)commandBuffer;
        // CommonHeader validation fields are reset only for debug devices.
        // In release, submitted can remain true after a pooled buffer is
        // reacquired. Native status and encoder handles are always current.
        if (commands->handle == nil ||
            commands->handle.status >= MTLCommandBufferStatusCommitted ||
            commands->renderEncoder != nil || commands->blitEncoder != nil ||
            commands->computeEncoder != nil) {
            return SDL_SetError("Metal interop requires an idle, unsubmitted Metal command buffer");
        }
        MetalTexture *source = ((MetalTextureContainer *)input)->activeTexture;
        MetalTexture *destination = ((MetalTextureContainer *)output)->activeTexture;
        METAL_INTERNAL_TrackTexture(commands, source);
        METAL_INTERNAL_TrackTexture(commands, destination);
        encode(userdata, (__bridge void *)commands->handle,
               (__bridge void *)source->handle, (__bridge void *)destination->handle);
    }
    return true;
}

SDL_GPUBootstrap MetalDriver = {
    "metal",
    METAL_PrepareDriver,
    METAL_CreateDevice
};

#endif // SDL_GPU_METAL
