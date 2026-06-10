// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AstrophotoKit",
    platforms: [
        .macOS("26.0")  // macOS 26.0 and higher
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "AstrophotoKit",
            targets: ["AstrophotoKit"]),
        .library(
            name: "AstrophotoArchiveKit",
            targets: ["AstrophotoArchiveKit"]),
        .library(
            name: "AstrophotoToolDefinitions",
            targets: ["AstrophotoToolDefinitions"]),
        .executable(name: "ap", targets: ["ap"]),
        .executable(name: "ap-archive", targets: ["ap-archive"]),
        .executable(name: "astrokit-mcp", targets: ["astrokit-mcp"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/Oekalegon/HEALPixKit.git", from: "1.0.0"),
    ],
    targets: [
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
            dependencies: ["CCFITSIO", "CCFITSIOWrapper", "Yams"],
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
        .target(
            name: "AstrophotoArchiveKit",
            dependencies: [
                "AstrophotoKit",
                .product(name: "HEALPixKit", package: "HEALPixKit"),
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
        .executableTarget(
            name: "astrokit-mcp",
            dependencies: ["AstrophotoKit", "AstrophotoArchiveKit", "AstrophotoToolDefinitions"],
            path: "Sources/astrokit-mcp"
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
    ]
)
