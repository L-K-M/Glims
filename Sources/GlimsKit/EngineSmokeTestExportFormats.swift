import AppKit

@MainActor
extension EngineSmokeTest {
    /// The document's configured PCX, EPS and PDF export, without a save
    /// panel: nothing here may wait for a person.
    static func exerciseExportFormats(_ session: EngineSession, work: URL,
                                      documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(30)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        let image = try session.newImage(width: 600, height: 300)
        let document: ImageDocument
        do { document = try ImageDocument(session: session, image: image, name: "Export formats") }
        catch { try? session.closeImage(image); throw error }
        documents.items.append(document)
        defer {
            var closed = false
            document.closeImageWhenDrained { closed = true }
            wait { closed }
            documents.items.removeAll { $0 === document }
        }
        let undo = document.undoInfo.undoCount
        let dirty = document.hasUnsavedChanges

        for format in [ExportFormat.pcx, .eps, .pdf] {
            let form = ExportOptionsForm()
            form.selectFormat(format)
            let file = work.appendingPathComponent("flat-export." + format.preferredExtension)
            var finished = false
            var failure: Error?
            document.export(to: file, settings: form.settings) { failure = $0; finished = true }
            wait { finished && document.pendingWork == 0 }
            let bytes = (try? Data(contentsOf: file)) ?? Data()
            defer { try? FileManager.default.removeItem(at: file) }

            let written: Bool
            switch format {
            case .pcx: written = bytes.first == 0x0a
            case .eps: written = bytes.range(of: Data("%%BoundingBox: 0 0 144 72".utf8)) != nil
            default:
                let page = CGDataProvider(data: bytes as CFData).flatMap { CGPDFDocument($0) }?.page(at: 1)
                written = page.map { $0.getBoxRect(.mediaBox).size == CGSize(width: 144, height: 72) } == true
            }
            check(finished && failure == nil && written,
                  "\(format.title) exports at the print size: \(failure.map(String.init(describing:)) ?? "no error")")
        }
        check(document.undoInfo.undoCount == undo && document.hasUnsavedChanges == dirty,
              "flat exports add no Undo step and leave the saved state alone")
    }
}
