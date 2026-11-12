import AppKit

/// Physical Lab values stay as Doubles until the native edit quantizes them.
/// This parser never trims, clamps, accepts numeric prefixes or converts ink %.
enum LabFillValidation {
    struct Settings: Equatable {
        let value: Double
        let opacity: Double
    }

    struct Rejection: Error, Equatable {
        let message: String
    }

    static func settings(amount: String, opacity: String, role: EngineSession.LabAxisRole,
                         component: EngineSession.ColorComponent) -> Result<Settings, Rejection> {
        guard component == .u8 || component == .u16 || component == .float else {
            return .failure(Rejection(message: "This document precision does not support Lab fills."))
        }
        guard let value = decimal(amount) else {
            return .failure(Rejection(message: "Enter a finite physical value for \(role.title)."))
        }
        if component == .float {
            guard abs(value) <= Double(Float.greatestFiniteMagnitude) else {
                return .failure(Rejection(message: "Enter a physical value within the finite 32-bit float range."))
            }
        } else if !role.nominalRange.contains(value) {
            let range = role == .lightness ? "0 to 100" : "−128 to 127"
            return .failure(Rejection(message: "Enter a physical value from \(range) for \(role.title)."))
        }
        guard let percent = decimal(opacity), (0...100).contains(percent) else {
            return .failure(Rejection(message: "Enter an opacity from 0 to 100%."))
        }
        return .success(Settings(value: value, opacity: percent / 100))
    }

    private static func decimal(_ text: String) -> Double? {
        // ASCII decimal/scientific notation only. Reject the complete draft if
        // it contains whitespace, a suffix, a hex literal or an unfinished exponent.
        let pattern = #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#
        guard !text.isEmpty, !text.contains(where: \.isWhitespace),
              text.range(of: pattern, options: .regularExpression) != nil,
              let value = Double(text), value.isFinite else { return nil }
        return value
    }
}

@MainActor
enum LabFillForm {
    static func present(in document: ImageDocument, on window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        guard let axis = document.selectedLabAxis else {
            document.onError?("Select a Lab channel before filling it.")
            return
        }
        if let reason = document.labFillRefusal(axis: axis) {
            document.onError?(reason)
            return
        }
        let controller = LabFillSheetController(document: document, axis: axis, host: window)
        window.beginSheet(controller.panel) { [controller] _ in
            controller.invalidate()
        }
    }
}

/// The host completion retains the controller until dismissal. Its document and
/// axis identity never follow palette selection or frontmost-window changes.
@MainActor
private final class LabFillSheetController: NSWindowController {
    let panel: NSPanel
    private let imageDocument: ImageDocument
    private let axis: EngineSession.LabAxis
    private let component: EngineSession.ColorComponent
    private weak var host: NSWindow?
    private let amount: NSTextField
    private let opacity = NSTextField(string: "100")
    private let message = NSTextField(wrappingLabelWithString: "")
    private var closeObserver: NSObjectProtocol?
    private var invalidated = false
    private var accepting = false
    private var submitted = false

    init(document: ImageDocument, axis: EngineSession.LabAxis, host: NSWindow) {
        imageDocument = document
        self.axis = axis
        component = document.colorInfo.component
        self.host = host
        amount = NSTextField(string: axis.role == .lightness ? "50" : "0")
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Fill Lab Channel"
        panel.isReleasedWhenClosed = false
        amount.setAccessibilityLabel("\(axis.role.title) physical value")
        opacity.setAccessibilityLabel("Lab fill opacity, percent")
        message.setAccessibilityLabel("Lab fill validation message")
        message.textColor = .systemRed
        amount.widthAnchor.constraint(equalToConstant: 170).isActive = true
        opacity.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let channel = NSTextField(wrappingLabelWithString: axis.name)
        channel.setAccessibilityLabel("Selected Lab channel")
        channel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Channel:"), channel],
            [NSTextField(labelWithString: "\(axis.role.title) value:"), amount],
            [NSTextField(labelWithString: "Opacity (%):"), opacity]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12

        let explanation = NSTextField(wrappingLabelWithString:
            "Fill the selected area of this Lab channel. Without a selection, fill the whole channel.")
        let rangeText = axis.role == .lightness ? "0 to 100" : "−128 to 127"
        let precisionHelp = component == .float
            ? "Enter physical Lab units. This 32-bit float document also accepts finite values outside the nominal \(rangeText) range."
            : "Enter physical Lab units from \(rangeText). The value is converted to the document precision when applied."
        let help = NSTextField(wrappingLabelWithString: precisionHelp)
        help.textColor = .secondaryLabelColor
        help.setAccessibilityLabel("Lab value range")

        let fill = NSButton(title: "Fill", target: self, action: #selector(apply(_:)))
        fill.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, fill])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [explanation, grid, help, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        panel.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            explanation.widthAnchor.constraint(equalToConstant: 420),
            help.widthAnchor.constraint(equalTo: explanation.widthAnchor),
            message.widthAnchor.constraint(equalTo: explanation.widthAnchor),
            message.heightAnchor.constraint(greaterThanOrEqualToConstant: 42)
        ])
        panel.setContentSize(content.fittingSize)
        panel.initialFirstResponder = amount
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        panel.orderOut(nil)
    }

    private func dismiss(_ response: NSApplication.ModalResponse = .cancel) {
        guard !invalidated else { return }
        if host?.attachedSheet === panel { host?.endSheet(panel, returnCode: response) }
        invalidate()
    }

    @objc private func cancel(_ sender: Any?) { dismiss() }

    @objc private func apply(_ sender: Any?) {
        guard !invalidated, !accepting, !submitted else { return }
        accepting = true
        defer { accepting = false }
        panel.endEditing(for: nil)
        guard !invalidated else { return }
        if let reason = imageDocument.labFillRefusal(axis: axis) {
            message.stringValue = reason
            return
        }
        guard imageDocument.colorInfo.component == component else {
            message.stringValue = "The document precision changed. Close this sheet and open Fill again."
            return
        }
        switch LabFillValidation.settings(amount: amount.stringValue, opacity: opacity.stringValue,
                                         role: axis.role, component: component) {
        case .failure(let reason):
            message.stringValue = reason.message
        case .success(let settings):
            if imageDocument.fillLabAxis(axis, value: settings.value, opacity: settings.opacity) {
                submitted = true
                dismiss(.OK)
            } else if !invalidated {
                message.stringValue = imageDocument.labFillRefusal(axis: axis)
                    ?? "The fill could not start. Try again."
            }
        }
    }
}
