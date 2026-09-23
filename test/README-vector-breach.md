# Vector Breach GPU fence regression

`testvectorbreachfences.c` uses public SDL GPU APIs and creates no window or
swapchain. It initializes the video backend loader and submits real uploads,
buffer copies, and downloads on a GPU device. It requires an available GPU;
software/dummy video tests do not substitute for this check.

The regression covers:

- Eight outstanding fences, wait any/all, repeated waits, and completed queries.
- Readback of every word after completion, using a distinct pattern per submission.
- A completed caller-owned fence retained across later command buffer reuse.
- Fence release immediately after submission, without waiting, followed by new
  submissions. It reports how many released fences were observed unsignaled;
  it does not assume a particular CPU/GPU speed relationship.
- Deferred destruction of uploaded/copied resources before their fence is waited.
- Two concurrent submitters, each acquiring, submitting, checking readback, and
  releasing 256 fences, to exercise command buffer reuse during fence acquisition.
- Device idle, fence/resource release, and device destruction.

A watchdog terminates the process with status 124 if the GPU portion, including
blocking waits and device teardown, exceeds 120 seconds. This is a deadlock limit, not a
performance requirement. Override it with `--timeout SECONDS` (1 to 3600).
Status 0 means passed, 1 means failed, 2 means invalid arguments, and 77 means no
requested GPU backend was available. Treat 77 as a skipped GPU check, not a pass.

## Build with an installed SDL package

Run from this SDL checkout. `pkg-config` must refer to this fork's built/installed
SDL, not an unrelated system SDL:

```sh
cc -std=c11 $(pkg-config --cflags sdl3) test/testvectorbreachfences.c \
  -o /tmp/testvectorbreachfences $(pkg-config --libs sdl3)
/tmp/testvectorbreachfences --driver metal
/tmp/testvectorbreachfences --driver metal --no-debug
```

For a static SDL package, use `pkg-config --static --libs sdl3` for the link flags.
Use `--driver vulkan` or `--driver direct3d12` on other supported platforms, or omit
`--driver` to use SDL's default. Debug validation is enabled unless `--no-debug`
is supplied. The test does not require shaders, SDL_test, or fork-private APIs.

## Build against an existing SDL CMake build

A standalone project avoids platform-specific library/framework lists.
Configure `test/vector-breach` with the directory containing the built
`SDL3Config.cmake` (for Accelerando's build, that is `build-cpp/sdl`):

```sh
cmake -S /path/to/SDL/test/vector-breach -B /path/to/fence-check-build \
  -DSDL3_DIR=/path/to/consumer/build-cpp/sdl
cmake --build /path/to/fence-check-build --config Release
ctest --test-dir /path/to/fence-check-build -C Release --output-on-failure
```

CTest runs both validation modes using SDL's default GPU backend and reports
unavailable GPUs as skipped. Use the executable's `--driver` option to require
a particular backend. Multi-configuration generators may place the executable under `Release/`.
Run both validation modes when changing Metal fence ownership. Keep optional
Afterglow/Accelerando Metal diagnostics disabled for the ordinary regression;
run additional diagnostic-enabled checks separately when changing callback
lifetimes. This test does not cover presentation/drawable fences or GPU capture.
