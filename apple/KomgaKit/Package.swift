// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KomgaKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "KomgaDiagnostics", targets: ["KomgaDiagnostics"]),
        .library(name: "KomgaAPI", targets: ["KomgaAPI"]),
        .library(name: "KomgaStore", targets: ["KomgaStore"]),
        .library(name: "KomgaSync", targets: ["KomgaSync"]),
        .library(name: "KomgaReader", targets: ["KomgaReader"]),
        .library(name: "KomgaFeatures", targets: ["KomgaFeatures"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(name: "KomgaDiagnostics"),
        .target(name: "KomgaAPI", dependencies: ["KomgaDiagnostics"]),
        .target(
            name: "KomgaStore",
            dependencies: ["KomgaAPI", "KomgaDiagnostics", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "KomgaSync", dependencies: ["KomgaAPI", "KomgaStore"]),
        .target(name: "KomgaReader", dependencies: ["KomgaAPI", "KomgaStore", "KomgaSync"]),
        .target(
            name: "KomgaFeatures",
            dependencies: ["KomgaAPI", "KomgaStore", "KomgaSync", "KomgaReader"]
        ),
        .testTarget(name: "KomgaKitTests", dependencies: ["KomgaAPI", "KomgaStore", "KomgaSync", "KomgaReader", "KomgaDiagnostics"])
    ]
)
