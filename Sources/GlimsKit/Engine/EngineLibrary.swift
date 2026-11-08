import CGlimsEngine
import Foundation

/// Finds and loads the engine adapter library (`libglimsengine.dylib`, built
/// from `Engine/` by `scripts/build-adapter.sh`). The app runs without it;
/// the canvas then stays a placeholder.
enum EngineLibrary {
    static let environmentVariable = "GLIMS_ENGINE_LIBRARY"
    static let defaultsKey = "EngineLibraryPath"
    static let fileName = "libglimsengine.dylib"

    enum LoadError: Error, CustomStringConvertible {
        case cannotOpen(path: String, reason: String)
        case missingEntryPoint(path: String)
        case unsupportedVersion(path: String)

        var description: String {
            switch self {
            case .cannotOpen(let path, let reason):
                return "The engine library at \(path) could not be loaded: \(reason)"
            case .missingEntryPoint(let path):
                return "\(path) is not a Glims engine library."
            case .unsupportedVersion(let path):
                return "\(path) does not provide engine facade version \(GLIMS_ENGINE_API_VERSION)."
            }
        }
    }

    /// Where to look, in order: the environment, the user default
    /// (`-EngineLibraryPath` on the command line also sets it), the
    /// app bundle's Frameworks directory, and the pinned adapter of the
    /// source checkout the executable was built in, when there is one.
    static func configuredPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                               defaults: UserDefaults = .standard,
                               bundle: Bundle = .main,
                               executable: URL? = nil) -> String? {
        if let path = environment[environmentVariable], !path.isEmpty { return path }
        if let path = defaults.string(forKey: defaultsKey), !path.isEmpty { return path }
        if let bundled = bundle.privateFrameworksURL?.appendingPathComponent(fileName),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        return sourceBuildPath(executable: executable ?? bundle.executableURL)
    }

    /// `swift run` and `.build/<config>/Glims` have no bundle to carry the
    /// engine, so they fall back to the adapter the checkout already built:
    /// `<checkout>/_engine/adapter/<ref>/`, with `<ref>` the first `ENGINE_SETS`
    /// entry of `scripts/engine.env` — the same pin `scripts/build-app.sh`
    /// bundles. Only an executable under a `.build` directory of a checkout
    /// holding `Package.swift` and `scripts/engine.env` qualifies, and
    /// anything inside an app bundle's `Contents` (a normal or `--shell-only`
    /// build) never does; there is no search outside that one project.
    private static func sourceBuildPath(executable: URL?) -> String? {
        guard let executable else { return nil }
        let resolved = executable.resolvingSymlinksInPath()
        let components = resolved.pathComponents
        let insideBundle = components.indices.contains { index in
            components[index].hasSuffix(".app")
                && index + 1 < components.count
                && components[index + 1] == "Contents"
        }
        guard !insideBundle else { return nil }

        // Walk ancestors until the filesystem root. pathComponents.count
        // strictly decreases, so the loop is bounded; deletingLastPathComponent
        // on the root itself can keep producing ".." instead of terminating.
        var directory = resolved.deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            if directory.lastPathComponent == ".build" {
                return sourceCheckoutAdapter(root: directory.deletingLastPathComponent())
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// The pinned adapter inside the checkout at `root`, or nil when the
    /// checkout layout or the adapter itself is missing.
    private static func sourceCheckoutAdapter(root: URL) -> String? {
        let manager = FileManager.default
        let engineEnv = root.appendingPathComponent("scripts/engine.env")
        guard manager.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
              manager.fileExists(atPath: engineEnv.path),
              let ref = pinnedEngineRef(in: engineEnv) else { return nil }
        let adapter = root.appendingPathComponent("_engine/adapter/\(ref)/\(fileName)")
        return manager.fileExists(atPath: adapter.path) ? adapter.path : nil
    }

    /// The GIMP ref of the first `ENGINE_SETS` entry in `scripts/engine.env`,
    /// parsed as data — the file is never sourced and nothing is expanded.
    /// Like a shell sourcing the file, the last assignment wins; a single or
    /// double quoted value is accepted, anything else malformed returns nil.
    private static func pinnedEngineRef(in engineEnv: URL) -> String? {
        guard let text = try? String(contentsOf: engineEnv, encoding: .utf8) else { return nil }
        var raw: String?
        for line in text.components(separatedBy: .newlines) {
            let assignment = line.trimmingCharacters(in: .whitespaces)
            if assignment.hasPrefix("ENGINE_SETS=") {
                raw = String(assignment.dropFirst("ENGINE_SETS=".count))
            }
        }
        guard var value = raw?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let quote = value.first, quote == "\"" || quote == "'" {
            guard let close = value.dropFirst().firstIndex(of: quote) else { return nil }
            value = String(value[value.index(after: value.startIndex)..<close])
        }
        guard let firstSet = value.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let ref = String(firstSet.prefix(while: { $0 != ":" }))
        return isSafeEngineRef(ref) ? ref : nil
    }

    /// The shape `require_engine_ref` in scripts/engine-common.sh accepts:
    /// one plain directory name — the stable `GIMP_*` pins, `master`, or
    /// another listed set — never `.`/`..`, separators or expansions.
    private static func isSafeEngineRef(_ ref: String) -> Bool {
        guard !ref.isEmpty, ref != ".", ref != ".." else { return false }
        return ref.unicodeScalars.allSatisfy { engineRefCharacters.contains($0) }
    }

    private static let engineRefCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")

    static func load(path: String) throws -> UnsafePointer<GlimsEngineAPI> {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw LoadError.cannotOpen(path: path, reason: dlerror().map { String(cString: $0) } ?? "unknown error")
        }
        guard let symbol = dlsym(handle, "glims_engine_get_api") else {
            throw LoadError.missingEntryPoint(path: path)
        }
        let getAPI = unsafeBitCast(symbol, to: GlimsEngineGetAPIFunction.self)
        guard let api = getAPI(GLIMS_ENGINE_API_VERSION),
              api.pointee.api_version == GLIMS_ENGINE_API_VERSION,
              Int(api.pointee.struct_size) >= MemoryLayout<GlimsEngineAPI>.size else {
            throw LoadError.unsupportedVersion(path: path)
        }
        return api
    }
}
