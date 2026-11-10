// swift-tools-version: 5.9
import PackageDescription

// Glims: a classic native Mac image editor on the GIMP engine (docs/plan.md).
//
//   - `CGlimsEngine`: the engine facade header (`glims_engine.h`).
//   - `GlimsKit`: the AppKit interface, built with RigiUI. It talks to the
//     engine only through the facade, loading the adapter library built
//     from `Engine/` at run time; it never includes GIMP headers.
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
                 revision: "13ec06a508025a71234f708efd1e36aef85a88c4")
    ],
    targets: [
        // The engine facade header, shared with the C adapter in Engine/.
        // The adapter itself is loaded at run time, so the app builds and
        // runs without it.
        .target(name: "CGlimsEngine"),
        .target(
            name: "GlimsKit",
            dependencies: ["CGlimsEngine", .product(name: "RigiUI", package: "rigi")],
            resources: [.copy("Resources/GlimsManual.txt")]
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
