// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AstroKit",
    platforms: [
        .macOS("26.0")  // macOS 26.0 and higher
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "AstroKit",
            targets: ["AstroKit"]),
        .library(
            name: "HEALPixKit",
            targets: ["HEALPixKit"]),
        .library(
            name: "AstroKitUI",
            targets: ["AstroKitUI"]),
        .library(
            name: "VSOP",
            targets: ["VSOP"]),
        .library(
            name: "AstrophotoKit",
            targets: ["AstrophotoKit"]),
        .library(
            name: "AstrophotoArchiveKit",
            targets: ["AstrophotoArchiveKit"]),
        .library(
            name: "AstrophotoToolDefinitions",
            targets: ["AstrophotoToolDefinitions"]),
        .library(
            name: "AstrophotoToolsKit",
            targets: ["AstrophotoToolsKit"]),
        .executable(name: "ap", targets: ["ap"]),
        .executable(name: "ap-archive", targets: ["ap-archive"]),
        .executable(name: "astrokit-mcp", targets: ["astrokit-mcp"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // MARK: - AstroKit (vendored ERFA C lib + Swift astronomy algorithms)

        .target(
            name: "CERFA",
            path: "Sources/CERFA",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AstroKit",
            dependencies: ["CERFA"],
            path: "Sources/AstroKit",
            swiftSettings: [
                // Swift's cross-module optimization (CMO) incorrectly constant-propagates
                // nonisolated(unsafe) globals (Planet.positionProvider, SphericalPosition.ephemeris)
                // across module boundaries, producing wrong rise/transit/set results in release builds.
                .unsafeFlags(["-Xfrontend", "-disable-cmo"], .when(configuration: .release))
            ]
        ),
        .target(
            name: "AstroKitUI",
            dependencies: ["AstroKit"],
            path: "Sources/AstroKitUI"
        ),
        .target(
            name: "VSOP",
            dependencies: ["AstroKit"],
            path: "Sources/VSOP"
        ),

        // MARK: - HEALPixKit (vendored healpix_cxx + Swift wrapper)

        .target(
            name: "CHEALPix",
            path: "Sources/CHEALPix",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("."),
                .define("HEALPIX_NO_OPENMP"),
            ]
        ),
        .target(
            name: "HEALPixKit",
            dependencies: ["CHEALPix"]
        ),

        // MARK: - AstrophotoKit (image processing)

        // Build tool that generates Version.generated.swift at every build.
        .executableTarget(
            name: "version-tool",
            path: "Sources/version-tool"
        ),
        .plugin(
            name: "VersionPlugin",
            capability: .buildTool(),
            dependencies: ["version-tool"]
        ),
        // System CFITSIO library (Homebrew / apt)
        .systemLibrary(
            name: "CCFITSIO",
            pkgConfig: "cfitsio",
            providers: [
                .brew(["cfitsio"]),
                .apt(["libcfitsio-dev"])
            ]
        ),
        // C wrapper target that implements wrapper functions
        .target(
            name: "CCFITSIOWrapper",
            dependencies: ["CCFITSIO"],
            path: "Sources/CCFITSIO",
            sources: ["cfitsio_wrapper.c"],
            publicHeadersPath: ".",
            linkerSettings: [
                .linkedLibrary("cfitsio")
            ]
        ),
        // Swift target that depends on the C library and wrapper
        .target(
            name: "AstrophotoKit",
            dependencies: ["CCFITSIO", "CCFITSIOWrapper", "Yams", "AstroKit"],
            exclude: [
                "Pipelines/_archive_v1"  // Exclude archived pipeline code from compilation to prevent naming conflicts
            ],
            resources: [
                .process("Shaders"),  // Include Metal shader source files as resources
                .process("Resources")  // Include pipeline configuration files
            ],
            plugins: ["VersionPlugin"]),
        .executableTarget(
            name: "ap",
            dependencies: [
                "AstrophotoKit",
                "AstrophotoArchiveKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ap"
        ),

        // MARK: - AstrophotoArchiveKit

        .target(
            name: "AstrophotoArchiveKit",
            dependencies: [
                "AstrophotoKit",
                "AstroKit",
                "HEALPixKit",
            ],
            path: "Sources/AstrophotoArchiveKit"
        ),
        .executableTarget(
            name: "ap-archive",
            dependencies: [
                "AstrophotoArchiveKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ap-archive"
        ),
        .target(
            name: "AstrophotoToolDefinitions",
            path: "Sources/AstrophotoToolDefinitions"
        ),
        .target(
            name: "AstrophotoToolsKit",
            dependencies: ["AstrophotoKit", "AstrophotoArchiveKit", "AstrophotoToolDefinitions"],
            path: "Sources/AstrophotoToolsKit"
        ),
        .executableTarget(
            name: "astrokit-mcp",
            dependencies: ["AstrophotoKit", "AstrophotoArchiveKit", "AstrophotoToolDefinitions", "AstrophotoToolsKit"],
            path: "Sources/astrokit-mcp"
        ),

        // MARK: - Tests

        .testTarget(
            name: "AstroKitTests",
            dependencies: ["AstroKit"]
        ),
        .testTarget(
            name: "HEALPixKitTests",
            dependencies: ["HEALPixKit"]
        ),
        .testTarget(
            name: "VSOPTests",
            dependencies: ["VSOP"]
        ),
        .testTarget(
            name: "AstrophotoKitTests",
            dependencies: ["AstrophotoKit"],
            exclude: [
                "Resources/M51/processed"  // Exclude processed subfolder — duplicate filenames conflict with M51/
            ],
            resources: [
                .process("Resources")  // Include all FITS test files
            ]),
        .testTarget(
            name: "AstrophotoArchiveKitTests",
            dependencies: ["AstrophotoArchiveKit"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
