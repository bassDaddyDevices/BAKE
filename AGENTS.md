# BAKE — instructions for coding agents

BAKE is an offline, node-based audio workstation for macOS 26+ (Apple Silicon): a SwiftUI app plus the Swift package `BakeCore` (graph compiler, C++ DSP, Metal GPU engine, canvas, bake session).

Follow [CONTRIBUTING.md](CONTRIBUTING.md): what BAKE is looking for, how to add a node, the DSP rules and the tests every change needs. In short:

- Work on a branch from current `main` (`node-<kind>` or `fix-<slug>`), in small steps that each build.
- Every change ships with tests. Before opening a pull request, run both and paste their summaries:
  - `swift test --package-path BakeCore`
  - `xcodebuild -workspace BAKE_WORKSPACE.xcworkspace -scheme BAKE -destination 'platform=macOS' -derivedDataPath /tmp/bake-dd build` (needs Xcode 27 with the Metal Toolchain)
- Don't change infrastructure (compiler, render engine, buffer pool, document format) without an issue first.
- Saved documents never change sound: a changed default or new sound-affecting parameter on a shipped node needs a migration.
- No code from GPL, LGPL or AGPL projects.

**Style:** Swift 6, Swift Testing, `@Observable` (no Combine), 4-space indentation, comments only where the code isn't obvious, matching the surrounding code. C++20 kernels in `bake::dsp`, `noexcept`, no allocation in per-sample loops.
