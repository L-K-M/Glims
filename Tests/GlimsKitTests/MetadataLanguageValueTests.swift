import XCTest
import Darwin
import CGlimsEngine
@testable import GlimsKit

/// Pure contract tests for `EngineSession.decodeMetadataLanguages`:
/// the facade array is `count` (language, text) pairs plus one all-NULL
/// sentinel, every pair a non-NULL valid-UTF-8 non-empty language and
/// text with case-fold-unique languages, and any violation throws
/// FAILED — never truncated. The decoder copies into Swift Strings, so
/// a decoded array stays valid after the C buffers are freed. No engine
/// is started.
final class MetadataLanguageValueTests: XCTestCase {

    /// One C-string field of a facade pair.
    private enum Field {
        case text(String)     // valid UTF-8, NUL-terminated
        case invalidUTF8     // NUL-terminated bytes that are not UTF-8
        case null            // NULL pointer
    }

    /// Owns every C string handed to the decoder and frees them all in
    /// `release`, so a failed assertion cannot leak buffers.
    private final class CBufferPool {
        private var buffers: [UnsafeMutablePointer<CChar>] = []

        func field(_ field: Field) -> UnsafeMutablePointer<CChar>? {
            switch field {
            case .null:
                return nil
            case .text(let string):
                guard let copy = strdup(string) else { return nil }
                buffers.append(copy)
                return copy
            case .invalidUTF8:
                // 0xFF can never appear in valid UTF-8.
                guard let allocation = malloc(2) else { return nil }
                let buffer = allocation.assumingMemoryBound(to: CChar.self)
                buffer[0] = -1
                buffer[1] = 0
                buffers.append(buffer)
                return buffer
            }
        }

        func release() {
            for buffer in buffers { free(buffer) }
            buffers.removeAll(keepingCapacity: false)
        }

        deinit { release() }
    }

    /// Decodes `pairs` plus `sentinel` (default all-NULL) through the
    /// facade decoder with `count` entries. Every C buffer is freed
    /// before this returns — even on a throw — so a returned array
    /// proves the decoder copied into Swift-owned strings.
    private func decodeForTest(pairs: [(Field, Field)],
                               sentinel: (Field, Field) = (.null, .null),
                               count: Int32? = nil) throws -> [EngineSession.MetadataLanguageValue] {
        let pool = CBufferPool()
        defer { pool.release() }
        var values = pairs.map {
            GlimsMetadataLanguageValue(language: pool.field($0.0), text: pool.field($0.1))
        }
        values.append(GlimsMetadataLanguageValue(language: pool.field(sentinel.0),
                                                 text: pool.field(sentinel.1)))
        return try values.withUnsafeMutableBufferPointer { buffer in
            try EngineSession.decodeMetadataLanguages(buffer.baseAddress,
                                                      count: count ?? Int32(pairs.count))
        }
    }

    /// Asserts `body` throws EngineSession.EngineError with status
    /// GLIMS_STATUS_FAILED.
    private func assertFailed(_ body: () throws -> [EngineSession.MetadataLanguageValue],
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let engineError = error as? EngineSession.EngineError else {
                return XCTFail("expected EngineSession.EngineError, got \(error)",
                               file: file, line: line)
            }
            XCTAssertEqual(engineError.status, Int32(GLIMS_STATUS_FAILED.rawValue),
                           "expected GLIMS_STATUS_FAILED for \(error)", file: file, line: line)
        }
    }

    private func assertPairFails(pairs: [(Field, Field)],
                                 sentinel: (Field, Field) = (.null, .null),
                                 count: Int32? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
        assertFailed({ try decodeForTest(pairs: pairs, sentinel: sentinel, count: count) },
                     file: file, line: line)
    }

    func testDecodesPairsInOrderIntoSwiftOwnedStrings() throws {
        // Quotes, commas and leading spaces survive byte-exact and the
        // language spelling keeps its case. The buffers are freed before
        // decodeForTest returns, so equality here proves the result does
        // not reference them.
        let decoded = try decodeForTest(pairs: [
            (.text("en"), .text(#"Title "quoted", with, commas"#)),
            (.text("Fr-CA"), .text("  espaces  conservés  ")),
            (.text("x-default"), .text("Unicode 山 🌲 naïve")),
        ])
        XCTAssertEqual(decoded, [
            EngineSession.MetadataLanguageValue(language: "en",
                                                text: #"Title "quoted", with, commas"#),
            EngineSession.MetadataLanguageValue(language: "Fr-CA",
                                                text: "  espaces  conservés  "),
            EngineSession.MetadataLanguageValue(language: "x-default",
                                                text: "Unicode 山 🌲 naïve"),
        ])
    }

    func testDecodesSinglePair() throws {
        XCTAssertEqual(try decodeForTest(pairs: [(.text("de"), .text("Einzel"))]),
                       [EngineSession.MetadataLanguageValue(language: "de", text: "Einzel")])
    }

    func testDecodesMaximum256Pairs() throws {
        let pairs = (0..<256).map { index in
            (Field.text("lang-\(index)"), Field.text("text \(index)"))
        }
        let expected = (0..<256).map {
            EngineSession.MetadataLanguageValue(language: "lang-\($0)", text: "text \($0)")
        }
        XCTAssertEqual(try decodeForTest(pairs: pairs), expected)
    }

    func testRejectsCountsOutsideContract() {
        // NULL pointer fails at any count.
        assertFailed { try EngineSession.decodeMetadataLanguages(nil, count: 1) }
        assertFailed { try EngineSession.decodeMetadataLanguages(nil, count: 0) }
        // Address1 is inaccessible on macOS. Every out-of-range count
        // must refuse before reading even the first pair.
        let inaccessible = UnsafeMutablePointer<GlimsMetadataLanguageValue>(bitPattern: 1)!
        for count: Int32 in [0, -1, 257, .min, .max] {
            assertFailed { try EngineSession.decodeMetadataLanguages(inaccessible, count: count) }
        }
    }

    func testRejectsNullEmptyAndNonUTF8Fields() {
        assertPairFails(pairs: [(.null, .text("text"))])
        assertPairFails(pairs: [(.text("en"), .null)])
        assertPairFails(pairs: [(.text(""), .text("text"))])
        assertPairFails(pairs: [(.text("en"), .text(""))])
        assertPairFails(pairs: [(.invalidUTF8, .text("text"))])
        assertPairFails(pairs: [(.text("en"), .invalidUTF8)])
    }

    func testRejectsCaseFoldDuplicateLanguages() {
        assertPairFails(pairs: [(.text("en"), .text("first")),
                                (.text("EN"), .text("second"))])
        assertPairFails(pairs: [(.text("en-US"), .text("first")),
                                (.text("EN-us"), .text("second"))])
    }

    func testRejectsNonNullSentinel() {
        let pair: (Field, Field) = (.text("en"), .text("text"))
        assertPairFails(pairs: [pair], sentinel: (.text("en"), .null))
        assertPairFails(pairs: [pair], sentinel: (.null, .text("text")))
        assertPairFails(pairs: [pair], sentinel: (.text("en"), .text("text")))
    }
}
