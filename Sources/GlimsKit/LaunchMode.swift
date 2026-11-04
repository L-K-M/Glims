/// How the app was asked to run.
///
/// `--smoke-test` builds the workspace window, checks it and exits; CI runs it
/// against the assembled bundle to prove the app launches. Single-dash
/// arguments are AppKit's (`-NSDocumentRevisionsDebugMode YES`, `-psn_…`) and
/// are left to it.
public enum LaunchMode: Equatable {
    case interactive
    case smokeTest
    case printVersion

    public struct UnknownOption: Error, Equatable {
        public let option: String
    }

    /// Parses the arguments after the executable path.
    public init(arguments: [String]) throws {
        var mode = LaunchMode.interactive
        for argument in arguments where argument.hasPrefix("--") {
            switch argument {
            case "--smoke-test": mode = .smokeTest
            case "--version": mode = .printVersion
            default: throw UnknownOption(option: argument)
            }
        }
        self = mode
    }
}
