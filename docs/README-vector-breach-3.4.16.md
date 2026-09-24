# SDL 3.4.16 integration, September 24, 2026

This record preserves the initial candidate validation below. The subsequent
[promotion update and fix audit](#promotion-update-and-fix-audit) records the
current maintenance decision; historical failures and limits are retained.

The candidate branch is `ccooper/sdl-3.4.16`. Source integration commit
`a6a746d94edbf596531019017bfb38858b0439fd` merges released upstream tag
`release-3.4.16` (`fa2c02bb6e21974a89ea9824bc53c9932abe5f9c`) into the shared
fork at `da9acc85c05c52a693ae48d59a8b1ecb32c00c9d`. Both histories and their
authors are retained. The moving `release-3.4.x` development tip was not used.

The fork's `main` was fast-forwarded to upstream development main
`70e125ba8ef21813c34bb258366a4420e7f52327`. Development main is a reference
branch, not the games' dependency. The original shared integration branch and
the independently submitted IO fix branches were not rewritten.

## Source reconciliation

All explicit conflicts were in the optional Metal diagnostics. Their existing
behavior was retained. The merge also silently inserted an unconditional
`metalFence->commandBuffer = nil` before the reference count decrement. That
would undo the newer upstream `51ef86a11` lifetime repair already in this fork.
The reconciliation retains clearing the command buffer only when the final
fence reference is released.

An independent source review confirmed that the resulting Metal GPU diff from
the previous fork is exactly upstream's pipeline rebinding repair
`bcbdcaf6e` by stable patch ID. Other overlapping changes preserve empty sampler
binding early returns, Metal ARC window cleanup, stale attachment cleanup, and
Vulkan command buffer cleanup. IO fixes and tests, UIKit scene geometry and
refresh behavior, renderer uniform snapshots and interop, CoreAudio guards,
software RLE handling, and fork regressions remain unchanged.

Released SDL 3.4.16 does not include the two local IO corrections, so they are
retained. The independently submitted [constant memory size fix](https://github.com/libsdl-org/SDL/pull/16381)
merged upstream as `70e125ba8`; the [allocation failure fix](https://github.com/libsdl-org/SDL/pull/16382)
remains open at validation time. This branch does not modify those submission
branches or submit additional changes upstream.

## Validation

Validation uses explicit source overrides pointing to the candidate checkout.
Existing build directories are reused with one or two low priority build jobs.

| Check | Result |
| --- | --- |
| Accelerando native build and CTest | 47/47 passed, no skips, including the generated audio corpus. |
| SDL IOStream automation | 14/14 passed; zero remaining tracked allocations. Other automation suites were excluded by the filter. |
| Fork fence, Metal window, and IO failure regressions | 4/4 passed; GPU cases used Metal with validation enabled and disabled; no skips. |
| Accelerando real Metal render targets | Shader comparisons, 720 size transitions, and resource history with 1/2/3 frames in flight passed. |
| Accelerando native window resizing | 120 measured frames; nine retained targets before and after, no failures, unchanged retained memory. This is capacity validation, not gameplay pacing acceptance. |
| Xcode 27.1 beta simulator app | Full build passed. |
| iOS device archive | Unsigned archive built with iPhoneOS 27.0; package validation passed, including assets, privacy manifest, matching debug symbols, and testing access disabled. |
| Android unsigned release | Native and Java compilation passed; 10/10 Java unit tests passed. Release lint and package verification remain blocked as described below. |
| Afterglow | Native build and explicit GPU/Metal MSL shader smoke passed. CTest: 141/142 passed, no skips; the sole failure exactly matches baseline. |
| Counterpoint | Native build passed with optional serializer benchmarks disabled. CTest: 233 passed, 8 failed, 1 skipped out of 242 cases. Native CoreAudio allocation checks failed on both candidate and pinned baseline. |

Accelerando's native app build reports two unused private fields for optional
Metal display link support. These are app fields, not newly introduced SDL
warnings. Dummy audio is used by its CTest audio runtime suite; this alone does
not establish physical output or route switching acceptance.

Afterglow's `afterglow_enemy_telegraph_smoke` failure was reproduced before the
candidate build. Both runs report missing hostile projectile defense colors:
blue=0, yellow=0, red=0, center=6,10,19,255. The candidate run completed all
142 cases, including native allocation, performance, audio path safety, boss
encounter, difficulty, retry, and end to end checks. It is not a fully green
suite, and the unrelated visual failure was not changed here.

### Counterpoint build scope

The candidate source override temporarily disables
`COUNTERPOINT_VERIFY_NATIVE_DEPENDENCY_LOCK`; the existing lock continues to
describe the unchanged consumer pin. Any later promotion must refresh that
content fingerprint and pass verification with the final pin.

The existing cache enabled optional serializer benchmarks. Its
`counterpoint_serializer_corpus_export` target fails an application assertion
in `tools/benchmarks/serializer/CorpusExport.cpp:37`:
`kMaximumColumnScalarBytes == kClientWorldMaximumEncodedBytes`, with values
262144 and 294912. This is independent of SDL. Validation temporarily sets
`COUNTERPOINT_BUILD_SERIALIZER_BENCHMARKS=OFF`; all 242 registered CTest cases
remain available. The original `ON` cache setting was restored afterward.
The unrestricted build with that optional target is not a passing check.

Nine of the ten GPU labeled cases passed, including shader workbench, menu
starfield, gate/offscreen rendering, frame clock, fog uploads, hero meshes,
articulation, and world shadows. `hero_texture_gpu_smoke` skipped because the embedded solo
authority could not start. The same failure and skip appear in the previous
`build/shared-sdl-texture-retry.log`. The test labels any application
initialization failure as missing window/GPU support, although its log confirms
the GPU pipeline was live. This remains a coverage gap, not a passing texture
smoke test.

The eight CTest failures are `bot_navigation`, `bot_navigation_imported`,
`static_kit_handlers`, `hero_visuals`, `authority_command_lifecycle`,
`projected_client_architecture`, `unit_mesh_assets`, and `fog_of_war`.
Seven execute simulation, content, or authority binaries whose link commands
contain no SDL. The architecture check is a Python source-contract test.
Their reported navigation/golden, point/triangle count, admission, source
structure, and visibility budget failures were not changed as part of this
dependency update.

All 11 audio labeled CTest cases passed, primarily using dummy audio. Additional
native CoreAudio music, SFX stress, and GPU/client audio checks delivered
callbacks but failed their C++ allocation contracts. The same three failures
reproduce against the exact pinned SDL baseline `5637da187`, with both
`SDL_AUDIODRIVER` and `SDL_AUDIO_DRIVER` removed from the environment. The native
client comparison relinks the same application objects against each SDL build.

| Native CoreAudio check | Candidate | Pinned baseline |
| --- | --- | --- |
| Music | 129 callbacks; 129 C++ allocations, zero frees | 130 callbacks; 130 C++ allocations, zero frees |
| SFX stress | 250 callbacks; 250 C++ allocations/frees | 249 callbacks; 249 C++ allocations/frees |
| GPU/client audio | C++ allocation assertion failed; 142767 allocations, 142772 frees | Same assertion failed; 43449 allocations, 43456 frees |

Music and SFX report zero SDL and raw allocations; all 60 requested SFX shots
started in both runs. Client runs also report zero SDL allocations, with all
43 shots started and 315 confirmed ticks. The differing client allocation
totals establish a preexisting contract failure, not equivalent performance.
The first candidate client attempt was blocked by an audio driver environment
override; the comparison above uses the corrected invocation. Native audio
allocation and pacing acceptance remain unresolved.

### Android acceptance limits

Release lint reports 53 errors and 37 warnings. Repeating Java lint against the
previous fork reports the same 53 error tuples (file, issue, and message), with
zero new errors in the candidate. These comprise 51 `MissingPermission`
errors, one `NewApi` error for `InputDevice.isExternal` at minimum SDK 24, and
one `UnspecifiedRegisterReceiverFlag` error. They occur in SDL's BLE controller,
controller manager, and HID manager. The first two source files are unchanged;
the stable HID manager changes add vendor IDs.

The existing package verifier also rejects the APK because it looks for literal
`res/xml/backup_rules.xml` and `res/xml/data_extraction_rules.xml` paths. AAPT2
shows both resources are present under optimized names, and independent XML
decoding and 16 KB ZIP alignment checks pass. The verifier was not weakened and
the complete release command did not pass. Its failed run was not registered
as a completed release artifact. No signing, installation, or upload occurred.

### Duo simulator

The candidate was installed on the existing Accelerando Duo simulator with
iOS 27.1. Ready screen opening and portrait rotation preserve full display
geometry: 2853 x 2007 landscape and 2007 x 2853 portrait. Launching directly in
open portrait also fills the display correctly.

Closing during live play produced a 143.03 ms process gap and activated the
existing protective pause without advancing the run. No crash or run reset was
observed. The paused run stayed at 0.35 seconds through reopening, Book mode,
and rotation back to landscape. Keyboard capture was restored to off and the
dedicated simulator was shut down after verification. The simulator still uses
the fallback Metal renderer because its GPU
feature families do not satisfy SDL_GPU Metal. These results do not validate
custom GPU shaders on the simulator, uninterrupted live folding, physical Duo
timing, or held multitouch across folds.

## Consumer promotion

The candidate is kept separate while acceptance failures remain. All three
consumer staged pins and source checkouts remain at
`5637da187be335ffbc6b0bf171ca2401dbb88a36`; the shared pin verifier passes with
that explicit revision. Existing Afterglow and Counterpoint migration work is
preserved. No consumer application source changes are part of this update.
Accelerando's native configuration was restored to its pinned SDL source after
testing. Its beta simulator configuration was restored to the original sibling
fork override; the unsigned archive configuration again uses the pinned source.
Afterglow's source override was also restored to its original empty value, and
its staged and unstaged changes match the prevalidation state byte for byte.
Counterpoint's original submodule source path, dependency lock verification
(`ON`), and serializer benchmarks (`ON`) were restored. Its staged and unstaged
patch hashes and original status counts match their initial snapshots.

Restoring configuration does not rebuild all artifacts. Accelerando and
Afterglow retain candidate binaries until the next build. Counterpoint's SDL
archive and focused music/SFX binaries were rebuilt against the pinned baseline
for the comparison; its candidate and baseline results are preserved separately.

Mobile execution on physical devices, signed distribution, store acceptance,
and Windows/Linux builds are outside this validation. A passing unsigned iOS
archive does not fill those gates. Development main still needs a separate
upgrade evaluation before replacing the stable branch in any consumer.

## Evidence

Accelerando logs use `build-cpp/shared-sdl-3.4.16-*`; fork regressions reuse
`build-cpp/shared-sdl-fence-check`. Duo logs and screenshots use
`build-cpp/duo-validation/sdl-3.4.16-*`. Afterglow and Counterpoint logs use
`build/shared-sdl-3.4.16-*` in their respective checkouts. The iOS archive and its
validation receipt reuse `build-cpp/ios-archive/Accelerando.xcarchive`.

## Promotion update and fix audit

Later on September 24, the user authorized coordinated promotion of
`ccooper/sdl-3.4.16` to all three games. It is now the common integration branch.
The focused Afterglow and Counterpoint failures above were investigated and
repaired on their `main` branches, including the invalid telegraph fixture,
navigation defects, stale test assumptions, and native allocation attribution.
The consumer promotion commits record their final pins and validation. The
initial results above remain historical evidence; they are not a claim about
the final consumer suites. Android package acceptance, physical device checks,
and presentation pacing remain subject to the recorded limits.

A source and history audit of `df0089b020f4d749c04820f094cf6023d65bdec1`
confirmed that every shared fork fix is retained:

- All 24 commits after the original SDL 3.4.12 base through shared fork tip
  `da9acc85c05c52a693ae48d59a8b1ecb32c00c9d` are ancestors of this integration.
- Of the 29 files modified by that original fork, 24 are byte identical at the
  audited revision. These include CoreAudio guards, IO fixes and regressions,
  UIKit geometry and refresh handling, renderer uniform snapshots, interop,
  CPU timing, and the standalone fork tests. The remaining files are the
  maintenance README and four source files with upstream changes.
- The entire Metal GPU delta from the previous fork is patch equivalent to
  upstream `bcbdcaf6e`, with stable patch ID
  `74e6bf2572f5ac53d904f521f345aba2780983ed`. Custom pools, native interop,
  optional diagnostics, and clearing the native command buffer only after the
  final fence reference remain intact.
- The other three source deltas add upstream GPU transfer usage validation,
  Metal buffer allocation checks, and Vulkan attachment, render pass, and
  pending batch corrections. The earlier empty sampler and Vulkan command
  pool cleanup fixes remain present.
- The constant memory size correction in original `db11b3ae5`, the rewritten
  submission `9e7f23ce7`, and upstream `70e125ba8` has the same production patch
  ID, `df77bc31bffe543e04ff9790d6c92b241ec7a6af`. The fork also retains its broader
  tests of late properties, stream position, dynamic growth, and ownership.
- The six property initializers and `SDL_GetIOProperties` match the rewritten
  allocation failure submission `647503725` and upstream `7f3d0638` after
  ignoring comments and whitespace. Their boolean results, failure cleanup,
  delayed publication, and retry behavior are preserved. The fork additionally
  retains its isolated allocation failure regression.

All local branches and published `alistanis/SDL` branch heads were checked.
The two rewritten IO submission branches add no missing production repair.
The separate local `ccooper/metal-display-link-experiment` commits `1db2402c2`
and `f431d3cbd` remain outside the integration deliberately. They contain the
unaccepted CAMetalDisplayLink pacing experiment and additional GPU completion
measurement, including an extra callback with measurement overhead. The
Accelerando pacing investigation explicitly preserved them as unpublished
experiments without advancing the shared pin or establishing a pacing fix.
Its separate previous-texture-release patch likewise lacked evidence for
promotion. These experiments are preserved for investigation and are not
missing shared production fixes. No SDL source changes were needed for this
audit or promotion update.
