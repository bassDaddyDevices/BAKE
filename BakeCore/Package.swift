// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BakeCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BakeGraph", targets: ["BakeGraph"]),
        .library(name: "BakeRender", targets: ["BakeRender"]),
        .library(name: "BakeCanvas", targets: ["BakeCanvas"]),
        .library(name: "BakeSession", targets: ["BakeSession"]),
    ],
    targets: [
        // Pure Swift: graph model, compiler, project format. No C++, no Metal.
        .target(name: "BakeGraph"),
        // CPU engine: C++20 time-domain kernels, imported into Swift via C++ interop.
        // Vendor/ holds third-party headers (MIT); it is not part of the public include/.
        // DSP is optimised in Debug too: unoptimised Stretch made Debug bakes minutes long.
        .target(name: "BakeDSP", cxxSettings: [
            .headerSearchPath("Vendor"),
            .unsafeFlags(["-O2"], .when(configuration: .debug)),
        ], linkerSettings: [
            // vDSP's FFT (Fft.cpp); the portable radix-2 FFT stays as the reference.
            .linkedFramework("Accelerate"),
        ]),
        // GPU engine: Metal compute shaders and their Swift host.
        .target(name: "BakeGPU", resources: [.process("Shaders")]),
        // Swift render engine: owns the shared buffer pool and drives both engines.
        .target(
            name: "BakeRender",
            dependencies: ["BakeGraph", "BakeDSP", "BakeGPU"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // Canvas UI: SwiftUI node editor over the BakeGraph model. No C++, no Metal.
        .target(name: "BakeCanvas", dependencies: ["BakeGraph"]),
        // Bake orchestration for the app: file access, compile, render, progress, problems.
        // Imports BakeRender, so it needs C++ interop (as does anything that imports it).
        .target(
            name: "BakeSession",
            dependencies: ["BakeGraph", "BakeRender"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .testTarget(name: "BakeGraphTests", dependencies: ["BakeGraph"]),
        .testTarget(
            name: "BakeSessionTests",
            dependencies: ["BakeSession", "BakeGraph", "BakeRender"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .testTarget(name: "BakeCanvasTests", dependencies: ["BakeCanvas", "BakeGraph"]),
        .testTarget(name: "BakeGPUTests", dependencies: ["BakeGPU"]),
        .testTarget(
            name: "BakeRenderTests",
            dependencies: ["BakeRender", "BakeGraph", "BakeGPU", "BakeDSP"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
