/* Lazy IO property failure/ownership regression for the Vector Breach fork.
 * Distributed under the same zlib license as SDL.
 */
#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Prefixes keep returned storage aligned for every fundamental C type. */
typedef union AllocationHeader
{
    max_align_t alignment;
    size_t size;
} AllocationHeader;

static size_t live_allocations;
static size_t allocation_attempts;
static size_t failure_point;
static int count_attempts;
static int injected;
static int failures;
static const unsigned char payload[] = "Late IO properties must retain this allocation.";

static int ShouldFail(void)
{
    if (count_attempts && ++allocation_attempts == failure_point) {
        injected = 1;
        return 1;
    }
    return 0;
}

static void *SDLCALL CountMalloc(size_t size)
{
    AllocationHeader *header;
    if (ShouldFail() || size > SIZE_MAX - sizeof(*header)) {
        return NULL;
    }
    header = (AllocationHeader *)malloc(sizeof(*header) + size);
    if (!header) {
        return NULL;
    }
    header->size = size;
    ++live_allocations;
    return header + 1;
}

static void *SDLCALL CountCalloc(size_t count, size_t size)
{
    void *ptr;
    if (size && count > SIZE_MAX / size) {
        return NULL;
    }
    ptr = CountMalloc(count * size);
    if (ptr) {
        memset(ptr, 0, count * size);
    }
    return ptr;
}

static void SDLCALL CountFree(void *ptr)
{
    if (ptr) {
        --live_allocations;
        free((AllocationHeader *)ptr - 1);
    }
}

static void *SDLCALL CountRealloc(void *ptr, size_t size)
{
    AllocationHeader *header;
    if (!ptr) {
        return CountMalloc(size);
    }
    if (!size) {
        CountFree(ptr);
        return NULL;
    }
    if (ShouldFail() || size > SIZE_MAX - sizeof(*header)) {
        return NULL;
    }
    header = (AllocationHeader *)realloc((AllocationHeader *)ptr - 1, sizeof(*header) + size);
    if (!header) {
        return NULL;
    }
    header->size = size;
    return header + 1;
}

static void Check(int condition, const char *message, size_t point, int mode)
{
    if (!condition) {
        fprintf(stderr, "FAIL point=%zu mode=%d: %s (%s)\n", point, mode, message, SDL_GetError());
        ++failures;
    }
}

static SDL_IOStream *OpenPopulated(void)
{
    SDL_IOStream *stream = SDL_IOFromDynamicMem();
    if (stream && SDL_WriteIO(stream, payload, sizeof(payload)) != sizeof(payload)) {
        SDL_CloseIO(stream);
        return NULL;
    }
    return stream;
}

static SDL_PropertiesID GetWithFailure(SDL_IOStream *stream, size_t point)
{
    SDL_PropertiesID props;
    allocation_attempts = 0;
    failure_point = point;
    injected = 0;
    count_attempts = 1;
    props = SDL_GetIOProperties(stream);
    count_attempts = 0;
    return props;
}

static void RunFailureCase(size_t point, int mode)
{
    const size_t baseline = live_allocations;
    SDL_IOStream *stream = OpenPopulated();
    SDL_PropertiesID props;
    void *memory = NULL;
    int transferred = 0;
    Check(stream != NULL, "create populated stream", point, mode);
    if (!stream) {
        return;
    }
    props = GetWithFailure(stream, point);
    Check(injected, "requested allocation failure was reached", point, mode);
    Check(props == 0, "failed property initialization must return zero", point, mode);

    /* Mode 0 closes immediately. Mode 1 retries; mode 2 also transfers ownership. */
    if (mode != 0) {
        props = SDL_GetIOProperties(stream);
        Check(props != 0, "property initialization can be retried", point, mode);
        if (props) {
            memory = SDL_GetPointerProperty(props, SDL_PROP_IOSTREAM_DYNAMIC_MEMORY_POINTER, NULL);
            Check(memory != NULL, "retry publishes the existing backing allocation", point, mode);
            if (memory) {
                Check(memcmp(memory, payload, sizeof(payload)) == 0, "retry preserves backing data", point, mode);
            }
            Check(SDL_GetIOSize(stream) == (Sint64)sizeof(payload), "retry preserves stream size", point, mode);
            Check(SDL_TellIO(stream) == (Sint64)sizeof(payload), "retry preserves stream position", point, mode);
            Check(SDL_GetIOProperties(stream) == props, "retry creates a stable property group", point, mode);
            if (mode == 2 && memory) {
                transferred = SDL_SetPointerProperty(props, SDL_PROP_IOSTREAM_DYNAMIC_MEMORY_POINTER, NULL);
                Check(transferred, "explicit NULL transfers ownership", point, mode);
            }
        }
    }
    Check(SDL_CloseIO(stream), "close stream", point, mode);
    if (transferred) {
        /* The tracked block must survive close before it is inspected or freed. */
        Check(live_allocations == baseline + 1, "transferred allocation survives close", point, mode);
        if (live_allocations == baseline + 1) {
            Check(memcmp(memory, payload, sizeof(payload)) == 0, "transferred data survives close", point, mode);
            SDL_free(memory);
        }
    }
    Check(live_allocations == baseline, "close releases all stream/property allocations", point, mode);
}

int main(void)
{
    SDL_IOStream *stream;
    SDL_PropertiesID props;
    size_t attempts, baseline;
    /* This is deliberately the first SDL call in this standalone process. */
    if (!SDL_SetMemoryFunctions(CountMalloc, CountCalloc, CountRealloc, CountFree)) {
        fputs("FAIL: cannot install allocation wrappers\n", stderr);
        return 1;
    }
    SDL_SetMainReady();
    if (!SDL_Init(0)) {
        fprintf(stderr, "FAIL: SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    /* Warm error TLS and global property bookkeeping outside fault injection. */
    SDL_SetError("%01024d", 0);
    for (int warm = 0; warm < 4; ++warm) {
        stream = OpenPopulated();
        if (!stream || !SDL_GetIOProperties(stream)) {
            fputs("FAIL: cannot warm IO properties\n", stderr);
            SDL_CloseIO(stream);
            SDL_Quit();
            return 1;
        }
        SDL_CloseIO(stream);
    }
    SDL_ClearError();
    baseline = live_allocations;
    stream = OpenPopulated();
    if (!stream) {
        fputs("FAIL: cannot create measurement stream\n", stderr);
        SDL_Quit();
        return 1;
    }
    props = GetWithFailure(stream, 0); /* Count every allocation without failing. */
    attempts = allocation_attempts;
    Check(props != 0 && attempts != 0, "measure lazy property allocation path", 0, -1);
    Check(SDL_CloseIO(stream), "close measurement stream", 0, -1);
    Check(live_allocations == baseline, "measurement returns to warmed baseline", 0, -1);

    for (size_t point = 1; point <= attempts; ++point) {
        for (int mode = 0; mode < 3; ++mode) {
            RunFailureCase(point, mode);
        }
    }
    Check(live_allocations == baseline, "all fault cases return to warmed baseline", 0, -1);
    printf("%s lazy_properties_allocation_points=%zu failure_cases=%zu failures=%d\n",
           failures ? "FAIL" : "PASS", attempts, attempts * 3, failures);
    SDL_Quit();
    return failures ? 1 : 0;
}
