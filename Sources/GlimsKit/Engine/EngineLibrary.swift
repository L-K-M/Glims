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
    /// (`-EngineLibraryPath` on the command line also sets it), and the
    /// app bundle's Frameworks directory.
    static func configuredPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                               defaults: UserDefaults = .standard,
                               bundle: Bundle = .main) -> String? {
        if let path = environment[environmentVariable], !path.isEmpty { return path }
        if let path = defaults.string(forKey: defaultsKey), !path.isEmpty { return path }
        if let bundled = bundle.privateFrameworksURL?.appendingPathComponent(fileName),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        return nil
    }

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
