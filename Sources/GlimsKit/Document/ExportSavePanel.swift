import AppKit
import UniformTypeIdentifiers

/// Keeps the selected format, filename and options together until Export.
/// The sheet's completion retains this object; NSSavePanel's delegate is weak.
@MainActor
final class ExportSavePanel: NSObject, NSOpenSavePanelDelegate {
    let panel = NSSavePanel()
    let form: ExportOptionsForm

    init(baseName: String, settings: ExportSettings) {
        form = ExportOptionsForm(settings: settings)
        super.init()
        panel.title = "Export Image"
        panel.prompt = "Export"
        panel.allowsOtherFileTypes = false
        panel.canSelectHiddenExtension = true
        panel.nameFieldStringValue = baseName + "." + settings.format.preferredExtension
        panel.accessoryView = form
        panel.delegate = self
        setFormat(settings.format)
        form.onFormatChange = { [weak self] format in self?.setFormat(format) }
    }

    private func setFormat(_ format: ExportFormat) {
        let filename = panel.nameFieldStringValue as NSString
        let oldExtension = filename.pathExtension
        let base = ExportFormat.forFileExtension(oldExtension) == nil
            ? String(filename) : filename.deletingPathExtension
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = base + "." + format.preferredExtension
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard form.commitEditing() else {
            throw NSError(domain: "ch.lkmc.Glims.Export", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: form.lastError ?? "Correct the export options."])
        }
    }
}

extension ExportFormat {
    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .psd: return UTType("com.adobe.photoshop-image")!
        }
    }
}
