# Contributing to BAKE

Thank you for helping. This page covers how to contribute, what BAKE is looking for, and the rules every node and fix follows.

## Before your first pull request: the CLA

Every contributor signs the [Contributor License Agreement](CLA.md) once, before a first pull request is merged. A bot asks you on your first pull request; it takes a minute.

**Why:** BAKE is GPLv3, and its author also sells signed builds. The CLA lets your contribution go into those builds too, and lets the project change its license later if it needs to. You keep the copyright in your work, and your contribution stays available under the GPL like the rest of BAKE.

## What BAKE is looking for

BAKE renders offline. No node runs inside a live audio callback, so a node can read the whole input, look ahead, run many passes, solve, analyse, and use the GPU. **The best contributions use that:** whole-file analysis, global look-ahead, multi-pass optimisation, heavy spectral or matrix work in Metal, batch processing.

- **Not ordinary real-time ports.** A straight port of an everyday real-time plugin is unlikely to be accepted unless it does something only offline processing allows.
- **No real-time fallbacks or latency-bounded paths.** BAKE has no live mode to fall back to.
- **Musical defaults, wild extremes.** Defaults should sound good on the first bake; ranges should go far past what a real-time plugin would allow.

Not sure if an idea fits? Open an issue first and describe the sound you're after.

## How to contribute

1. **Branch** from the current `main`: `node-<kind>` for a node, `fix-<slug>` for a fix.
2. **Small steps that each build.** Run the tests often.
3. **Tests with every change** (see below), all passing:
   ```sh
   swift test --package-path BakeCore
   xcodebuild -workspace BAKE_WORKSPACE.xcworkspace -scheme BAKE -destination 'platform=macOS' \
     -derivedDataPath /tmp/bake-dd build
   ```
4. **Open a pull request** that says what changed, why, and how you tested it (paste the test summary lines). For a node, add what it sounds like and the settings you liked.

**Fixing a bug:** reproduce it first with a failing test, find the root cause, make the smallest fix that addresses it (no drive-by refactors), and show the test passing.

**Infrastructure** (the compiler, render engine, buffer pool, document format, canvas framework) needs a design discussion before code: open an issue describing what you need and why.

## Adding a node

The compiler's exhaustive `switch` statements tell you if you missed a registration point.

1. **Kind:** a `case` in `BakeCore/Sources/BakeGraph/Catalog/NodeKind.swift` (lower camel case). It is saved in documents, so it never changes once shipped.
2. **Definition:** in `BakeCore/Sources/BakeGraph/Catalog/NodeCatalog.swift`, a `NodeDefinition` with pins, parameters and a length rule, returned from `definition(for:)`.
   - Parameter IDs are saved in documents: lower camel case, stable forever. Names are what users see.
   - Every number has a unit and a range. Effects with a wet signal get a **Mix**.
   - Frequencies and rates use `scale: .exponential`; counts and steps use `integer: true`.
   - **Modulatable by default.** Every sound-shaping number and choice gets `modulatable: true`. Only what changes the length or structure stays fixed: length parameters, pin counts, FFT and frame sizes, band counts, filter slopes, seeds, oversampling.
   - **Saved documents never change sound.** Changing a default or adding a sound-affecting parameter to a node that already shipped needs a migration with a frozen default. Say so in your pull request.
   - Page 1 (`role: .macro`) holds the 2–5 controls people reach for; the rest is `role: .setting` (Page 2). Controls only some settings use get `shownWhen`.
3. **Kernel (C++20):** `BakeCore/Sources/BakeDSP/include/BakeDSP/<Name>.h` and `BakeCore/Sources/BakeDSP/<Name>.cpp`, namespace `bake::dsp`, and one `#include` line in `BakeDSP.h`.
4. **Processor (Swift):** `BakeCore/Sources/BakeRender/<Name>Processor.swift`, a `final class` conforming to `StepProcessor`. Read parameters with `bake.dsp.ParameterSignal`, control inputs with `bake.dsp.ControlInput` (never index a control input's buffer directly), and allocate everything in `init`. Register it in `makeProcessor` in `RenderEngine.swift`.
5. **Title and group:** the display name in `BakeGraph/Catalog/NodeKindTitle.swift`, the Add Node group in `NodeCategory.swift`, search words in `BakeCanvas/Model/NodeSearch.swift`, and readable choice names in `ParameterFormat.title(forChoice:of:)` if needed.
6. **Wiki page:** a one-line description and an optional "Try" tip in `Tools/wiki/node-descriptions.json`. The page itself is generated from the catalog (see `Tools/wiki/node_pages.py`).

## DSP rules

These protect BAKE's guarantees. Breaking one means the change can't be merged.

- **Deterministic.** The same document and inputs give bit-identical output. Randomness only from a seeded generator whose seed is a node parameter: no `rand()`, clocks, threads or uninitialised memory.
- **Chunk-invariant.** The engine calls `process` in chunks of any size, and the output must not depend on where they fall. Carry state between calls in a plain struct, index modulation by absolute frame, and align any blocks to absolute positions.
- **No allocation, locks or I/O in the per-sample path.** Size scratch buffers in the processor's `init`.
- **Plain C++ interface.** `noexcept` free functions over `const float*` / `float*` and counts, enums and small structs. No exceptions or owning objects across the Swift boundary.
- **Finite and bounded.** Never output NaN or infinity; guard divisions and feedback; feedback paths need a limit, and DC-producing processes a DC blocker.
- **Exact when unmodulated.** Kernels that take a fixed value read it with `bake::dsp::modulatedOr`, so an unmodulated render keeps its exact bits.
- **Licensing.** Write the DSP yourself from published algorithms. No code from GPL, LGPL or AGPL projects: BAKE's signed builds can't include it. Any vendored code needs a permissive license and an entry in `THIRD_PARTY_NOTICES.md`.

## Required tests

Swift Testing (`import Testing`, `@Test`, `#expect`), in `BakeCore/Tests/BakeRenderTests/<Name>Tests.swift`. Helpers are in `Tests/BakeRenderTests/Support/`. Every node needs:

1. **A known answer:** proof the effect does its job (Reverse equals the reversed input; Redux at 4 bits has at most 16 levels).
2. **Chunk invariance:** chunks of 777 frames equal one big chunk, bit for bit.
3. **Determinism:** two renders are identical; a different seed differs.
4. **Finite extremes:** every parameter at its minimum and maximum gives finite output.
5. **Modulation moves it:** for each modulatable parameter, a modulation signal changes the output.
6. **Every setting matters:** two values of each choice and Page 2 setting give different output.
7. **End to end** through `RenderEngine.render`, with the planned length and channel count.

## Code style

Swift 6 and Swift Testing; `@Observable`, not Combine; 4-space indentation; C++20 in `bake::dsp`. Comments only where the code isn't obvious, matching the code around them.
