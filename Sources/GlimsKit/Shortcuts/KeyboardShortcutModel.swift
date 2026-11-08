import Foundation

// MARK: - Modifiers

/// The modifier keys of a keyboard shortcut, as Glims's own option set.
///
/// Deliberately NOT `NSEvent.ModifierFlags`: that raw value is an AppKit
/// detail with device-dependent bits and is never serialized here. Only the
/// four classic Mac modifiers exist, and stored values carrying bits outside
/// `knownMask` are rejected, never reinterpreted.
struct ShortcutModifiers: OptionSet, Codable, Hashable, CustomStringConvertible {
    let rawValue: Int

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let shift = ShortcutModifiers(rawValue: 1 << 1)
    static let option = ShortcutModifiers(rawValue: 1 << 2)
    static let control = ShortcutModifiers(rawValue: 1 << 3)

    /// Every bit this model knows.
    static let knownMask: Int = command.rawValue | shift.rawValue | option.rawValue | control.rawValue

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// True when the value holds only known, non-negative modifier bits.
    var usesOnlyKnownBits: Bool {
        rawValue >= 0 && (rawValue & ~ShortcutModifiers.knownMask) == 0
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        guard raw >= 0, (raw & ~ShortcutModifiers.knownMask) == 0 else {
            throw KeyboardShortcutError.unknownModifierBits(raw)
        }
        self.init(rawValue: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String {
        var parts: [String] = []
        if contains(.command) { parts.append("cmd") }
        if contains(.shift) { parts.append("shift") }
        if contains(.option) { parts.append("option") }
        if contains(.control) { parts.append("ctrl") }
        return parts.joined(separator: "+")
    }
}

// MARK: - Key

/// One key of a shortcut, stored as Glims's own string.
///
/// Two accepted forms:
///
/// - a single printable grapheme cluster, punctuation and symbols included;
///   letters are normalized to lower case ("A" and "a" are the same key, the
///   Shift modifier distinguishes them). Control characters (NUL, tab,
///   newline, DEL, ...), format characters, surrogates, private-use and
///   unassigned scalars, and multi-grapheme strings are rejected.
/// - an AppKit function-key unicode scalar (0xF700...0xF8FF), mapped to an
///   own tag string ("f5", "upArrow", ...), so no AppKit constant crosses
///   into storage.
struct ShortcutKey: Hashable, Codable, CustomStringConvertible {
    /// Glims's own stored string: the normalized grapheme, or a function tag.
    let value: String

    /// The AppKit function-key unicodes mapped to Glims's own tag strings.
    static let functionKeyTags: [UInt32: String] = {
        var tags: [UInt32: String] = [
            0xF700: "upArrow", 0xF701: "downArrow", 0xF702: "leftArrow", 0xF703: "rightArrow",
            0xF727: "insert", 0xF728: "delete", 0xF729: "home", 0xF72B: "end",
            0xF72C: "pageUp", 0xF72D: "pageDown", 0xF72E: "printScreen",
            0xF72F: "scrollLock", 0xF730: "pause", 0xF731: "sysReq", 0xF732: "break",
            0xF733: "reset", 0xF734: "print", 0xF746: "help",
        ]
        // NSF1FunctionKey (0xF704) ... NSF35FunctionKey (0xF726).
        for index in 0..<35 {
            tags[UInt32(0xF704 + index)] = "f\(index + 1)"
        }
        return tags
    }()

    /// The whole AppKit function-key unicode range.
    static let functionKeyRange: ClosedRange<UInt32> = 0xF700...0xF8FF

    /// Every stored function tag, for decoding the persisted form.
    static let knownTags: Set<String> = Set(functionKeyTags.values)

    /// A key from keyboard input: exactly one grapheme cluster. A function
    /// key arrives as its unicode scalar and is mapped to the own tag.
    init?(input: String) {
        guard input.count == 1 else { return nil }
        let character = input.first!
        if character.unicodeScalars.count == 1 {
            let scalar = character.unicodeScalars.first!
            if ShortcutKey.functionKeyRange.contains(scalar.value) {
                guard let tag = ShortcutKey.functionKeyTags[scalar.value] else { return nil }
                self.value = tag
                return
            }
        }
        guard ShortcutKey.isPrintable(character) else { return nil }
        // Letters normalize to lower case; the normalized form must itself be
        // a single printable grapheme.
        let normalized = String(character).lowercased()
        guard normalized.count == 1, ShortcutKey.isPrintable(normalized.first!) else { return nil }
        self.value = normalized
    }

    /// The persisted form: a single printable grapheme or a known function
    /// tag. Anything else (multi-character, control, unknown tag) is invalid.
    init?(persisted: String) {
        if ShortcutKey.knownTags.contains(persisted) {
            self.value = persisted
        } else if let key = ShortcutKey(input: persisted) {
            self.value = key.value
        } else {
            return nil
        }
    }

    /// Printable grapheme check: every scalar must be a letter, mark, number,
    /// punctuation, symbol or space — never control, format, surrogate,
    /// private-use, unassigned or line/paragraph separator.
    private static func isPrintable(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned,
                 .lineSeparator, .paragraphSeparator:
                return false
            default:
                break
            }
        }
        return true
    }

    var description: String { value }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let key = ShortcutKey(persisted: raw) else {
            throw KeyboardShortcutError.invalidKey(raw)
        }
        self = key
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

// MARK: - Shortcut

/// A key plus modifiers. Plain values; the rules that only overrides must
/// follow (Command or Control required, macOS reservations) are checked by
/// `KeyboardShortcutCatalog` when an override is applied.
struct KeyboardShortcut: Hashable, Codable, CustomStringConvertible {
    let key: ShortcutKey
    let modifiers: ShortcutModifiers

    init(key: ShortcutKey, modifiers: ShortcutModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Builds a shortcut from raw key input; nil when the key is invalid.
    init?(keyInput: String, modifiers: ShortcutModifiers) {
        guard let key = ShortcutKey(input: keyInput) else { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    /// Overrides must carry Command or Control, so they can never steal the
    /// canvas, text-editing or single-tool keys, which are plain keys.
    var hasCommandOrControl: Bool {
        modifiers.contains(.command) || modifiers.contains(.control)
    }

    var description: String {
        modifiers.isEmpty ? key.value : "\(modifiers)+\(key.value)"
    }

    /// The macOS-reserved combinations (docs/keyboard-shortcuts.md lists each
    /// one with its system meaning). A command whose factory base is one of
    /// these keeps it — the owner — but no other command can claim it.
    static let reserved: Set<KeyboardShortcut> = Set([
        KeyboardShortcut(keyInput: "h", modifiers: [.command]),            // Hide
        KeyboardShortcut(keyInput: "h", modifiers: [.command, .option]),   // Hide Others
        KeyboardShortcut(keyInput: "m", modifiers: [.command]),            // Minimize
        KeyboardShortcut(keyInput: "m", modifiers: [.command, .option]),   // Minimize All
        KeyboardShortcut(keyInput: "q", modifiers: [.command]),            // Quit
        KeyboardShortcut(keyInput: "q", modifiers: [.command, .shift]),    // Log Out
        KeyboardShortcut(keyInput: "q", modifiers: [.command, .control]),  // Lock Screen
        KeyboardShortcut(keyInput: " ", modifiers: [.command]),            // Spotlight
        KeyboardShortcut(keyInput: " ", modifiers: [.command, .option]),   // Spotlight search field
        KeyboardShortcut(keyInput: "`", modifiers: [.command]),            // Move focus to next window
        KeyboardShortcut(keyInput: "`", modifiers: [.command, .shift]),    // Move focus to previous window
        KeyboardShortcut(keyInput: "3", modifiers: [.command, .shift]),    // Screenshot
        KeyboardShortcut(keyInput: "4", modifiers: [.command, .shift]),    // Screenshot selection
        KeyboardShortcut(keyInput: "5", modifiers: [.command, .shift]),    // Screenshot options
    ].compactMap { $0 })

    enum CodingKeys: String, CodingKey { case key, modifiers }

    init(from decoder: Decoder) throws {
        try rejectUnknownShortcutKeys(decoder, allowed: ["key", "modifiers"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try container.decode(ShortcutKey.self, forKey: .key),
                  modifiers: try container.decode(ShortcutModifiers.self, forKey: .modifiers))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(modifiers, forKey: .modifiers)
    }
}

// MARK: - Override and catalog

/// The user's per-command choice: assign a specific shortcut, or explicitly
/// disable the command's shortcut. `reset` (removing the override) is a store
/// operation, not a stored value.
enum CommandShortcutOverride: Hashable {
    case assign(KeyboardShortcut)
    case disable
}

/// One command of the caller-supplied catalog. `id` is a stable identifier
/// supplied by the caller — a nonempty, unique string, never a localized
/// title. `base` is the optional factory shortcut.
struct CommandShortcutEntry: Hashable {
    let id: String
    let base: KeyboardShortcut?

    init(id: String, base: KeyboardShortcut? = nil) throws {
        guard !id.isEmpty else { throw KeyboardShortcutError.emptyCommandID }
        guard !id.contains(where: { $0.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) }) else {
            throw KeyboardShortcutError.invalidCommandID(id)
        }
        if let base, !base.modifiers.usesOnlyKnownBits {
            throw KeyboardShortcutError.unknownModifierBits(base.modifiers.rawValue)
        }
        self.id = id
        self.base = base
    }
}

/// The caller-supplied catalog of commands that can have shortcuts. The
/// catalog is the single source of command identity; titles shown in menus
/// are a UI concern and never enter this model.
struct KeyboardShortcutCatalog: Hashable {
    let entries: [CommandShortcutEntry]
    let byID: [String: CommandShortcutEntry]

    init(entries: [CommandShortcutEntry]) throws {
        var byID: [String: CommandShortcutEntry] = [:]
        var baseOwners: [KeyboardShortcut: String] = [:]
        for entry in entries {
            guard byID[entry.id] == nil else {
                throw KeyboardShortcutError.duplicateCommandID(entry.id)
            }
            byID[entry.id] = entry
            if let base = entry.base {
                if let other = baseOwners[base] {
                    throw KeyboardShortcutError.duplicateBaseShortcut(base, first: other, second: entry.id)
                }
                baseOwners[base] = entry.id
            }
        }
        self.entries = entries
        self.byID = byID
    }

    /// Convenience for literal construction.
    init(_ entries: [(id: String, base: KeyboardShortcut?)]) throws {
        try self.init(entries: entries.map { try CommandShortcutEntry(id: $0.id, base: $0.base) })
    }

    /// The effective shortcuts after applying `overrides`: an override wins
    /// over the base, an explicit disable removes the command's shortcut, and
    /// a command without either keeps its base. Disabled commands are absent
    /// from the result.
    ///
    /// Override ids the catalog does not know (orphans left by an older or
    /// newer catalog) are inactive here: the store retains them untouched,
    /// and they are ignored until the command is known again — then the
    /// stored override is revalidated like any other, BEFORE it is applied.
    ///
    /// Every known override must carry Command or Control and must not be a
    /// macOS reservation (unless it is that command's own base); a shortcut
    /// already used by another command in the effective catalog is a
    /// conflict. Conflicts name both commands and never silently unbind the
    /// other command.
    func effectiveShortcuts(overrides: [String: CommandShortcutOverride]) throws -> EffectiveShortcuts {
        var byCommand: [String: KeyboardShortcut] = [:]
        var byShortcut: [KeyboardShortcut: String] = [:]
        for entry in entries {
            let shortcut: KeyboardShortcut?
            switch overrides[entry.id] {
            case .none:
                shortcut = entry.base
            case .some(.disable):
                shortcut = nil
            case .some(.assign(let assigned)):
                try Self.validateOverride(assigned, for: entry)
                shortcut = assigned
            }
            if let shortcut {
                if let other = byShortcut[shortcut] {
                    throw KeyboardShortcutError.conflict(shortcut: shortcut, command: entry.id, other: other)
                }
                byShortcut[shortcut] = entry.id
                byCommand[entry.id] = shortcut
            }
        }
        return EffectiveShortcuts(byCommand: byCommand, byShortcut: byShortcut)
    }

    /// The override rules that depend on the command: Command or Control is
    /// required, and a macOS reservation can only be claimed by the command
    /// that owns it as its factory base.
    private static func validateOverride(_ shortcut: KeyboardShortcut, for entry: CommandShortcutEntry) throws {
        guard shortcut.modifiers.usesOnlyKnownBits else {
            throw KeyboardShortcutError.unknownModifierBits(shortcut.modifiers.rawValue)
        }
        guard shortcut.hasCommandOrControl else {
            throw KeyboardShortcutError.missingCommandOrControl(shortcut, command: entry.id)
        }
        if KeyboardShortcut.reserved.contains(shortcut), shortcut != entry.base {
            throw KeyboardShortcutError.reserved(shortcut, command: entry.id)
        }
    }
}

/// The resolved shortcut map: command id to shortcut and back, disabled
/// commands removed.
struct EffectiveShortcuts: Hashable {
    let byCommand: [String: KeyboardShortcut]
    let byShortcut: [KeyboardShortcut: String]

    func shortcut(forCommand id: String) -> KeyboardShortcut? { byCommand[id] }
    func command(forShortcut shortcut: KeyboardShortcut) -> String? { byShortcut[shortcut] }
}

// MARK: - Codable (override)

extension CommandShortcutOverride: Codable {
    private enum Kind: String { case assign, disable }
    private enum CodingKeys: String, CodingKey { case kind, shortcut }

    init(from decoder: Decoder) throws {
        try rejectUnknownShortcutKeys(decoder, allowed: ["kind", "shortcut"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindTag = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: kindTag) else {
            throw KeyboardShortcutError.malformed("unknown override kind \"\(kindTag)\"")
        }
        switch kind {
        case .assign:
            let shortcut = try container.decode(KeyboardShortcut.self, forKey: .shortcut)
            guard shortcut.hasCommandOrControl else {
                throw KeyboardShortcutError.missingCommandOrControl(shortcut, command: nil)
            }
            self = .assign(shortcut)
        case .disable:
            guard !container.contains(.shortcut) else {
                throw KeyboardShortcutError.malformed("a disable override carries no shortcut")
            }
            self = .disable
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .assign(let shortcut):
            try container.encode(Kind.assign.rawValue, forKey: .kind)
            try container.encode(shortcut, forKey: .shortcut)
        case .disable:
            try container.encode(Kind.disable.rawValue, forKey: .kind)
        }
    }
}

// MARK: - Strict decoding helpers

/// A coding key that accepts any string, used to read the keys a schema
/// version does not know.
struct ShortcutCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

/// Rejects extension fields at every object boundary before decoding values:
/// unknown data stays in the original stored bytes until a compatible version
/// reads it.
func rejectUnknownShortcutKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: ShortcutCodingKey.self)
    let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
    guard unknown.isEmpty else {
        let path = decoder.codingPath.map(\.stringValue).joined(separator: ".")
        throw KeyboardShortcutError.malformed("unsupported fields in \(path.isEmpty ? "document" : path): \(unknown.joined(separator: ", ")). Use a compatible Glims version")
    }
}

// MARK: - Errors

/// Every way a shortcut, override, catalog or stored document can be invalid.
enum KeyboardShortcutError: Error, LocalizedError, Equatable, CustomStringConvertible {
    /// A command id that is empty.
    case emptyCommandID
    /// A command id with control characters (or NUL).
    case invalidCommandID(String)
    /// The same command id twice in one catalog.
    case duplicateCommandID(String)
    /// Two catalog commands share one factory base shortcut.
    case duplicateBaseShortcut(KeyboardShortcut, first: String, second: String)
    /// A key that is not a single printable grapheme or a known function key
    /// (empty, multi-character, NUL/control, unprintable, unknown function).
    case invalidKey(String)
    /// Stored modifier bits outside `ShortcutModifiers.knownMask`.
    case unknownModifierBits(Int)
    /// An override without Command or Control, which would steal canvas,
    /// text or single-tool keys.
    case missingCommandOrControl(KeyboardShortcut, command: String?)
    /// A macOS reservation claimed by a command that does not own it as its
    /// factory base.
    case reserved(KeyboardShortcut, command: String)
    /// The shortcut is already the effective shortcut of another command.
    case conflict(shortcut: KeyboardShortcut, command: String, other: String)
    /// A mutation named a command the catalog does not contain.
    case unknownCommand(String)
    /// The same command id twice in the stored overrides array.
    case duplicateStoredOverride(String)
    /// The stored document's schema version is not the supported one.
    case unsupportedSchemaVersion(found: Int, supported: Int)
    /// The stored document has no schema version.
    case missingSchemaVersion
    /// The stored bytes are not a readable document of this schema.
    case malformed(String)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .emptyCommandID:
            return "A command identifier must not be empty."
        case .invalidCommandID(let id):
            return "The command identifier \"\(id)\" contains a control character."
        case .duplicateCommandID(let id):
            return "The command identifier \"\(id)\" appears twice in the catalog."
        case .duplicateBaseShortcut(let shortcut, let first, let second):
            return "The commands \"\(first)\" and \"\(second)\" share the factory shortcut \(shortcut)."
        case .invalidKey(let raw):
            return "\"\(raw)\" is not a shortcut key: a key is a single printable character or a function key."
        case .unknownModifierBits(let raw):
            return "The modifier value \(raw) has bits outside the known Command/Shift/Option/Control set."
        case .missingCommandOrControl(let shortcut, let command):
            return "The shortcut \(shortcut) needs the Command or Control key"
                + (command.map { " — \"\($0)\" would otherwise steal a canvas, text or single-tool key." } ?? ".")
        case .reserved(let shortcut, let command):
            return "The shortcut \(shortcut) is reserved by macOS; \"\(command)\" cannot claim it."
        case .conflict(let shortcut, let command, let other):
            return "The shortcut \(shortcut) is already used by the command \"\(other)\"; \"\(command)\" cannot take it."
        case .unknownCommand(let id):
            return "The catalog has no command \"\(id)\"."
        case .duplicateStoredOverride(let id):
            return "The stored overrides contain the command \"\(id)\" twice."
        case .unsupportedSchemaVersion(let found, let supported):
            return "The stored shortcut overrides use schema version \(found); this version reads only \(supported). The stored data was left untouched."
        case .missingSchemaVersion:
            return "The stored shortcut overrides have no schema version. The stored data was left untouched."
        case .malformed(let detail):
            return "The stored shortcut overrides could not be read: \(detail). The stored data was left untouched."
        }
    }
}
