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
        // Homebrew's libHalide carries its own install name as an absolute Cellar path, which
        // needed nothing further here. A relocatable toolchain — the one this project's own
        // scripts now build (tools/build-halide-toolchain.sh) and CI fetches — has to be
        // @rpath-relative to be relocatable at all, and an @rpath the linker never resolves is
        // an executable that finds nothing at launch: "Library not loaded: @rpath/libHalide….
        // dylib". Harmless to add unconditionally — an absolute install name ignores an rpath
        // that also happens to be true.
        .unsafeFlags(
            ["-L\(root)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(root)/lib"],
            .when(platforms: halidePlatforms)),
        .linkedLibrary("Halide", .when(platforms: halidePlatforms)),
        .linkedFramework("Metal", .when(platforms: [.macOS])),
        .linkedLibrary("dl", .when(platforms: [.linux])),
        .linkedLibrary("pthread", .when(platforms: [.linux])),
    ]
} ?? []

// The hand-written Metal kernels are Objective-C++ against Apple frameworks, so they cannot
// compile where those frameworks do not exist. Everything else in the target is portable:
// FotufilmHalideMetal.cpp carries the GPU pipeline for every backend, and on Linux it compiles
// against CUDA (see FOTUFILM_HALIDE_CUDA below). FotufilmHalideIOS.cpp needs no exclusion — it is
// already inert unless FOTUFILM_HALIDE_IOS_AOT is defined.
//
// `fotufilmbench` is a Linux-only tool, so it does not appear in an Apple build's target list at
// all — `fotufilm` remains the only executable there.
#if os(Linux)
// The benchmark times the CUDA path against the CPU one, so it has nothing to measure in a build
// with no Halide in it: without halideRoot the CUDA entry points are never compiled, and a target
// that referenced them anyway would fail to link rather than fail to be useful.
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

// What the engine's own test target cannot compile on a machine with no Apple frameworks. It is
// a shorter list than it looks: FotufilmImaging and FotufilmMetal guard their Apple imports
// internally and build as near-empty modules here, so a test may depend on either and still be
// portable. `swift test --filter` is no substitute for this — SwiftPM builds every target before
// it filters anything, so one unbuildable file takes the whole run down.
let appleOnlyTests = [
    // Unguarded CoreGraphics/CoreImage/ImageIO: these five reach Apple's frameworks directly.
    "Golden/RGBAImage.swift",
    "GamutShowcaseTool.swift",
    "LensCorpusHarness.swift",
    "LensCorrectionFilterTests.swift",
    "UnitCropCoordinatesTests.swift",
    // Portable Swift to a file, but all of it built on RGBAImage, which is not: the golden
    // harness reads and writes PNGs through ImageIO. Porting that one file is what would bring
    // the golden suite back here, and nothing else is in the way.
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
        // Checking the Mac app for a new release: the feed document and the rule for deciding
        // one version is newer than another, kept pure so the suite can hold it.
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
        // The editor's control catalogue: what the app offers a photographer, described once so
        // that the panel, the badges and the resets read the same list — and so that the list can
        // be checked against the engine's own option set.
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
