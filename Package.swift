// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Halide is an optional build-time dependency. Homebrew installs it into one of the first two
// roots; HALIDE_ROOT also supports source/binary releases and Linux CI images.
let halideRoots = [
    ProcessInfo.processInfo.environment["HALIDE_ROOT"],
    "/opt/homebrew",
    "/usr/local",
].compactMap { $0 }

let halideDisabled = ProcessInfo.processInfo.environment["FOTUFILM_DISABLE_HALIDE"] == "1"
let halideRoot = halideDisabled ? nil : halideRoots.first {
    FileManager.default.fileExists(atPath: "\($0)/include/Halide.h")
        && (FileManager.default.fileExists(atPath: "\($0)/lib/libHalide.dylib")
            || FileManager.default.fileExists(atPath: "\($0)/lib/libHalide.so"))
}

let halidePlatforms: [Platform] = [.macOS, .linux]
let halideCXXSettings: [CXXSetting] = halideRoot.map { root in
    [
        .define("FOTUFILM_HALIDE_ENABLED", .when(platforms: halidePlatforms)),
        .unsafeFlags(["-I\(root)/include", "-std=c++17"], .when(platforms: halidePlatforms)),
    ]
} ?? []
let halideLinkerSettings: [LinkerSetting] = halideRoot.map { root in
    [
        // Resolve relocatable Halide libraries as well as Homebrew installations.
        .unsafeFlags(
            ["-L\(root)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(root)/lib"],
            .when(platforms: halidePlatforms)),
        .linkedLibrary("Halide", .when(platforms: halidePlatforms)),
        .linkedFramework("Metal", .when(platforms: [.macOS])),
        .linkedLibrary("dl", .when(platforms: [.linux])),
        .linkedLibrary("pthread", .when(platforms: [.linux])),
    ]
} ?? []

#if os(Linux)
// CUDA benchmarking requires Halide. Objective-C++ Metal kernels require Apple frameworks.
let benchmarkTargets: [Target] = halideRoot != nil ? [
    .executableTarget(name: "fotufilmbench",
                      dependencies: ["FotufilmCore", "FotufilmHalide"]),
] : []
let benchmarkProducts: [Product] = halideRoot != nil ? [
    .executable(name: "fotufilmbench", targets: ["fotufilmbench"]),
] : []
let halideExcludedSources = ["FotufilmMetalGrain.mm"]
let halideGPUCXXSettings: [CXXSetting] = halideRoot != nil
    ? [.define("FOTUFILM_HALIDE_CUDA", .when(platforms: [.linux]))]
    : []

// SwiftPM builds every test file before applying filters; exclude Apple-only fixtures on Linux.
let appleOnlyTests = [
    // Unguarded CoreGraphics/CoreImage/ImageIO: these five reach Apple's frameworks directly.
    "Golden/RGBAImage.swift",
    "GamutShowcaseTool.swift",
    "LensCorpusHarness.swift",
    "LensCorrectionFilterTests.swift",
    "UnitCropCoordinatesTests.swift",
    // Golden-image tests use ImageIO through RGBAImage.
    "Golden/PrintDifference.swift",
    "Golden/GoldenStore.swift",
    "Golden/GoldenStocks.swift",
    "Golden/ReferenceChart.swift",
    "Golden/ContactSheet.swift",
    "Golden/InstrumentTests.swift",
    "GoldenImageTests.swift",
    "SelfRetentionMeasurement.swift",
    "SpectrumSceneTests.swift",
]
#else
let benchmarkTargets: [Target] = []
let benchmarkProducts: [Product] = []
let halideExcludedSources: [String] = []
let halideGPUCXXSettings: [CXXSetting] = []
let appleOnlyTests: [String] = []
#endif

let package = Package(
    name: "Fotufilm",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "FotufilmCore", targets: ["FotufilmCore"]),
        .library(name: "FotufilmUpdate", targets: ["FotufilmUpdate"]),
        .library(name: "FotufilmMetal", targets: ["FotufilmMetal"]),
        .library(name: "FotufilmImaging", targets: ["FotufilmImaging"]),
        .library(name: "FotufilmStockMatch", targets: ["FotufilmStockMatch"]),
        .library(name: "FotufilmEditModel", targets: ["FotufilmEditModel"]),
        .executable(name: "fotufilm", targets: ["fotufilm"]),
    ] + benchmarkProducts,
    targets: [
        .target(name: "FotufilmUpdate"),
        .target(
            name: "FotufilmHalide",
            path: "Sources/FotufilmHalide",
            exclude: halideExcludedSources,
            publicHeadersPath: "include",
            cxxSettings: halideCXXSettings + halideGPUCXXSettings,
            linkerSettings: halideLinkerSettings
        ),
        .target(
            name: "FotufilmCore",
            dependencies: ["FotufilmHalide"],
            // Process camera profiles individually so dependency directory links are
            // dereferenced into self-contained resources. Stocks retain their pack directory.
            resources: [.process("Resources"),
                        .process("CameraProfiles"),
                        .copy("Stocks")]
        ),
        .target(
            name: "FotufilmMetal",
            dependencies: ["FotufilmCore", "FotufilmHalide"],
            // Release apps carry only HandwrittenFotufilm.metallib. Local source compilation finds
            // these maintainable files from the working tree without packaging them as resources.
            exclude: ["Shaders"]
        ),
        // Core Image decoding and resampling shared by both apps and the CLI.
        .target(name: "FotufilmImaging", dependencies: ["FotufilmCore"]),
        // Choosing the film a photograph opens on.
        .target(name: "FotufilmStockMatch", dependencies: ["FotufilmCore"]),
        // Shared editor controls and their engine options.
        .target(name: "FotufilmEditModel", dependencies: ["FotufilmCore"]),
        .executableTarget(name: "fotufilm", dependencies: ["FotufilmCore", "FotufilmImaging"]),
        .testTarget(
            name: "FotufilmCoreTests",
            dependencies: ["FotufilmCore", "FotufilmMetal", "FotufilmImaging",
                           "FotufilmStockMatch"],
            // Reference pictures and golden renders, read from the source tree by `#filePath`
            // rather than from a bundle.
            exclude: ["Golden/Goldens", "Golden/References", "Golden/README.md"]
                + appleOnlyTests
        ),
        .testTarget(
            name: "FotufilmEditModelTests",
            dependencies: ["FotufilmEditModel", "FotufilmCore"]
        ),
        .testTarget(
            name: "FotufilmUpdateTests",
            dependencies: ["FotufilmUpdate"]
        ),
    ] + benchmarkTargets
)
