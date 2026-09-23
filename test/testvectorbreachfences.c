/*
 * Vector Breach fork GPU fence regression. Uses only public SDL APIs.
 * Distributed under the same zlib license as SDL.
 */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdio.h>
#include <stdlib.h>

#define BUFFER_BYTES (32U * 1024U)
#define WORD_COUNT (BUFFER_BYTES / sizeof(Uint32))
#define OUTSTANDING 8
#define REUSE_ROUNDS 16
#define THREAD_ROUNDS 256
#define SHADER_FORMATS (SDL_GPU_SHADERFORMAT_SPIRV | SDL_GPU_SHADERFORMAT_DXBC | SDL_GPU_SHADERFORMAT_DXIL | SDL_GPU_SHADERFORMAT_METALLIB)

typedef struct Work
{
    SDL_GPUDevice *device;
    SDL_GPUTransferBuffer *upload, *download;
    SDL_GPUBuffer *source, *destination;
    SDL_GPUFence *fence;
} Work;

typedef struct Watchdog
{
    SDL_AtomicInt done;
    Uint64 timeout_ms;
} Watchdog;

typedef struct Producer
{
    Work work;
    Uint32 seed;
    bool passed;
} Producer;

static bool fail(const char *operation)
{
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "FAIL: %s (%s)", operation, SDL_GetError());
    return false;
}

/* SDL's blocking GPU waits have no timeout. Bound even a driver deadlock,
 * including device teardown, without attempting unsafe concurrent teardown. */
static int SDLCALL watchdog_thread(void *userdata)
{
    Watchdog *watchdog = userdata;
    const Uint64 deadline = SDL_GetTicks() + watchdog->timeout_ms;
    while (!SDL_GetAtomicInt(&watchdog->done)) {
        if (SDL_GetTicks() >= deadline) {
            fputs("FAIL: GPU fence regression timed out; terminating without GPU teardown\n", stderr);
            fflush(stderr);
            _Exit(124);
        }
        SDL_Delay(10);
    }
    return 0;
}

static void release_inputs(Work *work)
{
    if (work->upload) SDL_ReleaseGPUTransferBuffer(work->device, work->upload);
    if (work->source) SDL_ReleaseGPUBuffer(work->device, work->source);
    if (work->destination) SDL_ReleaseGPUBuffer(work->device, work->destination);
    work->upload = NULL;
    work->source = work->destination = NULL;
}

static void destroy_work(Work *work)
{
    if (work->fence) SDL_ReleaseGPUFence(work->device, work->fence);
    work->fence = NULL;
    release_inputs(work);
    if (work->download) SDL_ReleaseGPUTransferBuffer(work->device, work->download);
    work->download = NULL;
}

static bool create_work(Work *work, SDL_GPUDevice *device)
{
    SDL_GPUBufferCreateInfo buffer = { 0 };
    SDL_GPUTransferBufferCreateInfo transfer = { 0 };
    work->device = device;
    buffer.usage = SDL_GPU_BUFFERUSAGE_VERTEX;
    buffer.size = BUFFER_BYTES;
    work->source = SDL_CreateGPUBuffer(device, &buffer);
    work->destination = SDL_CreateGPUBuffer(device, &buffer);
    transfer.size = BUFFER_BYTES;
    transfer.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    work->upload = SDL_CreateGPUTransferBuffer(device, &transfer);
    transfer.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
    work->download = SDL_CreateGPUTransferBuffer(device, &transfer);
    return (work->source && work->destination && work->upload && work->download) || fail("create transfer resources");
}

static Uint32 pattern(Uint32 seed, Uint32 index)
{
    return 0xa53c9e71U ^ (seed * 0x9e3779b9U) ^ (index * 0x85ebca6bU);
}

static bool submit_work(Work *work, Uint32 seed, bool readback)
{
    SDL_GPUCommandBuffer *commands;
    SDL_GPUCopyPass *copy;
    SDL_GPUTransferBufferLocation upload = { work->upload, 0 };
    SDL_GPUTransferBufferLocation download = { work->download, 0 };
    SDL_GPUBufferRegion source_region = { work->source, 0, BUFFER_BYTES };
    SDL_GPUBufferRegion destination_region = { work->destination, 0, BUFFER_BYTES };
    SDL_GPUBufferLocation source = { work->source, 0 };
    SDL_GPUBufferLocation destination = { work->destination, 0 };
    Uint32 *mapped = SDL_MapGPUTransferBuffer(work->device, work->upload, true);
    if (!mapped) return fail("map upload");
    for (Uint32 i = 0; i < WORD_COUNT; ++i) mapped[i] = pattern(seed, i);
    SDL_UnmapGPUTransferBuffer(work->device, work->upload);
    commands = SDL_AcquireGPUCommandBuffer(work->device);
    if (!commands) return fail("acquire command buffer");
    copy = SDL_BeginGPUCopyPass(commands);
    if (!copy) {
        SDL_CancelGPUCommandBuffer(commands);
        return fail("begin copy pass");
    }
    SDL_UploadToGPUBuffer(copy, &upload, &source_region, true);
    SDL_CopyGPUBufferToBuffer(copy, &source, &destination, BUFFER_BYTES, true);
    if (readback) SDL_DownloadFromGPUBuffer(copy, &destination_region, &download);
    SDL_EndGPUCopyPass(copy);
    work->fence = SDL_SubmitGPUCommandBufferAndAcquireFence(commands);
    return work->fence != NULL || fail("submit and acquire fence");
}

static bool check_data(Work *work, Uint32 seed)
{
    const Uint32 *mapped = SDL_MapGPUTransferBuffer(work->device, work->download, false);
    bool correct = true;
    if (!mapped) return fail("map completed download");
    for (Uint32 i = 0; i < WORD_COUNT; ++i) {
        if (mapped[i] != pattern(seed, i)) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "FAIL: signaled fence exposed incorrect data at word %u: got %08x expected %08x",
                         i, mapped[i], pattern(seed, i));
            correct = false;
            break;
        }
    }
    SDL_UnmapGPUTransferBuffer(work->device, work->download);
    return correct;
}

static bool wait_and_check(Work *work, Uint32 seed)
{
    if (!SDL_WaitForGPUFences(work->device, true, &work->fence, 1)) return fail("wait for submission");
    if (!SDL_QueryGPUFence(work->device, work->fence)) return fail("completed fence became unsignaled");
    return check_data(work, seed);
}

static bool exercise_batches(Work *works, SDL_GPUFence **retained)
{
    SDL_GPUDevice *device = works[0].device;
    for (Uint32 round = 0; round < REUSE_ROUNDS; ++round) {
        SDL_GPUFence *fences[OUTSTANDING];
        bool any_signaled = false;
        for (Uint32 i = 0; i < OUTSTANDING; ++i) {
            if (!submit_work(&works[i], round * OUTSTANDING + i + 1, true)) return false;
            fences[i] = works[i].fence;
        }
        if (!SDL_WaitForGPUFences(device, false, fences, OUTSTANDING)) return fail("wait any outstanding fence");
        for (Uint32 i = 0; i < OUTSTANDING; ++i) any_signaled |= SDL_QueryGPUFence(device, fences[i]);
        if (!any_signaled) return fail("wait any returned with no signaled fence");
        if (!SDL_WaitForGPUFences(device, true, fences, OUTSTANDING)) return fail("wait all outstanding fences");
        /* Both waits must remain valid and successful after completion. */
        if (!SDL_WaitForGPUFences(device, true, fences, OUTSTANDING) ||
            !SDL_WaitForGPUFences(device, false, fences, OUTSTANDING)) return fail("repeat wait on completed fences");
        for (Uint32 i = 0; i < OUTSTANDING; ++i) {
            if (!SDL_QueryGPUFence(device, fences[i])) return fail("query after wait all");
            if (!check_data(&works[i], round * OUTSTANDING + i + 1)) return false;
        }
        /* Hold one completed handle across later acquire/submit/cleanup cycles.
         * It must not be recycled just because its command buffer is reusable. */
        if (round == 0) {
            *retained = works[0].fence;
            works[0].fence = NULL;
        }
        if (!SDL_QueryGPUFence(device, *retained)) return fail("retained completed fence changed after pool reuse");
        for (Uint32 i = 0; i < OUTSTANDING; ++i) {
            if (works[i].fence) SDL_ReleaseGPUFence(device, works[i].fence);
            works[i].fence = NULL;
        }
    }
    return true;
}

static bool exercise_early_release(Work *work)
{
    Uint32 observed_pending = 0;
    /* Never read an early-released handle again. Only a later retained fence
     * authorizes readback. No assertion assumes the GPU is slower than the CPU. */
    for (Uint32 i = 0; i < 32; ++i) {
        if (!submit_work(work, 1000 + i, false)) return false;
        if (!SDL_QueryGPUFence(work->device, work->fence)) ++observed_pending;
        SDL_ReleaseGPUFence(work->device, work->fence);
        work->fence = NULL;
    }
    if (!submit_work(work, 2000, true)) return false;
    /* Also defer destruction of resources still referenced by this submission. */
    release_inputs(work);
    if (!wait_and_check(work, 2000)) return false;
    SDL_Log("early release: 32 handles released without waiting, %u observed unsignaled", observed_pending);
    return true;
}

static int SDLCALL producer_thread(void *userdata)
{
    Producer *producer = userdata;
    producer->passed = true;
    for (Uint32 i = 0; i < THREAD_ROUNDS; ++i) {
        if (!submit_work(&producer->work, producer->seed + i, true) ||
            !wait_and_check(&producer->work, producer->seed + i)) {
            producer->passed = false;
            break;
        }
        SDL_ReleaseGPUFence(producer->work.device, producer->work.fence);
        producer->work.fence = NULL;
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *driver = NULL;
    bool debug = true, passed = false;
    SDL_GPUDevice *device = NULL;
    SDL_GPUFence *retained = NULL;
    Work works[OUTSTANDING] = { 0 };
    Producer producers[2] = { 0 };
    SDL_Thread *threads[2] = { NULL, NULL }, *watchdog = NULL;
    Watchdog watch = { { 0 }, 120000 };
    int result = 1;

    for (int i = 1; i < argc; ++i) {
        if (SDL_strcmp(argv[i], "--driver") == 0 && i + 1 < argc) driver = argv[++i];
        else if (SDL_strcmp(argv[i], "--no-debug") == 0) debug = false;
        else if (SDL_strcmp(argv[i], "--timeout") == 0 && i + 1 < argc) {
            char *end = NULL;
            const unsigned long seconds = strtoul(argv[++i], &end, 10);
            if (!*argv[i] || *end || seconds < 1 || seconds > 3600) {
                fputs("--timeout must be between 1 and 3600 seconds\n", stderr);
                return 2;
            }
            watch.timeout_ms = (Uint64)seconds * 1000;
        } else {
            fprintf(stderr, "Usage: %s [--driver metal|vulkan|direct3d12] [--no-debug] [--timeout seconds]\n", argv[0]);
            return 2;
        }
    }
    /* Video initializes the backend loader; no window or swapchain is created. */
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        fail("SDL_Init");
        return 1;
    }
    watchdog = SDL_CreateThread(watchdog_thread, "GPU fence watchdog", &watch);
    if (!watchdog) {
        fail("create watchdog");
        goto done;
    }
    device = SDL_CreateGPUDevice(SHADER_FORMATS, debug, driver);
    if (!device) {
        SDL_Log("SKIP: requested GPU backend unavailable: %s", SDL_GetError());
        result = 77;
        goto done;
    }
    SDL_Log("GPU fence regression: driver=%s debug=%d", SDL_GetGPUDeviceDriver(device), debug);
    for (Uint32 i = 0; i < OUTSTANDING; ++i) if (!create_work(&works[i], device)) goto done;
    if (!exercise_batches(works, &retained) || !exercise_early_release(&works[0])) goto done;
    for (Uint32 i = 0; i < 2; ++i) {
        if (!create_work(&producers[i].work, device)) goto done;
        producers[i].seed = 10000 + i * THREAD_ROUNDS;
    }
    /* Competing submitters can clean/recycle wrappers while another caller is
     * returning from SubmitAndAcquireFence. Each owns distinct buffer resources. */
    for (Uint32 i = 0; i < 2; ++i) {
        threads[i] = SDL_CreateThread(producer_thread, "GPU fence producer", &producers[i]);
        if (!threads[i]) {
            fail("create producer");
            goto done;
        }
    }
    for (Uint32 i = 0; i < 2; ++i) {
        SDL_WaitThread(threads[i], NULL);
        threads[i] = NULL;
        if (!producers[i].passed) goto done;
    }
    if (!SDL_QueryGPUFence(device, retained) ||
        !SDL_WaitForGPUFences(device, true, &retained, 1)) {
        fail("retained fence after concurrent submissions");
        goto done;
    }
    passed = true;

done:
    for (Uint32 i = 0; i < 2; ++i) if (threads[i]) SDL_WaitThread(threads[i], NULL);
    if (device) {
        if (!SDL_WaitForGPUIdle(device)) passed = fail("wait for idle before cleanup");
        if (retained) SDL_ReleaseGPUFence(device, retained);
        for (Uint32 i = 0; i < OUTSTANDING; ++i) destroy_work(&works[i]);
        for (Uint32 i = 0; i < 2; ++i) destroy_work(&producers[i].work);
        SDL_DestroyGPUDevice(device);
    }
    SDL_SetAtomicInt(&watch.done, 1);
    if (watchdog) SDL_WaitThread(watchdog, NULL);
    SDL_Quit();
    if (passed) {
        SDL_Log("PASS: fence completion, data visibility, wait all/any, retained/early ownership, concurrent reuse and cleanup");
        result = 0;
    }
    return result;
}
