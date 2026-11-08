import XCTest
import Darwin
@testable import GlimsKit

/// Engine discovery for source builds: a SwiftPM executable inside a
/// checkout's `.build` tree finds the pinned adapter under
/// `_engine/adapter/` without `GLIMS_ENGINE_LIBRARY`, while the environment,
/// the user default and the bundle's Frameworks keep precedence and app
/// bundles never fall back to the checkout. Everything runs on fake trees in
/// a temporary folder; no library is loaded and no shell is run.
final class EngineLibraryTests: XCTestCase {
    private var base: URL!
    private let files = FileManager.default

    /// Shaped like scripts/engine.env: the pinned engine is the first
    /// ENGINE_SETS entry.
    private let defaultEngineEnv = """
    # Engine sets as GIMP_REF:BABL_REF:GEGL_REF.
    ENGINE_SETS="GIMP_3_2_8:BABL_0_1_128:GEGL_0_4_72 GIMP_3_2_0:BABL_0_1_124:GEGL_0_4_68 master:master:master GIMP_3_0_8:BABL_0_1_120:GEGL_0_4_66"
    """

    override func setUp() {
        let directory = files.temporaryDirectory
            .appendingPathComponent("glims-engine-library-tests-\(UUID().uuidString)", isDirectory: true)
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        // /var is a symlink to /private/var; discovery reports resolved paths.
        base = directory.resolvingSymlinksInPath()
    }

    override func tearDown() {
        try? files.removeItem(at: base)
        base = nil
    }

    private func makeFile(_ relative: String, in root: URL, contents: String = "") throws {
        let url = root.appendingPathComponent(relative)
        try files.createDirectory(at: url.deletingLastPathComponent(),
                                  withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A fake checkout. `engineEnv` is written to scripts/engine.env unless
    /// `includeEngineEnv` is false; `adapterRefs` are the refs that get an
    /// (empty) libglimsengine.dylib marker.
    private func makeCheckout(name: String = "checkout",
                              engineEnv: String? = nil,
                              includeEngineEnv: Bool = true,
                              packageSwift: Bool = true,
                              adapterRefs: [String] = ["GIMP_3_2_8"]) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        if packageSwift { try makeFile("Package.swift", in: root) }
        if includeEngineEnv {
            try makeFile("scripts/engine.env", in: root, contents: engineEnv ?? defaultEngineEnv)
        }
        for ref in adapterRefs {
            try makeFile("_engine/adapter/\(ref)/\(EngineLibrary.fileName)", in: root)
        }
        return root
    }

    private func discover(_ executable: URL,
                          environment: [String: String] = [:],
                          defaults: UserDefaults? = nil,
                          bundle: Bundle? = nil) -> String? {
        let suite = "glims-engine-tests.\(UUID().uuidString)"
        let resolved = defaults ?? UserDefaults(suiteName: suite)!
        defer { resolved.removePersistentDomain(forName: suite) }
        return EngineLibrary.configuredPath(environment: environment,
                                            defaults: resolved,
                                            bundle: bundle ?? .main,
                                            executable: executable)
    }

    private func adapterPath(_ ref: String = "GIMP_3_2_8", in root: URL) -> String {
        root.appendingPathComponent("_engine/adapter/\(ref)/\(EngineLibrary.fileName)").path
    }

    func testDebugAndReleaseBuildLayoutsFindThePinnedAdapter() throws {
        let root = try makeCheckout()
        for layout in [".build/debug/Glims",
                       ".build/arm64-apple-macosx/debug/Glims",
                       ".build/arm64-apple-macosx/release/Glims",
                       ".build/x86_64-apple-macosx/release/Glims"] {
            try makeFile(layout, in: root)
            XCTAssertEqual(discover(root.appendingPathComponent(layout)),
                           adapterPath(in: root), layout)
        }
    }

    func testBuildDirectorySymlinkResolvesToTheRealExecutable() throws {
        let root = try makeCheckout()
        try makeFile(".build/arm64-apple-macosx/debug/Glims", in: root)
        try files.createSymbolicLink(
            atPath: root.appendingPathComponent(".build/debug").path,
            withDestinationPath: "arm64-apple-macosx/debug")
        XCTAssertEqual(discover(root.appendingPathComponent(".build/debug/Glims")),
                       adapterPath(in: root))
    }

    func testExecutableSymlinkLeavingTheBuildTreeFindsNothing() throws {
        let root = try makeCheckout()
        try makeFile("outside/Glims", in: base)
        try files.createDirectory(at: root.appendingPathComponent(".build/debug"),
                                  withIntermediateDirectories: true)
        try files.createSymbolicLink(
            atPath: root.appendingPathComponent(".build/debug/Glims").path,
            withDestinationPath: base.appendingPathComponent("outside/Glims").path)
        XCTAssertNil(discover(root.appendingPathComponent(".build/debug/Glims")))
    }

    func testSymlinkedCheckoutPathStillFindsTheAdapter() throws {
        let root = try makeCheckout(name: "real")
        let link = base.appendingPathComponent("linked")
        try files.createSymbolicLink(atPath: link.path, withDestinationPath: root.path)
        try makeFile(".build/debug/Glims", in: link)
        XCTAssertEqual(discover(link.appendingPathComponent(".build/debug/Glims")),
                       adapterPath(in: root))
    }

    func testEnvironmentBeatsSourceDiscovery() throws {
        let root = try makeCheckout()
        try makeFile(".build/debug/Glims", in: root)
        XCTAssertEqual(discover(root.appendingPathComponent(".build/debug/Glims"),
                                environment: [EngineLibrary.environmentVariable: "/tmp/from-env.dylib"]),
                       "/tmp/from-env.dylib")
    }

    func testUserDefaultBeatsSourceDiscovery() throws {
        let root = try makeCheckout()
        try makeFile(".build/debug/Glims", in: root)
        let suite = "glims-engine-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("/tmp/from-defaults.dylib", forKey: EngineLibrary.defaultsKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(discover(root.appendingPathComponent(".build/debug/Glims"),
                                defaults: defaults),
                       "/tmp/from-defaults.dylib")
    }

    func testEnvironmentBeatsUserDefault() throws {
        let suite = "glims-engine-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("/tmp/from-defaults.dylib", forKey: EngineLibrary.defaultsKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(discover(URL(fileURLWithPath: "/nonexistent/Glims"),
                                environment: [EngineLibrary.environmentVariable: "/tmp/from-env.dylib"],
                                defaults: defaults),
                       "/tmp/from-env.dylib")
    }

    func testBundleFrameworksBeatSourceDiscovery() throws {
        let root = try makeCheckout()
        try makeFile(".build/debug/Glims", in: root)
        let app = base.appendingPathComponent("Fake.app", isDirectory: true)
        try makeFile("Contents/Frameworks/\(EngineLibrary.fileName)", in: app)
        try makeFile("Contents/Info.plist", in: app,
                     contents: "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>")
        let bundle = try XCTUnwrap(Bundle(path: app.path))
        XCTAssertEqual(discover(root.appendingPathComponent(".build/debug/Glims"), bundle: bundle),
                       app.appendingPathComponent("Contents/Frameworks/\(EngineLibrary.fileName)").path)
    }

    func testAppBundleExecutablesNeverUseSourceDiscovery() throws {
        let root = try makeCheckout()
        // A shell-only layout next to the checkout: dist/Glims.app.
        try makeFile("dist/Glims.app/Contents/MacOS/Glims", in: root)
        XCTAssertNil(discover(root.appendingPathComponent("dist/Glims.app/Contents/MacOS/Glims")))
        // Even an app bundle inside .build is shipped code, not a source build.
        try makeFile(".build/debug/Glims.app/Contents/MacOS/Glims", in: root)
        XCTAssertNil(discover(root.appendingPathComponent(".build/debug/Glims.app/Contents/MacOS/Glims")))
        for app in ["GLIMS.APP/Contents", "Glims.App/CONTENTS", "Glims.app/contents"] {
            let layout = ".build/debug/\(app)/MacOS/Glims"
            try makeFile(layout, in: root)
            XCTAssertNil(discover(root.appendingPathComponent(layout)), app)
        }
    }

    func testSourceMarkersAndAdapterMustBeRegularFiles() throws {
        for relative in ["Package.swift", "scripts/engine.env",
                         "_engine/adapter/GIMP_3_2_8/\(EngineLibrary.fileName)"] {
            let root = try makeCheckout(name: UUID().uuidString)
            try makeFile(".build/debug/Glims", in: root)
            let file = root.appendingPathComponent(relative)
            try files.removeItem(at: file)
            try files.createDirectory(at: file, withIntermediateDirectories: false)
            XCTAssertNil(discover(root.appendingPathComponent(".build/debug/Glims")), relative)
        }
    }

    func testSourceRegularFilesMayBeSymlinks() throws {
        let root = try makeCheckout()
        try makeFile(".build/debug/Glims", in: root)
        for relative in ["Package.swift", "scripts/engine.env",
                         "_engine/adapter/GIMP_3_2_8/\(EngineLibrary.fileName)"] {
            let file = root.appendingPathComponent(relative)
            let target = file.appendingPathExtension("real")
            try files.moveItem(at: file, to: target)
            try files.createSymbolicLink(at: file, withDestinationURL: target)
        }
        XCTAssertEqual(discover(root.appendingPathComponent(".build/debug/Glims")), adapterPath(in: root))
    }

    func testEnginePinFIFOIsRefusedWithoutWaitingForAWriter() throws {
        let root = try makeCheckout()
        try makeFile(".build/debug/Glims", in: root)
        let env = root.appendingPathComponent("scripts/engine.env")
        try files.removeItem(at: env)
        XCTAssertEqual(mkfifo(env.path, 0o600), 0)
        // Keep both ends open so the old reader cannot block in open().
        // A delayed, finite write releases its read even on the red run.
        let descriptor = open(env.path, O_RDWR | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let data = Data(defaultEngineEnv.utf8)
        let writerFinished = expectation(description: "FIFO cleanup")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            data.withUnsafeBytes { _ = Darwin.write(descriptor, $0.baseAddress, $0.count) }
            Darwin.close(descriptor)
            writerFinished.fulfill()
        }
        let start = Date()
        XCTAssertNil(discover(root.appendingPathComponent(".build/debug/Glims")))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
        wait(for: [writerFinished], timeout: 2)
    }

    func testMultilineAndTrailingShellSyntaxAreNotEngineAssignments() throws {
        for text in [
            "ENGINE_SETS=GIMP_3_2_8:B:C\nOTHER='\nENGINE_SETS=master:B:C\n'\n",
            "ENGINE_SETS=\"GIMP_3_2_8:B:C\"; ENGINE_SETS=master:B:C\n",
        ] {
            let root = try makeCheckout(name: UUID().uuidString, engineEnv: text,
                                        adapterRefs: ["GIMP_3_2_8", "master"])
            try makeFile(".build/debug/Glims", in: root)
            XCTAssertNil(discover(root.appendingPathComponent(".build/debug/Glims")))
        }
    }

    func testExecutablesOutsideABuildTreeAreNotSearched() throws {
        let root = try makeCheckout()
        // A stray binary at the checkout root is not a SwiftPM product.
        try makeFile("Glims", in: root)
        XCTAssertNil(discover(root.appendingPathComponent("Glims")))
        // A .build tree whose parent is not a checkout qualifies for nothing.
        try makeFile("elsewhere/.build/debug/Glims", in: base)
        XCTAssertNil(discover(base.appendingPathComponent("elsewhere/.build/debug/Glims")))
        // No .build ancestor at all; the process cwd is never consulted.
        try makeFile("tools/Glims", in: base)
        XCTAssertNil(discover(base.appendingPathComponent("tools/Glims")))
        XCTAssertNil(discover(URL(fileURLWithPath: "/usr/bin/true")))
    }

    func testIncompleteCheckoutsReturnNil() throws {
        var root = try makeCheckout(name: "no-package", packageSwift: false)
        try makeFile(".build/debug/Glims", in: root)
        XCTAssertNil(discover(root.appendingPathComponent(".build/debug/Glims")))

        root = try makeCheckout(name: "no-engine-env", includeEngineEnv: false)
        try makeFile(".build/debug/Glims", in: root)
        XCTAssertNil(discover(root.appendingPathComponent(".build/debug/Glims")))

        root = try makeCheckout(name: "no-adapter", adapterRefs: [])
        try makeFile(".build/debug/Glims", in: root)
        XCTAssertNil(discover(root.appendingPathComponent(".build/debug/Glims")))

        // Only a different engine set's adapter is present: the pinned ref
        // is the first ENGINE_SETS entry, not any built adapter.
        root = try makeCheckout(name: "other-adapter", adapterRefs: ["master"])
        try makeFile(".build/debug/Glims", in: root)
        XCTAssertNil(discover(root.appendingPathComponent(".build/debug/Glims")))
    }

    func testMalformedEngineSetsReturnNil() throws {
        let malformed = [
            "# only a comment\nMATRIX_SETS=\"GIMP_3_2_8\"\n",
            "# ENGINE_SETS=\"GIMP_3_2_8:B:C\"\n",
            "ENGINE_SETS =\"GIMP_3_2_8:B:C\"\n",
            "ENGINE_SETS=\n",
            "ENGINE_SETS=\"\"\n",
            "ENGINE_SETS=\"GIMP_3_2_8:B:C\n",
            "ENGINE_SETS=\"GIMP_3_2_8:B:C'\n",
            "ENGINE_SETS=\"GIMP_3_2_8:B:C\"\nENGINE_SETS=\n",
        ]
        for (index, contents) in malformed.enumerated() {
            let root = try makeCheckout(name: "malformed-\(index)", engineEnv: contents)
            try makeFile(".build/debug/Glims", in: root)
            XCTAssertNil(discover(root.appendingPathComponent(".build/debug/Glims")),
                         "case \(index): \(contents.debugDescription)")
        }
    }

    /// Each unsafe ref gets the adapter its naive path would name planted, so
    /// a nil answer can only come from ref validation, not a missing file.
    func testUnsafeEngineRefsReturnNil() throws {
        let unsafe: [(String, String, String?)] = [
            ("dotdot", "ENGINE_SETS=\"..:B:C\"\n", "_engine/libglimsengine.dylib"),
            ("dot", "ENGINE_SETS=\".:B:C\"\n", "_engine/adapter/libglimsengine.dylib"),
            ("separator", "ENGINE_SETS=\"a/b:B:C\"\n", "_engine/adapter/a/b/libglimsengine.dylib"),
            ("backslash", "ENGINE_SETS=\"a\\b:B:C\"\n", "_engine/adapter/a\\b/libglimsengine.dylib"),
            ("dollar", "ENGINE_SETS=\"$X/B:C\"\n", "_engine/adapter/$X/libglimsengine.dylib"),
            ("backtick", "ENGINE_SETS=\"`id`:B:C\"\n", "_engine/adapter/`id`/libglimsengine.dylib"),
            ("empty", "ENGINE_SETS=\":B:C D:E:F\"\n", nil),
        ]
        for (name, contents, planted) in unsafe {
            let root = try makeCheckout(name: "unsafe-\(name)", engineEnv: contents,
                                        adapterRefs: [])
            if let planted { try makeFile(planted, in: root) }
            try makeFile(".build/debug/Glims", in: root)
            XCTAssertNil(discover(root.appendingPathComponent(".build/debug/Glims")),
                         "case \(name): \(contents.debugDescription)")
        }
    }

    func testQuotedAndUnquotedAssignmentsParse() throws {
        let assignments = [
            "ENGINE_SETS=\"GIMP_3_2_8:BABL_0_1_128:GEGL_0_4_72 master:master:master\"\n",
            "ENGINE_SETS='GIMP_3_2_8:BABL_0_1_128:GEGL_0_4_72 master:master:master'\n",
            "ENGINE_SETS=GIMP_3_2_8:BABL_0_1_128:GEGL_0_4_72\n",
            "  ENGINE_SETS =ignored\nENGINE_SETS=\"GIMP_3_2_8:B:C\" # pinned\n",
        ]
        for (index, assignment) in assignments.enumerated() {
            let root = try makeCheckout(name: "quoted-\(index)", engineEnv: assignment)
            try makeFile(".build/debug/Glims", in: root)
            XCTAssertEqual(discover(root.appendingPathComponent(".build/debug/Glims")),
                           adapterPath(in: root), "case \(index)")
        }
    }

    func testFirstEngineSetEntryChoosesTheAdapter() throws {
        // The ref comes from engine.env, not a hard-coded pin: a differently
        // named first set resolves to its own adapter directory.
        let custom = try makeCheckout(name: "custom",
                                      engineEnv: "ENGINE_SETS=\"CUSTOM_9:A:B GIMP_3_2_8:X:Y\"\n",
                                      adapterRefs: ["CUSTOM_9", "GIMP_3_2_8"])
        try makeFile(".build/debug/Glims", in: custom)
        XCTAssertEqual(discover(custom.appendingPathComponent(".build/debug/Glims")),
                       adapterPath("CUSTOM_9", in: custom))

        // master listed first means master, even when another adapter exists.
        let masterFirst = try makeCheckout(name: "master-first",
                                           engineEnv: "ENGINE_SETS=\"master:m:m GIMP_3_2_8:X:Y\"\n",
                                           adapterRefs: ["master", "GIMP_3_2_8"])
        try makeFile(".build/debug/Glims", in: masterFirst)
        XCTAssertEqual(discover(masterFirst.appendingPathComponent(".build/debug/Glims")),
                       adapterPath("master", in: masterFirst))
    }
}
