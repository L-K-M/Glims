/// A validated camera capture date: a proleptic Gregorian civil date with
/// second resolution. The accepted subset of the EXIF-style capture-date
/// text form is fully specified and nothing else is accepted:
///
/// - Components: year 1...9999, month 1...12, day 1...the month's real
///   last day (leap year: divisible by 4, except centuries unless
///   divisible by 400), hour 0...23, minute 0...59, second 0...59.
/// - Text: exactly 19 ASCII bytes "YYYY:MM:DD HH:MM:SS" — zero-padded
///   unsigned decimal components, ':' at byte positions 4, 7, 13, 16,
///   one ' ' at byte position 10, every other byte an ASCII digit.
///
/// Outside the subset there is no trimming or normalization, no signs,
/// NUL, Unicode or non-ASCII digits or separators, no partial or
/// unknown-zero dates, no time zones and no fractional seconds.
/// Malformed values that already exist in metadata remain untouched:
/// the caller (the UI layer) never rewrites them, and this type has no
/// interface of its own.
///
/// Every field is `let` and both initializers validate before storing,
/// so any existing value is canonical and `metadataText` round trips it
/// byte for byte.
struct MetadataCaptureDate: Equatable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int

    init?(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        // Early range returns before any arithmetic, so extreme inputs
        // such as Int.min/Int.max are rejected without a trap.
        guard (1...9999).contains(year) else { return nil }
        guard (1...12).contains(month) else { return nil }
        let lastDay = Self.lastDay(ofMonth: month, year: year)
        guard (1...lastDay).contains(day) else { return nil }
        guard (0...23).contains(hour) else { return nil }
        guard (0...59).contains(minute) else { return nil }
        guard (0...59).contains(second) else { return nil }

        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    /// Parses the canonical 19-byte ASCII text form only. The length
    /// guard runs before any byte array is allocated, so a huge string
    /// costs one count, not one copy; after the guard the copy is at
    /// most 19 bytes.
    init?(metadataText: String) {
        guard metadataText.utf8.count == 19 else { return nil }
        let bytes = Array(metadataText.utf8)
        guard bytes[4] == 0x3A,   // ':'
              bytes[7] == 0x3A,   // ':'
              bytes[10] == 0x20,  // ' '
              bytes[13] == 0x3A,  // ':'
              bytes[16] == 0x3A   // ':'
        else { return nil }

        // Every remaining byte must be an ASCII digit (checked in
        // `decimal`), which also excludes non-ASCII bytes that happen
        // to fill 19 UTF-8 bytes.
        guard let year = Self.decimal(bytes, 0..<4),
              let month = Self.decimal(bytes, 5..<7),
              let day = Self.decimal(bytes, 8..<10),
              let hour = Self.decimal(bytes, 11..<13),
              let minute = Self.decimal(bytes, 14..<16),
              let second = Self.decimal(bytes, 17..<19)
        else { return nil }

        self.init(year: year, month: month, day: day,
                  hour: hour, minute: minute, second: second)
    }

    /// The canonical text form: zero-padded decimal components joined by
    /// ':' and one ' ', built with plain integer and String operations.
    var metadataText: String {
        Self.padded(year, to: 4) + ":" + Self.padded(month, to: 2) + ":"
            + Self.padded(day, to: 2) + " " + Self.padded(hour, to: 2) + ":"
            + Self.padded(minute, to: 2) + ":" + Self.padded(second, to: 2)
    }

    private static func lastDay(ofMonth month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return isLeapYear(year) ? 29 : 28  // month 2; caller validated 1...12
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    /// Fixed-width unsigned decimal over `range`; every byte must be an
    /// ASCII digit, so no sign, space or non-ASCII byte can slip in. At
    /// most four digits are accumulated, so the value fits in an Int.
    private static func decimal(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        var value = 0
        for index in range {
            let byte = bytes[index]
            guard (0x30...0x39).contains(byte) else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        return value
    }

    private static func padded(_ value: Int, to width: Int) -> String {
        let digits = String(value)
        let zeros = width - digits.count
        guard zeros > 0 else { return digits }
        return String(repeating: "0", count: zeros) + digits
    }
}
