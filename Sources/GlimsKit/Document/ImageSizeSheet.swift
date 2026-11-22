import AppKit

/// Image > Image Size's sheet content: pixel dimensions, print width and
/// height with a unit, resolution with a unit, Constrain proportions and
/// the Resample image choice with its method. The fields edit one pure
/// `ImageSizeModel`; with Resample off the pixel fields are disabled and
/// the resolution and print size move inversely, with it on the print size
/// and resolution drive the pixels. Cancel changes nothing.
@MainActor
final class ImageSizeForm: NSGridView, NSTextFieldDelegate {
    private(set) var model: ImageSizeModel
    private var printUnit: ImageSizeModel.LengthUnit = .inches
    private var resolutionUnit: ImageSizeModel.ResolutionUnit = .pixelsPerInch
    private(set) var isValid = true
    var onValidityChanged: ((Bool) -> Void)?

    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let printWidthField = NSTextField()
    private let printHeightField = NSTextField()
    private let resolutionField = NSTextField()
    private let printUnitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resolutionUnitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let constrainCheckbox = NSButton(checkboxWithTitle: "Constrain proportions", target: nil, action: nil)
    private let resampleCheckbox = NSButton(checkboxWithTitle: "Resample image", target: nil, action: nil)
    private let resamplePopup = ImageSizeResampling.popUpButton()

    init(model: ImageSizeModel) {
        self.model = model
        super.init(frame: .zero)
        for (field, label) in [(widthField, "Width in pixels"), (heightField, "Height in pixels"),
                               (printWidthField, "Print width"), (printHeightField, "Print height"),
                               (resolutionField, "Resolution")] {
            field.delegate = self
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        }
        widthField.stringValue = String(model.width)
        heightField.stringValue = String(model.height)
        printUnitPopup.setAccessibilityLabel("Print unit")
        printUnitPopup.target = self
        printUnitPopup.action = #selector(printUnitChanged(_:))
        for unit in ImageSizeModel.LengthUnit.allCases {
            printUnitPopup.addItem(withTitle: unit.title)
        }
        printUnitPopup.selectItem(at: ImageSizeModel.LengthUnit.allCases.firstIndex(of: printUnit) ?? 0)
        resolutionUnitPopup.setAccessibilityLabel("Resolution unit")
        resolutionUnitPopup.target = self
        resolutionUnitPopup.action = #selector(resolutionUnitChanged(_:))
        for unit in ImageSizeModel.ResolutionUnit.allCases {
            resolutionUnitPopup.addItem(withTitle: unit.title)
        }
        resolutionUnitPopup.selectItem(at: ImageSizeModel.ResolutionUnit.allCases.firstIndex(of: resolutionUnit) ?? 0)
        constrainCheckbox.target = self
        constrainCheckbox.action = #selector(constrainChanged(_:))
        constrainCheckbox.state = model.constrainProportions ? .on : .off
        resampleCheckbox.target = self
        resampleCheckbox.action = #selector(resampleChanged(_:))
        resampleCheckbox.state = model.resample ? .on : .off

        addRow(with: [NSTextField(labelWithString: "Width (px):"), widthField,
                      NSTextField(labelWithString: "Height (px):"), heightField])
        addRow(with: [NSTextField(labelWithString: "Print width:"), printWidthField,
                      NSTextField(labelWithString: "Print height:"), printHeightField])
        addRow(with: [NSTextField(labelWithString: "Print unit:"), printUnitPopup,
                      NSTextField(labelWithString: "Resolution:"), resolutionField])
        addRow(with: [NSTextField(labelWithString: "Resolution unit:"), resolutionUnitPopup,
                      constrainCheckbox, resampleCheckbox])
        addRow(with: [NSTextField(labelWithString: "Resample method:"), resamplePopup,
                      NSGridCell.emptyContentView, NSGridCell.emptyContentView])
        column(at: 0).xPlacement = .trailing
        column(at: 2).xPlacement = .trailing
        rowSpacing = 8
        columnSpacing = 12
        setFrameSize(fittingSize)
        refresh()
        updateEnabled()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The geometry the sheet will apply.
    var resolution: EngineSession.ImageResolution {
        .init(x: model.resolutionX, y: model.resolutionY)
    }

    var interpolation: EngineSession.Interpolation {
        ImageSizeResampling.interpolation(of: resamplePopup) ?? ImageSizeResampling.defaultInterpolation
    }

    var resample: Bool { model.resample }

    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        return formatter
    }()

    private func format(_ value: Double) -> String {
        Self.decimal.string(from: NSNumber(value: value)) ?? ""
    }

    private func refresh(except field: NSTextField? = nil) {
        if field !== widthField { widthField.stringValue = String(model.width) }
        if field !== heightField { heightField.stringValue = String(model.height) }
        if field !== printWidthField {
            printWidthField.stringValue = format(model.printWidth(in: printUnit))
        }
        if field !== printHeightField {
            printHeightField.stringValue = format(model.printHeight(in: printUnit))
        }
        if field !== resolutionField {
            resolutionField.stringValue = format(model.resolutionX(in: resolutionUnit))
        }
    }

    private func updateEnabled() {
        let resampleOn = model.resample
        widthField.isEnabled = resampleOn
        heightField.isEnabled = resampleOn
        resamplePopup.isEnabled = resampleOn
        constrainCheckbox.isEnabled = resampleOn
    }

    private func setValidity(_ valid: Bool) {
        guard valid != isValid else { return }
        isValid = valid
        onValidityChanged?(valid)
    }

    private func intText(_ field: NSTextField) -> Int? {
        Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func doubleText(_ field: NSTextField) -> Double? {
        Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "."))
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let valid: Bool
        switch field {
        case widthField:
            valid = intText(field).map { model.setPixelWidth($0) } ?? false
        case heightField:
            valid = intText(field).map { model.setPixelHeight($0) } ?? false
        case printWidthField:
            valid = doubleText(field).map { model.setPrintWidth($0, unit: printUnit) } ?? false
        case printHeightField:
            valid = doubleText(field).map { model.setPrintHeight($0, unit: printUnit) } ?? false
        case resolutionField:
            valid = doubleText(field).map { model.setResolution($0, unit: resolutionUnit) } ?? false
        default:
            return
        }
        refresh(except: field)
        setValidity(valid)
    }

    @objc private func printUnitChanged(_ sender: NSPopUpButton) {
        guard ImageSizeModel.LengthUnit.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        printUnit = ImageSizeModel.LengthUnit.allCases[sender.indexOfSelectedItem]
        refresh()
    }

    @objc private func resolutionUnitChanged(_ sender: NSPopUpButton) {
        guard ImageSizeModel.ResolutionUnit.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        resolutionUnit = ImageSizeModel.ResolutionUnit.allCases[sender.indexOfSelectedItem]
        refresh()
    }

    @objc private func constrainChanged(_ sender: NSButton) {
        model.setConstrainProportions(sender.state == .on)
    }

    @objc private func resampleChanged(_ sender: NSButton) {
        model.setResample(sender.state == .on)
        updateEnabled()
        refresh()
    }
}

extension ImageSizeForm {
    /// Presents the sheet on `window`. It captures `document`; Cancel
    /// changes nothing, and OK applies exactly one queued command.
    static func present(for document: ImageDocument, on window: NSWindow) {
        guard window.attachedSheet == nil,
              let resolution = document.resolution,
              let model = ImageSizeModel(width: document.info.width, height: document.info.height,
                                         resolutionX: resolution.x, resolutionY: resolution.y) else { return }
        let form = ImageSizeForm(model: model)
        let alert = NSAlert()
        alert.messageText = "Image Size"
        alert.informativeText = "Change the pixel dimensions, the print size and the resolution. "
            + "With Resample off the pixels stay fixed."
        alert.accessoryView = form
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = form.widthField
        form.onValidityChanged = { valid in alert.buttons.first?.isEnabled = valid }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if form.resample {
                document.resize(toWidth: form.model.width, height: form.model.height,
                                resolution: form.resolution, interpolation: form.interpolation)
            } else {
                document.setResolution(form.resolution)
            }
        }
    }
}
