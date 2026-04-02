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
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
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
            ]),
        .testTarget(
            name: "AstrophotoKitTests",
            dependencies: ["AstrophotoKit"],
            exclude: [
                "Resources/M51/processed"  // Exclude processed subfolder — duplicate filenames conflict with M51/
            ],
            resources: [
                .process("Resources")  // Include all FITS test files
            ])
    ]
)
