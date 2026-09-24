# Shared SDL for Vector Breach

This is the Vector Breach fork of [SDL](https://github.com/libsdl-org/SDL),
maintained at [alistanis/SDL](https://github.com/alistanis/SDL). It is an altered
source distribution under SDL's existing license. Upstream copyright notices
and commit authors are retained.

`ccooper/vector-breach` is the shared integration branch. Accelerando, Afterglow,
and Counterpoint consume the **same immutable commit** through `third_party/SDL`
submodules. Fixes belong here; do not grow game-specific SDL branches or patch
stacks. SDL_mixer and FreeType remain separate dependencies. The original Go
Vector Breach does not consume this fork.

## Initial common revision

The base is SDL 3.4.12 (`f87239e71e42da91ca317a12eefb82cfbf3393eb`). Consolidation
keeps the existing base so the dependency extraction can be validated separately
from a release upgrade.

Upstream changes were cherry-picked as individual commits with their authors:

| Upstream commit | Purpose |
| --- | --- |
| `5e53f67155ac5e000de81f6f109af2bc27121524` | Logical audio device backlink repair |
| `7e593a2b4f2d858f1315920e3655ac1903403e86` | Replace Metal fence busy waiting |
| `6c10cdb6ebcdbede48a0019c1b538be662c49ef3` | Native command buffer retention and wait-any repair |
| `b79a5e27ffa9ada1f1f8d1d0cef1587e44fdef42` | Correct completed fence queries |
| `39664f3b775f9c2b531cb2c554b313b4f505bb8e` | Acquire the caller fence under the submit lock |
| `51ef86a11fcce73eb588b1e098a17a9b43a97152` | Separate command buffer and caller fence references |

Existing game changes were reconciled from Afterglow `454a5691`, Counterpoint
`09a06102`, and Accelerando's September 23, 2026 reviewed working tree:

- CoreAudio shutdown guards and synchronous queue disposal.
- Queued GPU uniform snapshots and batching correctness, retained uniform
  capacity, and fixed uniform slots. The fixed slots remove the array growth
  failure repaired separately in Afterglow.
- Metal resource tracking storage and pools; native texture/device/command buffer
  access and ordered renderer submission for MetalFX and world shadows.
- Afterglow's optional Metal diagnostics, GPU timestamps, frame capture, and
  drawable presentation recording.
- Accelerando's optional CPU phase timing and Instruments signposts.
- The opt-in UIKit refresh hint. The application chooses its requested rate;
  other consumers retain SDL's default policy.
- The renderer interop export is owned by SDL, including its ELF export map.

Existing extension names are retained for compatibility. They are fork APIs,
not upstream SDL APIs. `ACCEL_METAL_DIAGNOSTICS`, `ACCEL_METAL_SIGNPOSTS`,
`AFTERGLOW_METAL_DIAGNOSTICS`, `AFTERGLOW_METAL_PASS_TIMESTAMPS`, and
`AFTERGLOW_METAL_PRESENTATIONS` remain opt-in. Keep them disabled for normal
performance acceptance. `AFTERGLOW_IOS_REFRESH_RATE` remains an application hint.
Presentation recording is unsupported on Apple simulators because their Metal
SDK omits drawable presentation callbacks and timestamps. Requesting
`AFTERGLOW_METAL_PRESENTATIONS` there logs that limitation without allocating a
recorder; device and macOS recording remain available.

UIKit windows attached to a scene use their actual window bounds during frame
calculation and initial setup. The legacy orientation workaround remains for
windows without a scene; it must not force the Duo inner display into landscape.
For simulator investigations, `AFTERGLOW_UIKIT_GEOMETRY=1` logs SDL, window, view,
scene, screen and Metal drawable dimensions at layout changes. Keep it disabled
for performance acceptance.

The fence fixes improve waiting and lifetime correctness. They do not establish
a fix for Accelerando's intermittent presentation stalls or pacing target.

## Development and coordinated updates

Use one sibling SDL checkout to develop fixes. Configure each game with its
existing source override pointing to that checkout:

| Game | CMake override |
| --- | --- |
| Accelerando | `-DVBA_SDL_DIR=/path/to/SDL` |
| Afterglow | `-DAFTERGLOW_SDL_DIR=/path/to/SDL` |
| Counterpoint | `-DCOUNTERPOINT_SDL_DIR=/path/to/SDL` |

Android builds accept the corresponding environment variable and use that
same source for native SDL and `org.libsdl.app` Java. Build output belongs in
each consumer's build directory, outside this checkout.

Before promoting an SDL change, build and run the native suites in all three
games. Run the fork's [GPU fence regression](test/README-vector-breach.md),
including both validation modes. Include Counterpoint's GPU uniform snapshot regression and Accelerando's
GPU render target checks. Run the consumer mobile/package CI for changes to
platform code or dependency wiring. Record skipped platforms and missing
fixtures; passing desktop tests does not establish mobile or pacing readiness.

Commit and push the validated SDL revision, fetch it in all three submodules,
and check out that exact commit. Refresh Counterpoint's SDL content fingerprint
with its `tools/native-deps.py` workflow, stage each gitlink, and update the
consumer branches together. `python3 build-scripts/check-vector-breach-pins.py`
checks the three staged pins, source checkouts, and fork URLs from sibling
working directories. CI and fresh clones must initialize submodules.

Keep upstream fixes in separate commits when possible. Reconcile an upstream
upgrade once here and validate all consumers before advancing their common
revision. Contributions to upstream SDL remain subject to its contribution
policy; this consolidation is maintained in the user's explicitly authorized
fork and is not an upstream submission.
