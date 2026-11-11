import Foundation

/// A small bounded JSON tree. Number spelling is retained so integer fields
/// cannot accept booleans, rounded large numbers, fractions or exponents.
indirect enum RecorderJSON {
    case object([String: RecorderJSON])
    case array([RecorderJSON])
    case string(String)
    case number(String, Double)
    case bool(Bool)
    case null
}

struct RecorderJSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private var values = 0

    init(_ data: Data) throws {
        guard data.count <= RecorderFileLimits.bytes else { throw RecorderFileError.invalid("The recording exceeds 16 MiB.") }
        guard String(data: data, encoding: .utf8) != nil else { throw RecorderFileError.invalid("The recording is not valid UTF-8.") }
        bytes = Array(data)
    }

    mutating func parse() throws -> RecorderJSON {
        let result = try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw error("Trailing data") }
        return result
    }

    private func error(_ reason: String) -> RecorderFileError { .invalid("\(reason) at JSON byte \(index).") }
    private var next: UInt8? { index < bytes.count ? bytes[index] : nil }
    private mutating func whitespace() {
        while let byte = next, [9, 10, 13, 32].contains(byte) { index += 1 }
    }
    private mutating func consume(_ byte: UInt8) -> Bool {
        guard next == byte else { return false }
        index += 1; return true
    }
    private mutating func require(_ byte: UInt8) throws {
        guard consume(byte) else { throw error("Unexpected JSON token") }
    }

    private mutating func value(depth: Int) throws -> RecorderJSON {
        guard depth <= RecorderFileLimits.depth else { throw error("JSON nesting exceeds 64") }
        values += 1
        guard values <= RecorderFileLimits.values else { throw error("Too many JSON values") }
        whitespace()
        guard let token = next else { throw error("Expected a JSON value") }
        switch token {
        case 123:
            index += 1; whitespace()
            var result: [String: RecorderJSON] = [:]
            if consume(125) { return .object(result) }
            while true {
                let key = try string()
                guard result.index(forKey: key) == nil else { throw error("Duplicate object key: \(key)") }
                whitespace(); try require(58)
                result[key] = try value(depth: depth + 1)
                whitespace()
                if consume(125) { return .object(result) }
                try require(44); whitespace()
            }
        case 91:
            index += 1; whitespace()
            var result: [RecorderJSON] = []
            if consume(93) { return .array(result) }
            while true {
                result.append(try value(depth: depth + 1))
                whitespace()
                if consume(93) { return .array(result) }
                try require(44)
            }
        case 34: return .string(try string())
        case 116: try literal([116, 114, 117, 101]); return .bool(true)
        case 102: try literal([102, 97, 108, 115, 101]); return .bool(false)
        case 110: try literal([110, 117, 108, 108]); return .null
        case 45, 48...57: return try number()
        default: throw error("Expected a JSON value")
        }
    }

    private mutating func literal(_ spelling: [UInt8]) throws {
        for byte in spelling { try require(byte) }
    }
    private func digit(_ byte: UInt8?) -> Bool { byte.map { (48...57).contains($0) } ?? false }
    private mutating func number() throws -> RecorderJSON {
        let start = index
        _ = consume(45)
        if consume(48) {
            guard !digit(next) else { throw error("Leading zero in number") }
        } else {
            guard let byte = next, (49...57).contains(byte) else { throw error("Invalid number") }
            while digit(next) { index += 1 }
        }
        if consume(46) {
            guard digit(next) else { throw error("Missing fractional digits") }
            while digit(next) { index += 1 }
        }
        if next == 101 || next == 69 {
            index += 1
            if next == 43 || next == 45 { index += 1 }
            guard digit(next) else { throw error("Missing exponent digits") }
            while digit(next) { index += 1 }
        }
        guard index - start <= RecorderFileLimits.numberBytes else { throw error("Number token exceeds 128 bytes") }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let number = Double(token), number.isFinite else { throw error("Number is not a finite Double") }
        let mantissa = token.utf8.prefix { $0 != 101 && $0 != 69 }
        guard number != 0 || !mantissa.contains(where: { (49...57).contains($0) }) else { throw error("Nonzero number underflows Double") }
        return .number(token, number)
    }

    private mutating func hex4() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = next else { throw error("Incomplete Unicode escape") }
            let digit: UInt32
            switch byte {
            case 48...57: digit = UInt32(byte - 48)
            case 65...70: digit = UInt32(byte - 65 + 10)
            case 97...102: digit = UInt32(byte - 97 + 10)
            default: throw error("Invalid Unicode escape")
            }
            result = result * 16 + digit; index += 1
        }
        return result
    }

    private mutating func string() throws -> String {
        try require(34)
        var output: [UInt8] = []
        while let byte = next {
            index += 1
            if byte == 34 { return String(decoding: output, as: UTF8.self) }
            guard byte >= 32 else { throw error("Unescaped string control character") }
            if byte == 92 {
                guard let escape = next else { throw error("Incomplete string escape") }
                index += 1
                switch escape {
                case 34, 47, 92: output.append(escape)
                case 98: output.append(8)
                case 102: output.append(12)
                case 110: output.append(10)
                case 114: output.append(13)
                case 116: output.append(9)
                case 117:
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        try require(92); try require(117)
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("Invalid Unicode surrogate pair") }
                        scalar = 0x10000 + (scalar - 0xD800) * 0x400 + low - 0xDC00
                    } else if (0xDC00...0xDFFF).contains(scalar) { throw error("Unpaired Unicode surrogate") }
                    guard let value = UnicodeScalar(scalar) else { throw error("Invalid Unicode scalar") }
                    output.append(contentsOf: String(value).utf8)
                default: throw error("Unknown string escape")
                }
            } else { output.append(byte) }
            guard output.count <= RecorderFileLimits.stringBytes else { throw error("String exceeds 64 KiB") }
        }
        throw error("Unterminated string")
    }
}

struct RecorderJSONWriter {
    private var bytes = Data()
    private var values = 0

    mutating func encode(_ node: RecorderJSON) throws -> Data {
        try write(node, depth: 0)
        return bytes
    }
    private mutating func append(_ data: [UInt8]) throws {
        guard data.count <= RecorderFileLimits.bytes - bytes.count else { throw RecorderFileError.invalid("The recording exceeds 16 MiB.") }
        bytes.append(contentsOf: data)
    }
    private mutating func string(_ value: String) throws {
        guard value.utf8.count <= RecorderFileLimits.stringBytes else { throw RecorderFileError.invalid("String exceeds 64 KiB.") }
        try append([34])
        let hex = Array("0123456789abcdef".utf8)
        for byte in value.utf8 {
            switch byte {
            case 34, 92: try append([92, byte])
            case 0...31: try append([92, 117, 48, 48, hex[Int(byte / 16)], hex[Int(byte % 16)]])
            default: try append([byte])
            }
        }
        try append([34])
    }
    private mutating func write(_ node: RecorderJSON, depth: Int) throws {
        values += 1
        guard depth <= RecorderFileLimits.depth, values <= RecorderFileLimits.values else { throw RecorderFileError.invalid("JSON resource limit exceeded.") }
        switch node {
        case .object(let members):
            try append([123])
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { try append([44]) }
                try string(key); try append([58]); try write(members[key]!, depth: depth + 1)
            }
            try append([125])
        case .array(let members):
            try append([91])
            for (index, member) in members.enumerated() {
                if index > 0 { try append([44]) }
                try write(member, depth: depth + 1)
            }
            try append([93])
        case .string(let value): try string(value)
        case .number(let token, let value):
            guard value.isFinite, token.utf8.count <= RecorderFileLimits.numberBytes else { throw RecorderFileError.invalid("Invalid number.") }
            try append(Array(token.utf8))
        case .bool(let value): try append(Array((value ? "true" : "false").utf8))
        case .null: try append(Array("null".utf8))
        }
    }
}
