// swift-tools-version: 5.9
import PackageDescription

// Glims: a classic native Mac image editor on the GIMP engine (docs/plan.md).
//
//   - `GlimsKit`: the AppKit interface, built with RigiUI. It will talk to the
//     engine only through the facade C API of the planned `Engine/` adapter;
//     it never includes GIMP headers.
//   - `Glims`: the thin executable.
//
// Rigi is pinned to an immutable revision (Rigi's README asks consumers to);
// move the pin only after Rigi's own checks pass at the new revision.
let package = Package(
    name: "Glims",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Glims", targets: ["Glims"])
    ],
    dependencies: [
        .package(url: "https://github.com/L-K-M/Rigi.git",
                 revision: "dcfc91e3b72aee612b2b48aed4a744397b78dc77")
    ],
    targets: [
        .target(
            name: "GlimsKit",
            dependencies: [.product(name: "RigiUI", package: "rigi")]
        ),
        .executableTarget(
            name: "Glims",
            dependencies: ["GlimsKit"]
        ),
        .testTarget(
            name: "GlimsKitTests",
            dependencies: ["GlimsKit"]
        )
    ]
)
