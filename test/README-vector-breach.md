# Vector Breach regressions

## GPU fences

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

## Metal window lifetime on macOS

The same CMake project builds `testmetalwindowlifetime` on native macOS and
registers `gpu_metal_window_lifetime` with CTest. It is excluded from iOS, tvOS,
and visionOS builds. The target enables Objective-C ARC and links Cocoa and
QuartzCore directly as well as the selected SDL library.

The test creates, claims for a Metal GPU device, releases, and destroys eight
small hidden windows. It captures weak references to each window's Metal view
and `CAMetalLayer`, then drains autorelease pools, the Cocoa run loop, and Core
Animation transactions. It checks that all layers are released while the GPU
device remains alive and after the device is destroyed. This detects the
window data ARC leak without comparing process memory measurements.

It does not acquire a drawable or render a frame. Consequently it does not
independently validate drawable or swapchain texture ownership, presentation
pacing, or performance. The cleanup allowance and CTest's 30 second timeout are
cleanup/deadlock bounds, not timing requirements.

Status 0 means all layers were released; 1 means failure; 2 means invalid
arguments. Status 77 means Cocoa/Metal was unavailable or Cocoa still retained
a Metal view, making the layer ownership observation inconclusive. CTest reports
77 as skipped, not passed. Keep skipped checks explicit in validation reports.

If hidden-window behavior is inconclusive, run the executable with `--show` to
repeat the same checks with small visible windows:

```sh
/path/to/fence-check-build/testmetalwindowlifetime --show
```

Multi-configuration generators may place the executable under `Release/`.

## Lazy IO properties under allocation failure

The standalone project also builds `testioproperties` and registers
`io_properties_allocation_failure` with CTest. This portable test needs no
video, audio, GPU, or SDL_test support and has no skip path.

It installs counting memory functions before SDL initialization, writes a
dynamic memory stream before requesting its properties, then injects failure
at each allocation during the first property request. It verifies that failure
returns zero, immediate close releases the backing buffer, and retry preserves
the data, size, and position. A third path transfers ownership by setting the
buffer property to NULL and verifies that the caller retains the buffer after
close. Each case checks allocation balance against warmed global bookkeeping.

This specifically covers dynamic stream property creation. The ordinary
IOStream automation suite covers mutable and constant memory properties;
this test does not inject faults into their initializers or file properties.
