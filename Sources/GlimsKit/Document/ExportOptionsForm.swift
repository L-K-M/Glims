import AppKit

/// The export formats the save flow offers, in the Format popup's order.
/// `forFileExtension` maps every common alias — "png", "jpg", "jpeg",
/// "tif", "tiff" — to its format, case-insensitively and tolerating a
/// leading dot; an unknown or empty extension gets nil so the caller
/// picks a fallback rather than guessing.
enum ExportFormat: String, CaseIterable {
    case png, jpeg, tiff, psd

    var title: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .psd: return "PSD"
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
        }
    }

    static func forFileExtension(_ ext: String) -> ExportFormat? {
        let key = ext.lowercased()
        switch key.hasPrefix(".") ? String(key.dropFirst()) : key {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "tif", "tiff": return .tiff
        case "psd": return .psd
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

    var psdLayout = PsdLayout.layers

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

    /// The typed range gate: quality is a finite 0 ... 1 and compression
    /// a whole 0 ... 9. Enum and Boolean members are in range by
    /// construction.
    static func validate(_ settings: ExportSettings) -> Bool {
        settings.jpegQuality.isFinite && (0...1).contains(settings.jpegQuality)
            && (0...9).contains(settings.pngCompression)
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
/// compression/transparent color), plus an inline message line. The view
/// owns no panel, filename or engine call — the controller embeds it and
/// reads `settings` after a successful `commitEditing`.
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
    let psdExplanation = NSTextField(wrappingLabelWithString: "")
    let messageLabel = NSTextField(labelWithString: "")
    /// The last readable refusal shown inline; nil while clean.
    private(set) var lastError: String?
    /// The grid's per-format option rows; a format switch hides the
    /// others'.
    private var optionRows: [ExportFormat: [NSGridRow]] = [:]

    init(settings: ExportSettings = ExportSettings()) {
        self.settings = settings
        super.init(frame: .zero)
        buildContent()
        show(settings)
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
        psdExplanation.font = .systemFont(ofSize: 11)
        psdExplanation.textColor = .secondaryLabelColor
        psdExplanation.preferredMaxLayoutWidth = 270
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

        messageLabel.setAccessibilityLabel("Export options message")
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2

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
            [NSGridCell.emptyContentView, psdExplanation],
        ]
        let grid = NSGridView(views:
            [[NSTextField(labelWithString: "Format:"), formatPopup]] + jpegRows + pngRows + tiffRows + psdRows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        optionRows = [
            .jpeg: (1...4).map { grid.row(at: $0) },
            .png: (5...7).map { grid.row(at: $0) },
            .tiff: (8...9).map { grid.row(at: $0) },
            .psd: (10...11).map { grid.row(at: $0) },
        ]
        // Measured with every option row visible, the widest the grid
        // ever lays out; pinning it keeps the form's width stable while
        // format swaps hide and show rows.
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
        psdExplanation.stringValue = settings.psdLayout.explanation
    }

    private func popupIndex<T: Equatable>(of value: T, in choices: [T]) -> Int {
        choices.firstIndex(of: value) ?? 0
    }

    private func applyFormatVisibility() {
        for (format, rows) in optionRows {
            rows.forEach { $0.isHidden = format != settings.format }
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

    // MARK: Actions

    /// Picks `format` programmatically — the same swap a popup pick
    /// makes, reported through `onFormatChange`. No-op when already
    /// current.
    func selectFormat(_ format: ExportFormat) {
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
        let choices = ExportSettings.PsdLayout.allCases
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        settings.psdLayout = choices[sender.indexOfSelectedItem]
        psdExplanation.stringValue = settings.psdLayout.explanation
        clearMessage()
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
        case .tiff, .psd:
            break
        }
        guard ExportSettings.validate(settings) else {
            refuse("The export settings are invalid.")
            return false
        }
        clearMessage()
        return true
    }
}
