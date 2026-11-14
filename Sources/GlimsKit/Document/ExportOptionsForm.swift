import AppKit

/// The export formats the save flow offers, in the Format popup's order.
/// `forFileExtension` maps every common alias — "png", "jpg", "jpeg",
/// "tif", "tiff" — to its format, case-insensitively and tolerating a
/// leading dot; an unknown or empty extension gets nil so the caller
/// picks a fallback rather than guessing.
enum ExportFormat: String, CaseIterable {
    case png, jpeg, tiff, psd, gif, bmp, tga

    var title: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .psd: return "PSD"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        case .tga: return "TGA"
        }
    }

    /// The extension suggested for a new file name of this format. Every
    /// accepted alias still resolves through `forFileExtension`.
    var preferredExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .psd: return "psd"
        case .gif: return "gif"
        case .bmp: return "bmp"
        case .tga: return "tga"
        }
    }

    static func forFileExtension(_ ext: String) -> ExportFormat? {
        let key = ext.lowercased()
        switch key.hasPrefix(".") ? String(key.dropFirst()) : key {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "tif", "tiff": return .tiff
        case "psd": return .psd
        case "gif": return .gif
        case "bmp": return .bmp
        case "tga": return .tga
        default: return nil
        }
    }
}

/// The export options captured by ExportOptionsForm, as one plain value:
/// the chosen format plus every format's own knobs kept together, so a
/// format switch preserves the other formats' settings. Interactive
/// edits reach these values only through the form's typed, range-checked
/// commits; `validate` is the last gate before an export runs.
struct ExportSettings: Equatable {
    var format: ExportFormat = .png

    /// The JPEG quality factor, 0 ... 1.
    var jpegQuality: Double = 0.9
    var jpegProgressive = true
    var jpegOptimize = true
    var jpegSubsampling = JpegSubsampling.full

    /// The PNG compression level, 0 ... 9.
    var pngCompression = 9
    var pngInterlaced = false
    var pngPreserveTransparentColor = false

    enum BitmapMethod: String, CaseIterable {
        case existing, threshold, diffusion
        var title: String {
            switch self {
            case .existing: return "Existing black and white"
            case .threshold: return "Threshold grayscale"
            case .diffusion: return "Diffusion dither"
            }
        }
    }
    var bitmapMethod = BitmapMethod.existing
    /// Inclusive 8-bit grayscale cutoff; samples at or below become black.
    var bitmapThreshold = 127

    var psdLayout = PsdLayout.layers
    /// PSD output color: the document's RGB/grayscale pixels, or a CMYK output
    /// conversion that keeps RGB editing unchanged.
    var psdColor: PsdOutputColor = .document
    /// The captured CMYK destination profile for PSD CMYK export. Retained as
    /// exact bytes (including repeat/batch/export reuse) even if the installed
    /// profile later changes or leaves the catalog.
    var psdCmykProfile: PsdCmykProfile?

    /// Native ink output uses the document's own profile and fixed channels.
    /// Conversion or merged-appearance settings must not be silently ignored.
    var permitsNativeCmykPSD: Bool {
        Self.validate(self) && format == .psd && psdColor == .document
            && psdLayout == .layers && psdCmykProfile == nil
    }

    enum PsdLayout: String, CaseIterable {
        case layers, merged

        var title: String {
            switch self {
            case .layers: return "Layers"
            case .merged: return "Merged appearance"
            }
        }

        var explanation: String {
            switch self {
            case .layers: return "Keeps layers and masks. Effects are rendered into layers; blending may change. Save XCF to retain full editing and precision."
            case .merged: return "Exports the visible image as one layer, including transparency. Save XCF to retain full editing and precision."
            }
        }
    }

    var tiffCompression = TiffCompression.none
    var tiffPreserveTransparentColor = true

    /// JPEG's chroma subsampling, in the popup's display order.
    enum JpegSubsampling: String, CaseIterable {
        /// 4:4:4 — no subsampling.
        case full
        /// 4:2:2 — chroma halved horizontally.
        case horizontal
        /// 4:4:0 — chroma halved vertically.
        case vertical
        /// 4:2:0 — chroma halved in both directions.
        case both

        var title: String {
            switch self {
            case .full: return "4:4:4"
            case .horizontal: return "4:2:2"
            case .vertical: return "4:4:0"
            case .both: return "4:2:0"
            }
        }
    }

    /// TIFF's compression modes, in the popup's display order.
    enum TiffCompression: String, CaseIterable {
        case none, lzw, deflate, packBits

        var title: String {
            switch self {
            case .none: return "None"
            case .lzw: return "LZW"
            case .deflate: return "Deflate"
            case .packBits: return "Pack Bits"
            }
        }
    }

    /// The typed range gate: quality is a finite 0 ... 1, compression a whole
    /// 0 ... 9, and any captured PSD CMYK profile is a valid CMYK ICC payload.
    /// A missing CMYK profile is only required at commit for an active PSD+CMYK
    /// export; other formats keep their stored choice.
    static func validate(_ settings: ExportSettings) -> Bool {
        guard settings.jpegQuality.isFinite && (0...1).contains(settings.jpegQuality)
                && (0...9).contains(settings.pngCompression)
                && (0...255).contains(settings.bitmapThreshold) else { return false }
        // PsdCmykProfile validates its immutable bytes at construction.
        return true
    }

    /// Whether this settings value can run as the active export choice.
    var isReadyToExport: Bool {
        guard Self.validate(self) else { return false }
        if format == .psd, psdColor == .cmyk {
            return psdCmykProfile != nil
        }
        if format == .psd, psdColor == .bitmap {
            return psdLayout == .merged
        }
        return true
    }
}

/// A slider + field row for one numeric export option, shaped like the
/// filter rows but refusing instead of clamping: a commit the row cannot
/// read, that is not finite or that lands outside the option's range
/// leaves the stored value alone, keeps the typed text for correction
/// and reports a readable reason for the form's inline message. Slider
/// drags snap to whole units; the field is the precision path and parses
/// with the same user-locale formatter it displays, so a comma-decimal
/// system both shows and accepts "90,5".
final class ExportNumberRow: NSView {
    private let range: ClosedRange<Double>
    private let isInteger: Bool
    /// The readable reason reported for a refused commit.
    private let rejection: String
    let slider: NSSlider
    let field = NSTextField()
    /// Displays and parses the field's text — deliberately NOT installed
    /// as the field's `formatter`, so a refused value can never trigger
    /// AppKit's modal format error.
    let formatter = NumberFormatter()
    private(set) var value: Double = 0
    private var hasEditedText = false
    /// An accepted commit that moved the value (slider drag or field).
    var onChange: ((Double) -> Void)?
    /// An accepted field commit that restated the current value.
    var onAccepted: (() -> Void)?
    /// A refused field commit; the argument is the readable reason.
    var onRejected: ((String) -> Void)?

    init(label: String, unit: String? = nil, range: ClosedRange<Double>,
         integer: Bool, rejection: String) {
        self.range = range
        self.isInteger = integer
        self.rejection = rejection
        self.slider = NSSlider(value: range.lowerBound, minValue: range.lowerBound,
                               maxValue: range.upperBound, target: nil, action: nil)
        super.init(frame: .zero)
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        formatter.usesGroupingSeparator = false

        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        slider.setAccessibilityLabel(label)

        field.target = self
        field.action = #selector(fieldChanged)
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        field.setAccessibilityLabel(label)

        let stack = NSStackView(views: [slider, field])
        stack.spacing = 8
        if let unit {
            let unitLabel = NSTextField(labelWithString: unit)
            unitLabel.textColor = .secondaryLabelColor
            stack.addArrangedSubview(unitLabel)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `newValue` without reporting a change — the initial read
    /// from settings.
    func show(_ newValue: Double) {
        hasEditedText = false
        value = newValue
        field.stringValue = display(newValue)
        slider.doubleValue = newValue
    }

    private func display(_ v: Double) -> String {
        if isInteger { return String(Int(v.rounded())) }
        return formatter.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// Whole-string typed parsing: integer rows take a canonical Int
    /// ("9" but not "9.5" or a prefix), number rows the user's decimal
    /// text. Nonfinite results count as unreadable.
    private func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parsed = isInteger ? Int(trimmed).map(Double.init)
                               : formatter.number(from: trimmed)?.doubleValue
        guard let typed = parsed, typed.isFinite else { return nil }
        return typed
    }

    @objc private func sliderChanged() {
        hasEditedText = false
        let dragged = min(max(slider.doubleValue.rounded(), range.lowerBound), range.upperBound)
        guard dragged != value else { return }
        value = dragged
        field.stringValue = display(dragged)
        onChange?(dragged)
    }

    @objc private func fieldChanged() {
        commitField()
    }

    /// Validates the field text against the option's typed range. An
    /// accepted value is stored, shown canonically and reported; a
    /// refusal keeps the typed text, reports the reason and returns
    /// false so the caller can refuse too — no silent reset to a
    /// default and no truncation of the stored value.
    @discardableResult
    func commitField() -> Bool {
        // Display rounding must not rewrite an untouched stored value. An
        // explicit edit to the same displayed text still applies that text.
        if !hasEditedText && field.stringValue == display(value) {
            onAccepted?()
            return true
        }
        guard let typed = parse(field.stringValue), range.contains(typed) else {
            onRejected?(rejection)
            NSSound.beep()
            return false
        }
        field.stringValue = display(typed)
        hasEditedText = false
        slider.doubleValue = typed
        if typed != value {
            value = typed
            onChange?(typed)
        } else {
            onAccepted?()
        }
        return true
    }
}

extension ExportNumberRow: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ notification: Notification) {
        hasEditedText = false
    }

    func controlTextDidChange(_ notification: Notification) {
        hasEditedText = true
    }

    /// Committing happens on Return or when the field loses focus, the
    /// same two moments a value field applies elsewhere in the app.
    func controlTextDidEndEditing(_ notification: Notification) {
        commitField()
    }
}

/// The File ▸ Export… options view: the Format popup and the per-format
/// option rows it swaps below (JPEG quality/optimize/progressive/
/// subsampling, PNG compression/interlace/transparent color, TIFF
/// compression/transparent color, PSD content/color/profile), plus an inline
/// message line. The view owns no panel, filename or engine call — the
/// controller embeds it and reads `settings` after a successful
/// `commitEditing`.
///
/// Switching the format preserves every format's own settings: the
/// struct always carries all of them, and a hidden section's controls
/// reappear as they were. The sections live in one grid whose width is
/// pinned to the widest combination, so a format swap never resizes the
/// form. A numeric field keeps a refused draft — never a silent reset
/// to a default or a truncated read — and `commitEditing` re-checks the
/// visible format's fields, shows a readable inline reason, focuses the
/// offending field and returns false, which must prevent the export.
/// No modal alert is ever shown here.
@MainActor
final class ExportOptionsForm: NSView {
    private(set) var settings: ExportSettings
    /// Reports user-picked and programmatic format changes; not fired
    /// for the format the view was seeded with.
    var onFormatChange: ((ExportFormat) -> Void)?

    // The named controls stay visible (not private) so the smoke tests
    // and the owning controller can drive them; each carries an
    // accessibility label.
    let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let qualityRow = ExportNumberRow(label: "JPEG quality", unit: "%", range: 0...100,
        integer: false, rejection: "Quality must be a number from 0 to 100.")
    let subsamplingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let optimizeBox = NSButton(checkboxWithTitle: "Optimize", target: nil, action: nil)
    let progressiveBox = NSButton(checkboxWithTitle: "Progressive", target: nil, action: nil)
    let compressionRow = ExportNumberRow(label: "PNG compression", range: 0...9,
        integer: true, rejection: "Compression must be a whole number from 0 to 9.")
    let interlacedBox = NSButton(checkboxWithTitle: "Interlaced (Adam7)", target: nil, action: nil)
    let pngTransparentBox = NSButton(checkboxWithTitle: "Preserve transparent pixel colors",
        target: nil, action: nil)
    let tiffCompressionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let tiffTransparentBox = NSButton(checkboxWithTitle: "Preserve transparent pixel colors",
        target: nil, action: nil)
    let psdLayoutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let psdColorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let bitmapMethodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let bitmapThresholdRow = ExportNumberRow(label: "Bitmap threshold", range: 0...255,
        integer: true, rejection: "Threshold must be a whole number from 0 to 255.")
    let psdCmykProfilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let psdExplanation = NSTextField(wrappingLabelWithString: "")
    let bmpExplanation = NSTextField(wrappingLabelWithString:
        "Exports the visible image as uncompressed 32-bit sRGB with transparency. Some older BMP readers ignore alpha. Save XCF to retain layers, profile and precision.")
    let tgaExplanation = NSTextField(wrappingLabelWithString:
        "Exports the visible image as uncompressed 32-bit sRGB with transparency and top-left origin. No color profile is embedded. Save XCF to retain layers, profile and precision.")
    let gifExplanation = NSTextField(wrappingLabelWithString:
        "Exports the visible image with up to 256 colors. Pixels below 50% opacity become transparent; other pixels become opaque. One image, without animation. Save XCF to retain layers and precision.")
    let messageLabel = NSTextField(labelWithString: "")
    /// The last readable refusal shown inline; nil while clean.
    private(set) var lastError: String?
    /// The grid's per-format option rows; a format switch hides the
    /// others'.
    private var optionRows: [ExportFormat: [NSGridRow]] = [:]
    private var psdCmykProfileRow: NSGridRow?
    private var bitmapMethodGridRow: NSGridRow?
    private var bitmapThresholdGridRow: NSGridRow?
    private var psdCmykCatalog = PsdCmykProfileCatalog()
    private var psdCmykLoadGeneration = 0
    private var psdCmykCatalogLoader: any PsdCmykProfileCatalogLoading
    private let psdCmykPlaceholderTitle = "Choose a profile"
    enum Context {
        case ordinary
        case nativeCmyk(profileName: String)
    }
    private let context: Context
    private let supportsBitmapPSD: Bool
    private let supportsBitmapThresholdPSD: Bool
    private let supportsBitmapDiffusionPSD: Bool
    private var nativeCmyk: Bool {
        if case .nativeCmyk = context { return true }
        return false
    }

    init(settings: ExportSettings = ExportSettings(),
         context: Context = .ordinary,
         supportsBitmapPSD: Bool = false,
         supportsBitmapThresholdPSD: Bool = false,
         supportsBitmapDiffusionPSD: Bool = false,
         psdCmykCatalogLoader: any PsdCmykProfileCatalogLoading = LivePsdCmykProfileCatalogLoader()) {
        self.context = context
        self.supportsBitmapPSD = supportsBitmapPSD
        self.supportsBitmapThresholdPSD = supportsBitmapThresholdPSD
        self.supportsBitmapDiffusionPSD = supportsBitmapDiffusionPSD
        var initial = settings
        if case .nativeCmyk = context {
            initial.format = .psd
            initial.psdColor = .document
            initial.psdLayout = .layers
            initial.psdCmykProfile = nil
        }
        self.settings = initial
        self.psdCmykCatalogLoader = psdCmykCatalogLoader
        super.init(frame: .zero)
        buildContent()
        show(initial)
        applyFormatVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        formatPopup.addItems(withTitles: ExportFormat.allCases.map(\.title))
        formatPopup.setAccessibilityLabel("Export format")
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))

        subsamplingPopup.addItems(withTitles: ExportSettings.JpegSubsampling.allCases.map(\.title))
        subsamplingPopup.setAccessibilityLabel("JPEG subsampling")
        subsamplingPopup.target = self
        subsamplingPopup.action = #selector(subsamplingChanged(_:))

        tiffCompressionPopup.addItems(withTitles: ExportSettings.TiffCompression.allCases.map(\.title))
        tiffCompressionPopup.setAccessibilityLabel("TIFF compression")
        tiffCompressionPopup.target = self
        tiffCompressionPopup.action = #selector(tiffCompressionChanged(_:))

        psdLayoutPopup.addItems(withTitles: ExportSettings.PsdLayout.allCases.map(\.title))
        psdLayoutPopup.setAccessibilityLabel("PSD content")
        psdLayoutPopup.target = self
        psdLayoutPopup.action = #selector(psdLayoutChanged(_:))

        psdColorPopup.addItems(withTitles: PsdOutputColor.allCases.map(\.title))
        psdColorPopup.menu?.autoenablesItems = false
        if let index = PsdOutputColor.allCases.firstIndex(of: .bitmap) {
            psdColorPopup.item(at: index)?.isEnabled = supportsBitmapPSD
        }
        bitmapMethodPopup.addItems(withTitles: ExportSettings.BitmapMethod.allCases.map(\.title))
        bitmapMethodPopup.setAccessibilityLabel("Bitmap conversion")
        bitmapMethodPopup.menu?.autoenablesItems = false
        if let index = ExportSettings.BitmapMethod.allCases.firstIndex(of: .threshold) {
            bitmapMethodPopup.item(at: index)?.isEnabled = supportsBitmapThresholdPSD
        }
        if let index = ExportSettings.BitmapMethod.allCases.firstIndex(of: .diffusion) {
            bitmapMethodPopup.item(at: index)?.isEnabled = supportsBitmapDiffusionPSD
        }
        bitmapMethodPopup.target = self
        bitmapMethodPopup.action = #selector(bitmapMethodChanged(_:))
        psdColorPopup.setAccessibilityLabel("PSD color")
        psdColorPopup.target = self
        psdColorPopup.action = #selector(psdColorChanged(_:))

        if nativeCmyk {
            formatPopup.isEnabled = false
            psdLayoutPopup.item(at: 0)?.title = "Native ink channels"
            psdLayoutPopup.isEnabled = false
            psdColorPopup.item(at: 0)?.title = "Document CMYK"
            psdColorPopup.isEnabled = false
            psdCmykProfilePopup.isEnabled = false
        }

        rebuildPsdCmykProfilePopup(entries: [])
        psdCmykProfilePopup.setAccessibilityLabel("CMYK profile")
        psdCmykProfilePopup.target = self
        psdCmykProfilePopup.action = #selector(psdCmykProfileChanged(_:))
        psdCmykProfilePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 270).isActive = true
        if let cell = psdCmykProfilePopup.cell as? NSPopUpButtonCell {
            cell.lineBreakMode = .byTruncatingTail
        }

        psdExplanation.font = .systemFont(ofSize: 11)
        psdExplanation.textColor = .secondaryLabelColor
        psdExplanation.preferredMaxLayoutWidth = 270
        gifExplanation.font = .systemFont(ofSize: 11)
        gifExplanation.textColor = .secondaryLabelColor
        gifExplanation.preferredMaxLayoutWidth = 270
        for explanation in [bmpExplanation, tgaExplanation] {
            explanation.font = .systemFont(ofSize: 11)
            explanation.textColor = .secondaryLabelColor
            explanation.preferredMaxLayoutWidth = 270
            explanation.widthAnchor.constraint(equalToConstant: 270).isActive = true
        }
        psdExplanation.widthAnchor.constraint(equalToConstant: 270).isActive = true

        for box in [optimizeBox, progressiveBox, interlacedBox, pngTransparentBox, tiffTransparentBox] {
            box.setAccessibilityLabel(box.title)
            box.target = self
            box.action = #selector(toggleChanged(_:))
        }
        for box in [pngTransparentBox, tiffTransparentBox] {
            box.toolTip = "Keep color channel values where pixels are fully transparent."
        }

        qualityRow.onChange = { [weak self] percent in
            self?.settings.jpegQuality = percent / 100
            self?.clearMessage()
        }
        qualityRow.onAccepted = { [weak self] in self?.clearMessage() }
        qualityRow.onRejected = { [weak self] reason in self?.refuse(reason) }
        compressionRow.onChange = { [weak self] level in
            self?.settings.pngCompression = Int(level)
            self?.clearMessage()
        }
        compressionRow.onAccepted = { [weak self] in self?.clearMessage() }
        compressionRow.onRejected = { [weak self] reason in self?.refuse(reason) }

        bitmapThresholdRow.onChange = { [weak self] value in
            self?.settings.bitmapThreshold = Int(value)
            self?.clearMessage()
        }
        bitmapThresholdRow.onAccepted = { [weak self] in self?.clearMessage() }
        bitmapThresholdRow.onRejected = { [weak self] reason in self?.refuse(reason) }

        messageLabel.setAccessibilityLabel("Export options message")
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 3

        let jpegRows: [[NSView]] = [
            [NSTextField(labelWithString: "Quality:"), qualityRow],
            [NSTextField(labelWithString: "Subsampling:"), subsamplingPopup],
            [NSGridCell.emptyContentView, optimizeBox],
            [NSGridCell.emptyContentView, progressiveBox],
        ]
        let pngRows: [[NSView]] = [
            [NSTextField(labelWithString: "Compression:"), compressionRow],
            [NSGridCell.emptyContentView, interlacedBox],
            [NSGridCell.emptyContentView, pngTransparentBox],
        ]
        let tiffRows: [[NSView]] = [
            [NSTextField(labelWithString: "Compression:"), tiffCompressionPopup],
            [NSGridCell.emptyContentView, tiffTransparentBox],
        ]
        let psdRows: [[NSView]] = [
            [NSTextField(labelWithString: "Content:"), psdLayoutPopup],
            [NSTextField(labelWithString: "Color:"), psdColorPopup],
            [NSTextField(labelWithString: "CMYK profile:"), psdCmykProfilePopup],
            [NSTextField(labelWithString: "Bitmap method:"), bitmapMethodPopup],
            [NSTextField(labelWithString: "Threshold:"), bitmapThresholdRow],
            [NSGridCell.emptyContentView, psdExplanation],
        ]
        let bitmapRows: [[NSView]] = [
            [NSGridCell.emptyContentView, gifExplanation],
            [NSGridCell.emptyContentView, bmpExplanation],
            [NSGridCell.emptyContentView, tgaExplanation],
        ]
        let grid = NSGridView(views:
            [[NSTextField(labelWithString: "Format:"), formatPopup]] + jpegRows + pngRows + tiffRows + psdRows + bitmapRows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        let psdStart = 10
        let psdAllRows = (psdStart..<(psdStart + psdRows.count)).map { grid.row(at: $0) }
        psdCmykProfileRow = psdAllRows[2]
        bitmapMethodGridRow = psdAllRows[3]
        bitmapThresholdGridRow = psdAllRows[4]
        optionRows = [
            .jpeg: (1...4).map { grid.row(at: $0) },
            .png: (5...7).map { grid.row(at: $0) },
            .tiff: (8...9).map { grid.row(at: $0) },
            .psd: psdAllRows,
            .gif: [grid.row(at: psdStart + psdRows.count)],
            .bmp: [grid.row(at: psdStart + psdRows.count + 1)],
            .tga: [grid.row(at: psdStart + psdRows.count + 2)],
        ]
        let fullWidth = ceil(grid.fittingSize.width)

        grid.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        addSubview(messageLabel)
        messageLabel.preferredMaxLayoutWidth = fullWidth
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            grid.widthAnchor.constraint(greaterThanOrEqualToConstant: fullWidth),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            messageLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    /// Shows the seeded settings in every control; the format's own
    /// option rows become visible through `applyFormatVisibility`.
    private func show(_ settings: ExportSettings) {
        if let index = ExportFormat.allCases.firstIndex(of: settings.format) {
            formatPopup.selectItem(at: index)
        }
        qualityRow.show(settings.jpegQuality * 100)
        subsamplingPopup.selectItem(at: popupIndex(of: settings.jpegSubsampling,
            in: ExportSettings.JpegSubsampling.allCases))
        optimizeBox.state = settings.jpegOptimize ? .on : .off
        progressiveBox.state = settings.jpegProgressive ? .on : .off
        compressionRow.show(Double(settings.pngCompression))
        interlacedBox.state = settings.pngInterlaced ? .on : .off
        pngTransparentBox.state = settings.pngPreserveTransparentColor ? .on : .off
        tiffCompressionPopup.selectItem(at: popupIndex(of: settings.tiffCompression,
            in: ExportSettings.TiffCompression.allCases))
        tiffTransparentBox.state = settings.tiffPreserveTransparentColor ? .on : .off
        psdLayoutPopup.selectItem(at: popupIndex(of: settings.psdLayout, in: ExportSettings.PsdLayout.allCases))
        psdColorPopup.selectItem(at: popupIndex(of: settings.psdColor, in: PsdOutputColor.allCases))
        bitmapMethodPopup.selectItem(at: popupIndex(of: settings.bitmapMethod, in: ExportSettings.BitmapMethod.allCases))
        bitmapThresholdRow.show(Double(settings.bitmapThreshold))
        rebuildPsdCmykProfilePopup(entries: currentCatalogEntries())
        syncPsdCmykProfileSelection()
        updatePsdExplanation()
        loadPsdCmykCatalogIfNeeded()
    }

    private func popupIndex<T: Equatable>(of value: T, in choices: [T]) -> Int {
        choices.firstIndex(of: value) ?? 0
    }

    private func currentCatalogEntries() -> [PsdCmykProfileCatalogEntry] {
        if case .loaded(let entries) = psdCmykCatalog.state { return entries }
        return []
    }

    private func applyFormatVisibility() {
        for (format, rows) in optionRows {
            rows.forEach { $0.isHidden = format != settings.format }
        }
        psdLayoutPopup.isEnabled = !nativeCmyk && settings.psdColor != .bitmap
        let showBitmap = settings.format == .psd && !nativeCmyk && settings.psdColor == .bitmap
        bitmapMethodGridRow?.isHidden = !showBitmap
        bitmapThresholdGridRow?.isHidden = !showBitmap || settings.bitmapMethod != .threshold
        let showCmyk = settings.format == .psd && (nativeCmyk || settings.psdColor == .cmyk)
        psdCmykProfileRow?.isHidden = !showCmyk
        if showCmyk { loadPsdCmykCatalogIfNeeded() }
    }

    private func updatePsdExplanation() {
        if nativeCmyk {
            psdExplanation.stringValue = "All four inks, including hidden inks, and the source profile are preserved. Print resolution and other metadata are omitted. Save XCF to retain full editing."
            return
        }
        switch settings.psdColor {
        case .document:
            psdExplanation.stringValue = settings.psdLayout.explanation
        case .cmyk:
            psdExplanation.stringValue = "\(settings.psdLayout.explanation) \(PsdOutputColor.cmyk.explanation)"
        case .bitmap:
            switch settings.bitmapMethod {
            case .existing:
                psdExplanation.stringValue = PsdOutputColor.bitmap.explanation
            case .threshold:
                psdExplanation.stringValue = "Converts opaque grayscale pixels at or below the threshold to black, and the rest to white. Transparency and linked layers are refused. Layers and metadata are omitted. Save XCF to keep editing."
            case .diffusion:
                psdExplanation.stringValue = "Uses diffusion dithering to convert opaque grayscale to black and white. Transparency and linked layers are refused. Layers and metadata are omitted. Save XCF to keep editing."
            }
        }
    }

    private func refuse(_ message: String) {
        lastError = message
        messageLabel.textColor = .systemRed
        messageLabel.stringValue = message
    }

    private func clearMessage() {
        lastError = nil
        messageLabel.stringValue = ""
    }

    private func showInfoMessage(_ message: String) {
        lastError = nil
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = message
    }

    // MARK: PSD CMYK profile catalog

    private func rebuildPsdCmykProfilePopup(entries: [PsdCmykProfileCatalogEntry]) {
        psdCmykProfilePopup.removeAllItems()
        if case .nativeCmyk(let name) = context {
            psdCmykProfilePopup.addItem(withTitle: name.isEmpty ? "Document source profile" : name)
            psdCmykProfilePopup.toolTip = name
            return
        }
        psdCmykProfilePopup.addItem(withTitle: psdCmykPlaceholderTitle)
        psdCmykProfilePopup.lastItem?.representedObject = nil
        func append(_ profile: PsdCmykProfile) {
            // NSPopUpButton.addItem(withTitle:) coalesces duplicate titles.
            // Different profiles may share a name; retain each byte identity.
            let item = NSMenuItem(title: profile.displayName, action: nil, keyEquivalent: "")
            item.representedObject = profile.iccData
            item.toolTip = profile.displayName
            item.setAccessibilityLabel(profile.displayName)
            psdCmykProfilePopup.menu?.addItem(item)
        }
        for entry in entries { append(entry.profile) }
        if let profile = settings.psdCmykProfile,
           !entries.contains(where: { $0.profile.iccData == profile.iccData }) {
            append(profile)
        }
        syncPsdCmykProfileSelection()
    }

    private func syncPsdCmykProfileSelection() {
        guard let profile = settings.psdCmykProfile else {
            psdCmykProfilePopup.selectItem(at: 0)
            return
        }
        if let index = (0..<psdCmykProfilePopup.numberOfItems).first(where: { index in
            (psdCmykProfilePopup.item(at: index)?.representedObject as? Data) == profile.iccData
        }) {
            psdCmykProfilePopup.selectItem(at: index)
        } else {
            psdCmykProfilePopup.selectItem(at: 0)
        }
    }

    private func loadPsdCmykCatalogIfNeeded() {
        guard !nativeCmyk else { return }
        guard settings.format == .psd, settings.psdColor == .cmyk else { return }
        if case .loading = psdCmykCatalog.state { return }
        if case .loaded = psdCmykCatalog.state { return }
        if case .failed = psdCmykCatalog.state { return }
        psdCmykCatalog.state = .loading
        psdCmykLoadGeneration += 1
        let generation = psdCmykLoadGeneration
        let loader = psdCmykCatalogLoader
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try loader.loadCatalog() }
            DispatchQueue.main.async { [weak self] in
                self?.applyPsdCmykCatalogResult(result, generation: generation)
            }
        }
    }

    private func applyPsdCmykCatalogResult(_ result: Result<[PsdCmykProfileCatalogEntry], Error>, generation: Int) {
        guard generation == psdCmykLoadGeneration else { return }
        // Catalog results must not clear/replace the captured profile bytes or
        // retarget another form; they only refresh the available choices.
        switch result {
        case .success(let entries):
            psdCmykCatalog.state = .loaded(entries)
            rebuildPsdCmykProfilePopup(entries: entries)
            if entries.isEmpty, settings.format == .psd, settings.psdColor == .cmyk, settings.psdCmykProfile == nil {
                showInfoMessage(PsdCmykProfileCatalog.emptyMessage)
            }
        case .failure:
            psdCmykCatalog.state = .failed(PsdCmykProfileCatalog.failedPrefix)
            rebuildPsdCmykProfilePopup(entries: [])
            if settings.format == .psd, settings.psdColor == .cmyk, settings.psdCmykProfile == nil {
                refuse("\(PsdCmykProfileCatalog.failedPrefix) \(PsdCmykProfileCatalog.installMessage)")
            }
        }
    }

    // MARK: Actions

    /// Picks `format` programmatically — the same swap a popup pick
    /// makes, reported through `onFormatChange`. No-op when already
    /// current.
    func selectFormat(_ format: ExportFormat) {
        guard !nativeCmyk || format == .psd else { return }
        guard format != settings.format else { return }
        settings.format = format
        if let index = ExportFormat.allCases.firstIndex(of: format) {
            formatPopup.selectItem(at: index)
        }
        clearMessage()
        applyFormatVisibility()
        onFormatChange?(format)
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard ExportFormat.allCases.indices.contains(index) else { return }
        selectFormat(ExportFormat.allCases[index])
    }

    @objc private func subsamplingChanged(_ sender: NSPopUpButton) {
        let choices = ExportSettings.JpegSubsampling.allCases
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        settings.jpegSubsampling = choices[sender.indexOfSelectedItem]
        clearMessage()
    }

    @objc private func tiffCompressionChanged(_ sender: NSPopUpButton) {
        let choices = ExportSettings.TiffCompression.allCases
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        settings.tiffCompression = choices[sender.indexOfSelectedItem]
        clearMessage()
    }

    @objc private func psdLayoutChanged(_ sender: NSPopUpButton) {
        guard !nativeCmyk else { return }
        let choices = ExportSettings.PsdLayout.allCases
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        settings.psdLayout = choices[sender.indexOfSelectedItem]
        updatePsdExplanation()
        clearMessage()
    }

    @objc private func bitmapMethodChanged(_ sender: NSPopUpButton) {
        guard !nativeCmyk else { return }
        let choices = ExportSettings.BitmapMethod.allCases
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        settings.bitmapMethod = choices[sender.indexOfSelectedItem]
        updatePsdExplanation()
        applyFormatVisibility()
        clearMessage()
    }

    @objc private func psdColorChanged(_ sender: NSPopUpButton) {
        guard !nativeCmyk else { return }
        let choices = PsdOutputColor.allCases
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        settings.psdColor = choices[sender.indexOfSelectedItem]
        if settings.psdColor == .bitmap {
            settings.psdLayout = .merged
            psdLayoutPopup.selectItem(at: popupIndex(of: .merged, in: ExportSettings.PsdLayout.allCases))
        }
        updatePsdExplanation()
        clearMessage()
        applyFormatVisibility()
    }

    @objc private func psdCmykProfileChanged(_ sender: NSPopUpButton) {
        guard !nativeCmyk else { return }
        guard let data = sender.selectedItem?.representedObject as? Data,
              PsdCmykProfile.isValidICCData(data) else {
            settings.psdCmykProfile = nil
            if settings.format == .psd, settings.psdColor == .cmyk {
                showInfoMessage("Choose a CMYK profile before exporting. \(PsdCmykProfileCatalog.installMessage)")
            } else {
                clearMessage()
            }
            syncPsdCmykProfileSelection()
            return
        }
        let name = sender.selectedItem?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.psdCmykProfile = try? PsdCmykProfile(displayName: name?.isEmpty == false ? name! : "CMYK Profile",
                                                      iccData: data)
        if settings.psdCmykProfile == nil {
            refuse("Choose a valid installed CMYK profile no larger than 4 MB.")
        } else {
            clearMessage()
        }
        syncPsdCmykProfileSelection()
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        let on = sender.state == .on
        if sender === optimizeBox {
            settings.jpegOptimize = on
        } else if sender === progressiveBox {
            settings.jpegProgressive = on
        } else if sender === interlacedBox {
            settings.pngInterlaced = on
        } else if sender === pngTransparentBox {
            settings.pngPreserveTransparentColor = on
        } else if sender === tiffTransparentBox {
            settings.tiffPreserveTransparentColor = on
        }
        clearMessage()
    }

    // MARK: Validation gate

    /// Commits the active editor and re-checks the visible format's
    /// numeric fields plus the whole settings value. A refused field
    /// shows its readable reason inline, gets the focus and returns
    /// false — which must prevent the export. The stored settings are
    /// left untouched by a refusal; a hidden format's stale draft does
    /// not block an export of the visible format.
    func commitEditing() -> Bool {
        window?.endEditing(for: nil)
        if nativeCmyk {
            guard settings.permitsNativeCmykPSD else {
                refuse("Native CMYK export requires PSD with the document's ink channels and source profile.")
                return false
            }
            clearMessage()
            return true
        }
        switch settings.format {
        case .jpeg:
            guard qualityRow.commitField() else {
                window?.makeFirstResponder(qualityRow.field)
                return false
            }
        case .png:
            guard compressionRow.commitField() else {
                window?.makeFirstResponder(compressionRow.field)
                return false
            }
        case .tiff, .psd, .gif, .bmp, .tga:
            break
        }
        guard ExportSettings.validate(settings) else {
            refuse("The export settings are invalid.")
            return false
        }
        if settings.format == .psd, settings.psdColor == .bitmap {
            guard supportsBitmapPSD, settings.psdLayout == .merged else {
                refuse("Bitmap PSD export is not available with these settings or this image engine.")
                return false
            }
            if settings.bitmapMethod == .threshold {
                guard supportsBitmapThresholdPSD else {
                    refuse("Threshold Bitmap export is not available for this document or image engine.")
                    return false
                }
                guard bitmapThresholdRow.commitField() else {
                    window?.makeFirstResponder(bitmapThresholdRow.field)
                    return false
                }
            }
            if settings.bitmapMethod == .diffusion && !supportsBitmapDiffusionPSD {
                refuse("Diffusion Bitmap export is not available for this document or image engine.")
                return false
            }
        }
        if settings.format == .psd, settings.psdColor == .cmyk {
            guard let profile = settings.psdCmykProfile, PsdCmykProfile.isValidICCData(profile.iccData) else {
                if case .failed = psdCmykCatalog.state {
                    refuse("\(PsdCmykProfileCatalog.failedPrefix) \(PsdCmykProfileCatalog.installMessage)")
                } else if case .loaded(let entries) = psdCmykCatalog.state, entries.isEmpty {
                    refuse(PsdCmykProfileCatalog.emptyMessage)
                } else {
                    refuse("Choose a CMYK profile before exporting. \(PsdCmykProfileCatalog.installMessage)")
                }
                window?.makeFirstResponder(psdCmykProfilePopup)
                return false
            }
        }
        clearMessage()
        return true
    }

    /// Test/support hook: installs a catalog result as if discovery finished.
    func applyPsdCmykCatalogForTesting(_ result: Result<[PsdCmykProfileCatalogEntry], Error>) {
        psdCmykLoadGeneration += 1
        applyPsdCmykCatalogResult(result, generation: psdCmykLoadGeneration)
    }
}
