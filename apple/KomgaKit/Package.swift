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
        .library(name: "KomgaFeatures", targets: ["KomgaFeatures"]),
        .library(name: "KomgaDownloads", targets: ["KomgaDownloads"])
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
        // Stage 9's offline download system, ported. The queue policy is pure and
        // depends on nothing; the store, tree and engine arrive with the rest of
        // the port and will pull in KomgaStore / KomgaAPI / KomgaReader.
        .target(name: "KomgaDownloads"),
        .testTarget(name: "KomgaKitTests", dependencies: ["KomgaAPI", "KomgaStore", "KomgaSync", "KomgaReader", "KomgaDiagnostics", "KomgaDownloads"])
    ]
)
