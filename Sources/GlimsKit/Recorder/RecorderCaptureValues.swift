import Foundation

/// The exact sRGB components passed to a native command, never an NSColor.
struct RecorderColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    enum InvalidColor: Error { case components }

    init(red: Double, green: Double, blue: Double, alpha: Double) throws {
        guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw InvalidColor.components
        }
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

/// Immutable identification hints captured before an item's first recorded edit.
/// Symbols belong to the recording; neither these values nor their ancestors
/// contain native IDs. They do not establish identity when reopening an image.
struct RecorderTargetDescription: Equatable {
    enum Kind: Equatable { case pixel, group, text, link, vector, channel, quickMask }
    struct Bounds: Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
    struct Ancestor: Equatable {
        let name: String
        let kind: Kind
        let siblingIndex: Int
    }

    let name: String
    let kind: Kind
    let ancestors: [Ancestor]
    let siblingIndex: Int
    let bounds: Bounds
}

enum RecorderDescriptionObservation: Equatable {
    case available(RecorderTargetDescription)
    case unavailable(String)
}

/// First observations remain useful after rename/deletion. Epoch admission is
/// checked by the document before observations enter this catalog.
struct RecorderDescriptionCatalog: Equatable {
    private(set) var values: [UUID: RecorderDescriptionObservation] = [:]

    mutating func acceptFirst(_ observations: [UUID: RecorderDescriptionObservation]) {
        for (symbol, observation) in observations where values[symbol] == nil {
            values[symbol] = observation
        }
    }
}

/// Persisted ink identity belongs to one document. It never authorizes an
/// automatic binding to another document, even when the UUID matches.
struct RecorderInkIdentity: Equatable {
    enum Mode: String { case cmyk, multichannel }
    enum Role: String { case unspecified, cyan, magenta, yellow, black }

    let mode: Mode
    let role: Role
    let uuid: UUID

    var isValid: Bool {
        guard uuid != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else { return false }
        switch mode {
        case .cmyk: return role != .unspecified
        case .multichannel: return role == .unspecified
        }
    }
}

enum RecorderBindingDescription: Equatable {
    enum Target: Equatable {
        case layer(UUID)
        case mask(owner: UUID)
        case channel(UUID)
        case quickMask(UUID)
    }
    struct Mask: Equatable {
        let owner: UUID
        let isPresent: Bool
        let enabled: Bool
        let editing: Bool
        let showing: Bool
    }
    struct QuickMask: Equatable {
        let enabled: Bool
        let symbol: UUID?
        let inverted: Bool
        let color: RecorderColor
    }
    struct Context: Equatable {
        let layers: [UUID]
        let channels: [UUID]
        let target: Target
        let masks: [Mask]
        let quickMask: QuickMask
    }

    case none
    case layer(UUID)
    /// An explicit source channel, for example Channel ▸ To Selection. The
    /// symbol is a channel-kind description, never the active paint target.
    case channel(UUID)
    /// Only native ink commands accept this binding. The symbol remains a
    /// channel-kind description; the identity contains no runtime channel ID.
    case ink(symbol: UUID, identity: RecorderInkIdentity)
    case context(Context)
    case unavailable(String)
}
