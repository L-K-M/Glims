import AppKit

enum InkFillValidation {
    struct Rejection: Error, Equatable {
        let message: String
    }

    static func settings(amount: String, opacity: String) -> Result<EngineSession.InkEdit, Rejection> {
        func percent(_ text: String) -> Double? {
            guard !text.isEmpty, !text.contains(where: \.isWhitespace),
                  let value = Double(text), value.isFinite, (0...100).contains(value) else { return nil }
            return value / 100
        }
        guard let ink = percent(amount) else {
            return .failure(Rejection(message: "Enter an ink amount from 0 to 100%."))
        }
        guard let alpha = percent(opacity) else {
            return .failure(Rejection(message: "Enter an opacity from 0 to 100%."))
        }
        return .success(.init(operation: .fill, intensity: 1 - ink, opacity: alpha))
    }
}

@MainActor
enum InkFillForm {
    static func present(in document: ImageDocument, on window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        let channel = document.activeChannel ?? 0
        if let reason = document.inkEditRefusal(channel: channel) {
            document.onError?(reason)
            return
        }
        let controller = InkFillSheetController(document: document, channel: channel, host: window)
        window.beginSheet(controller.panel) { [controller] _ in
            controller.invalidate()
        }
    }
}

/// The host's sheet completion owns this controller until dismissal. Fields
/// never write to the image; only an admitted Fill submits the captured plane.
@MainActor
private final class InkFillSheetController: NSWindowController {
    let panel: NSPanel
    private let imageDocument: ImageDocument
    private let channel: Int32
    private weak var host: NSWindow?
    private let amount = NSTextField(string: "100")
    private let opacity = NSTextField(string: "100")
    private let message = NSTextField(wrappingLabelWithString: "")
    private var closeObserver: NSObjectProtocol?
    private var invalidated = false
    private var accepting = false

    init(document: ImageDocument, channel: Int32, host: NSWindow) {
        self.imageDocument = document
        self.channel = channel
        self.host = host
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 235),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Fill Ink Channel"
        panel.isReleasedWhenClosed = false
        amount.setAccessibilityLabel("Ink amount, percent")
        opacity.setAccessibilityLabel("Fill opacity, percent")
        message.setAccessibilityLabel("Fill validation message")
        message.textColor = .systemRed
        amount.widthAnchor.constraint(equalToConstant: 88).isActive = true
        opacity.widthAnchor.constraint(equalToConstant: 88).isActive = true

        let ink = NSButton(title: "Ink", target: self, action: #selector(useInk(_:)))
        let paper = NSButton(title: "Paper", target: self, action: #selector(usePaper(_:)))
        let presets = NSStackView(views: [ink, paper])
        presets.orientation = .horizontal
        presets.spacing = 8
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Ink amount (%):"), amount, presets],
            [NSTextField(labelWithString: "Opacity (%):"), opacity, NSView()]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10

        let fill = NSButton(title: "Fill", target: self, action: #selector(apply(_:)))
        fill.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, fill])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let explanation = NSTextField(wrappingLabelWithString:
            "Fill the selected area of this ink channel. Without a selection, fill the whole channel. 0% is paper; 100% is full ink.")
        let stack = NSStackView(views: [explanation, grid, message, buttons])
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
            explanation.widthAnchor.constraint(equalToConstant: 370),
            message.widthAnchor.constraint(equalTo: explanation.widthAnchor),
            message.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
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

    private func dismiss() {
        guard !invalidated else { return }
        if host?.attachedSheet === panel { host?.endSheet(panel, returnCode: .cancel) }
        invalidate()
    }

    @objc private func useInk(_ sender: Any?) {
        guard !invalidated, !accepting else { return }
        amount.stringValue = "100"
        message.stringValue = ""
    }

    @objc private func usePaper(_ sender: Any?) {
        guard !invalidated, !accepting else { return }
        amount.stringValue = "0"
        message.stringValue = ""
    }

    @objc private func cancel(_ sender: Any?) { dismiss() }

    @objc private func apply(_ sender: Any?) {
        guard !invalidated, !accepting else { return }
        accepting = true
        defer { accepting = false }
        panel.endEditing(for: nil)
        guard !invalidated else { return }
        if let reason = imageDocument.inkEditRefusal(channel: channel) {
            message.stringValue = reason
            return
        }
        switch InkFillValidation.settings(amount: amount.stringValue, opacity: opacity.stringValue) {
        case .failure(let reason):
            message.stringValue = reason.message
        case .success(let settings):
            if imageDocument.editInk(settings, channel: channel) {
                dismiss()
            } else if !invalidated {
                message.stringValue = imageDocument.inkEditRefusal(channel: channel) ?? "The fill could not start. Try again."
            }
        }
    }
}
