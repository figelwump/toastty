#if DEBUG
import SwiftUI
import UniformTypeIdentifiers

struct ToasttyComposerTraceExport: View {
    let trace: ToasttyComposerTrace
    @State private var document: ToasttyComposerTraceDocument?
    @State private var filename = "Toastty-typing-trace"
    @State private var showsError = false

    var body: some View {
        Button("Save typing trace") {
            do {
                // Copy and encode only after typing has stopped. Later events
                // cannot change the file being saved.
                let snapshot = trace.snapshot()
                document = try ToasttyComposerTraceDocument(data: snapshot.encoded())
                filename = "Toastty-typing-trace-\(Int(snapshot.capturedAt.timeIntervalSince1970))"
            } catch {
                showsError = true
            }
        }
        .accessibilityIdentifier("toastty-mobile-save-typing-trace")
        .fileExporter(
            isPresented: Binding(
                get: { document != nil },
                set: { if !$0 { document = nil } }
            ), document: document, contentTypes: [.json], defaultFilename: filename,
            onCompletion: { result in
                document = nil
                if case .failure = result { showsError = true }
            },
            onCancellation: { document = nil }
        )
        .alert("Could not save typing trace", isPresented: $showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try saving the trace again.")
        }

        Text("Start a fresh app run and use filler text for this test. Take a screenshot when the underline appears, then save the trace. The trace contains typing times, text lengths, selection ranges, layout measurements, and app and iOS versions. Review the screenshot before sharing it.")
            .font(.footnote)
            .foregroundStyle(ToasttyDesignTokens.mutedText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ToasttyComposerTraceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
