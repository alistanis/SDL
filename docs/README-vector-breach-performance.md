# Upstream performance review, September 24, 2026

This review compares the shared fork at `530cadbc5` with freshly fetched
`libsdl-org/SDL` main at `34d66a4d3965e756a2e83711f2986310e933cab4` and
release-3.4.x at `7917ae9fc`. The fork retains its SDL 3.4.12 base and public API.
This is a set of focused backports, not a general upgrade to development SDL.
Upstream authors and original commit IDs are retained in individual commits.

## Integrated changes

| Upstream commit | Behavior |
| --- | --- |
| [`4aa40070e`](https://github.com/libsdl-org/SDL/commit/4aa40070ef6c58c24ac5f3bf30750058bd3bda38) | Return before backend calls when vertex or fragment sampler bindings are empty. |
| [`cb99c462c`](https://github.com/libsdl-org/SDL/commit/cb99c462c18d9940080b906b774da803c303a68d) and [`ba16daed1`](https://github.com/libsdl-org/SDL/commit/ba16daed13c4c55b0e6c182bbc043b79e265e335) | Release ARC references to the Metal layer, drawable and swapchain texture before freeing GPU window data. The second commit fixes a typo in the first. |
| [`9e7e1271f`](https://github.com/libsdl-org/SDL/commit/9e7e1271fdbe4088283a43e97de73c4c9304cff6) | Clear the fallback Metal render attachment when no drawable is available, avoiding a stale attachment reference. This is a lifetime/correctness fix, not a measured speedup. |
| [`f2ca3689e`](https://github.com/libsdl-org/SDL/commit/f2ca3689e92f3d3c11ebcb30ef929058fad31194) | Free old Vulkan command buffers when rebuilding a renderer swapchain, instead of retaining their allocations across repeated resizes. |
| [`ac9ef17bc`](https://github.com/libsdl-org/SDL/commit/ac9ef17bcc1e6382bd972dc73ad470ee8a00ea66) | Avoid RLE overhead for static alpha texture subrectangle copies in the software renderer. |
| [`c9ebec468`](https://github.com/libsdl-org/SDL/commit/c9ebec46876c210d58d65118c7a46944139954eb) | Create IO stream properties only when requested, reducing allocations and locking for short lived streams. |

The IO backport requires a local correction. Upstream added a stored memory size
but omitted its initialization in `SDL_IOFromConstMem`. Consequently the first
`SDL_GetIOProperties` call reports a zero `SDL_PROP_IOSTREAM_MEMORY_SIZE_NUMBER`
for a nonempty constant-memory stream. This defect is still present at the
inspected upstream main revision. The fork initializes the field and adds
property/stream regression coverage. Lazy initialization also needs to propagate
property-insertion failures: publishing an incomplete group after successful
dynamic stream writes can otherwise lose the owned buffer on close. The fork
only publishes complete groups, frees incomplete groups and permits retry. An
allocation-failure regression exercises that path. No upstream issue or pull
request was submitted as part of this work.

## Already present or deferred

Actual code and patch equivalents were checked because upstream main and stable
often have different commit IDs for the same fix. The complete Metal fence
repair chain, Cocoa display-height IPC cache, semaphore-free thread creation,
zero-fence early return, hidden GPU window suppression, audio device backlink
repair and prior resource pools are already present.

The following were reviewed but excluded from this focused update:

- Vulkan YUV pipeline caching (`4b40cff5d`) depends on intervening YUV format and
  upload changes. It does not apply cleanly and does not help the games' RGBA
  rendering paths.
- Avoiding initialization of immediately overwritten surfaces (`fa2a726cc`)
  spans 27 files and newer platforms. This belongs in a coherent version upgrade.
- Android input-device listeners (`fc3a96e47`) need subsequent listener shutdown
  and initialization fixes plus activity and physical-controller testing.
- HIDAPI rumble/read contention (`71f4af732`) needs physical controller rumble,
  disconnect and shutdown validation. Accelerando disables HIDAPI by default
  on macOS, so this does not explain its desktop pacing issue.
- Audio device renegotiation (`36fed09ed`) can introduce a device-reopen hitch.
  iOS listener cleanup (`a74722ed7`, `62ea29689`, `fe6c1f113`) conflicts with the
  fork's deliberate synchronous shutdown and needs separate reconciliation.
- Metal allocation-failure checks (`a19040c84`), pipeline rebind correctness
  (`bcbdcaf6e`), and main-thread callback starvation (`f26af1338`) are separate
  correctness changes, without a demonstrated performance benefit here.

No newer Metal pacing implementation or Metal 4/shared-event rewrite was found
in the inspected upstream branches. These backports do not establish that the
game's presentation stalls or seamless Duo folding are fixed.

## Validation

### Measured behavior

- With allocator hooks, opening 64 constant-memory streams without requesting
  their properties used 640 live allocations and 645 allocation calls in the
  previous built SDL. The optimized library used 128 of each. Both returned to
  the allocation baseline after closing all streams, and the reported memory
  size remained correct. This is an 80% reduction in live allocations for this
  specific workload, not a measured game frame-rate improvement.
- The Metal window regression reproduced eight retained layers after their
  eight views/windows were destroyed with the previous library, even after GPU
  device destruction. With the backport, all eight layers were released while
  the device remained alive. The test deliberately does not acquire drawables,
  so this isolates layer ownership rather than every swapchain resource.
- The allocation-failure regression failed against the uncorrected IO backport:
  failures at property-insertion allocation points returned incomplete groups
  and leaked the previously written buffer. With the local correction, all 18
  cases passed across six allocation points, covering immediate close, retry,
  and retry with explicit ownership transfer.

### Checks

- Accelerando: full native build and all 47 CTest suites passed without skips,
  including the generated audio corpus. The real Metal GPU render-target test
  passed shader comparisons, 720 resize transitions and queued resource history.
- SDL IOStream: all 14 tests passed, including late memory properties and
  dynamic ownership transfer. Allocation tracking reported zero remaining
  allocations. Other SDL automation suites were not included in that filtered
  invocation.
- Shared GPU fence tests passed with debug validation enabled and disabled.
  The new Metal window lifetime and IO allocation-failure tests also passed.
  All four standalone CTest cases passed without a skip.
- Software and fallback Metal probes passed 32 frames of full, alpha subrect
  and rotated copies, checking 12,288 pixels per renderer. Metal also passed
  32 resize requests and two minimize/restore cycles.
- Vulkan through the Android emulator's arm64 MoltenVK library passed the same
  pixel checks using an RGBA render target, followed by window presentation,
  32 resizes and two minimize/restore cycles. Direct swapchain readback returned
  incorrect pixels in both prior and updated libraries. A diagnostic application
  of upstream `04289da57` did not resolve that behavior and was not retained.
  The Vulkan run is therefore limited to offscreen pixel validation and window
  lifecycle; it is not a passing direct-readback or validation-layer run.
- Full Xcode 27.1 beta simulator app build passed. SDL arm64 device SDK and
  Android arm64 shared-library/Java archive builds passed. These are compilation
  checks, not physical device or store/package acceptance.
- Afterglow: native build and a Metal/MSL shader smoke run passed. Full CTest
  finished with 141 of 142 passing and no skips. The sole failure was
  `afterglow_enemy_telegraph_smoke`, with the same missing hostile projectile
  defense colors recorded in the September 23 baseline log. This existing
  failure remains unresolved; the suite is not fully green.
- Counterpoint: the GPU render-state snapshot target rebuilt against this fork
  and its regression passed. The full native build was stopped after it began
  rebuilding the historical replay runtimes; the complete Counterpoint suite
  was not rerun. No Counterpoint release-readiness claim is made.

The final allocation-failure correction was followed by native, iOS and Android
SDL rebuilds, all 14 IO tests, and all four standalone regressions. The broader
game suites and renderer probes above ran before that final failure-path fix.
Consumer gitlinks remain unchanged. Validation used explicit SDL source
overrides; normal consumer configurations were restored afterward.
Coordinated consumer promotion remains separate from this fork update.

### Evidence and reproduction

Accelerando evidence is in `build-cpp/shared-sdl-upstream-*.log` and
`build-cpp/shared-sdl-fence-check/`, including `io-allocation-before.log`,
`io-allocation-after.log`, `metal-window-before.log`, `metal-window-after.log`
and `io-properties-failure-before.log`, plus the renderer probes. The final
fault-injection result is in `shared-sdl-upstream-final-regressions.log` and the
standalone project's `Testing/Temporary/LastTest.log`. Afterglow and Counterpoint evidence uses
`build/shared-sdl-upstream-*.log` in each checkout. These are reusable output
directories, not additional saved release artifacts.

Configure the native consumer with `-DVBA_SDL_DIR=/path/to/SDL` and
`-DSDL_TESTS=ON` to build `testautomation`. Run it from its generated `sdl/test`
directory with `--filter IOStream --trackmem` and dummy SDL video/audio drivers.
The standalone test project and GPU commands are documented in
[the regression guide](../test/README-vector-breach.md).
