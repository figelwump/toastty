import AVFoundation
import ImageIO
import PhotosUI
import RemoteProtocol
import SwiftUI
import UniformTypeIdentifiers

/// The paperclip control that lives inside the composer field's trailing edge.
/// It owns the import flow; `ToasttyAttachmentTray` renders the resulting
/// previews and status above the field.
struct ToasttyAttachmentPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let attachments: [RemoteMessageAttachment]
    let supportsAttachments: Bool
    let allowsInput: Bool
    @Binding var isLoading: Bool
    let addAttachments: ([RemoteMessageAttachment]) -> String?

    @State private var showsChooser = false
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var showsCamera = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var errorMessage: String?
    @State private var importID: UUID?
    @State private var isVisible = true

    /// Matches the composer field's trailing inset so the icon never overlaps text.
    static let buttonSize: CGFloat = 44

    private var canPick: Bool {
        allowsInput && supportsAttachments && !isLoading && attachments.count < RemoteAttachmentPolicy.maximumCount
    }

    var body: some View {
        Button { showsChooser = true } label: {
            Image(systemName: "paperclip")
                .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 24 : 18))
                .frame(width: ToasttyAttachmentPicker.buttonSize, height: ToasttyAttachmentPicker.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(canPick ? ToasttyDesignTokens.secondaryText : ToasttyDesignTokens.mutedText)
        .disabled(!canPick)
        .accessibilityLabel("Attach")
        .accessibilityIdentifier("toastty-mobile-attachment-add")
        .confirmationDialog("Attach to message", isPresented: $showsChooser, titleVisibility: .visible) {
            Button("Photo Library", systemImage: "photo") { showsPhotos = true }
            Button("Take Photo", systemImage: "camera") { requestCamera() }
            Button("Choose File", systemImage: "folder") { showsFiles = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Images, PDFs, and text files. Up to 4 files, 4 MB each, 8 MB total.")
        }
        .photosPicker(isPresented: $showsPhotos, selection: $selectedPhotos,
                      maxSelectionCount: max(1, RemoteAttachmentPolicy.maximumCount - attachments.count), matching: .images)
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            importPhotos(items)
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsCamera) {
            ToasttyAttachmentCamera { result in
                switch result {
                case .success(let data): importCameraPhoto(data)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .ignoresSafeArea()
        }
        .alert("Could not attach file", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            importID = nil
            isLoading = false
        }
    }

    private func requestCamera() {
        guard canPick else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "This device has no available camera. Choose Photo Library or Files instead."
            return
        }
        Task { @MainActor in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard isVisible, canPick else { return }
            if granted { showsCamera = true } else {
                errorMessage = "Camera access is off. Allow camera access for Toastty in Settings, or choose Photo Library or Files."
            }
        }
    }

    private func beginImport(count: Int) -> UUID? {
        guard isVisible, canPick else { return nil }
        guard count <= RemoteAttachmentPolicy.maximumCount - attachments.count else {
            errorMessage = "Attach up to 4 files to one message."
            return nil
        }
        let id = UUID()
        importID = id
        isLoading = true
        return id
    }

    private func finishImport(_ result: Result<[RemoteMessageAttachment], Error>, id: UUID) {
        guard isVisible, importID == id else { return }
        importID = nil
        isLoading = false
        guard allowsInput, supportsAttachments else {
            errorMessage = "The conversation changed while preparing the attachment. Choose it again when input is available."
            return
        }
        switch result {
        case .success(let additions): errorMessage = addAttachments(additions)
        case .failure(let error): errorMessage = error.localizedDescription
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard let id = beginImport(count: items.count) else { selectedPhotos = []; return }
        Task { @MainActor in
            do {
                var additions: [RemoteMessageAttachment] = []
                for item in items {
                    guard let photo = try await item.loadTransferable(type: ToasttyAttachmentPhoto.self) else {
                        throw ToasttyAttachmentLoader.ImportError.invalidImage
                    }
                    additions.append(photo.attachment)
                }
                finishImport(.success(additions), id: id)
            } catch { finishImport(.failure(error), id: id) }
            selectedPhotos = []
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, let id = beginImport(count: urls.count) else { return }
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try urls.map { try ToasttyAttachmentLoader.file(at: $0) } }
            }.value
            finishImport(result, id: id)
        }
    }

    private func importCameraPhoto(_ data: Data) {
        guard let id = beginImport(count: 1) else { return }
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result { [try ToasttyAttachmentLoader.photo(data: data)] }
            }.value
            finishImport(result, id: id)
        }
    }
}

/// Attachment previews and import status, shown above the composer field while
/// there is something to report.
struct ToasttyAttachmentTray: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let attachments: [RemoteMessageAttachment]
    let supportsAttachments: Bool
    let allowsInput: Bool
    let isLoading: Bool
    let removeAttachment: (UUID) -> Void

    static func isVisible(
        attachments: [RemoteMessageAttachment],
        supportsAttachments: Bool,
        allowsInput: Bool,
        isLoading: Bool
    ) -> Bool {
        isLoading || !attachments.isEmpty || (!supportsAttachments && allowsInput)
    }

    private var attachmentRowHeight: CGFloat { dynamicTypeSize.isAccessibilitySize ? 56 : 44 }

    private var attachmentListHeight: CGFloat {
        min(132, CGFloat(attachments.count) * attachmentRowHeight + CGFloat(max(0, attachments.count - 1)) * 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            ToasttyAttachmentRow(attachment: attachment, canRemove: allowsInput && !isLoading) {
                                removeAttachment(attachment.id)
                            }
                        }
                    }
                }
                .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? min(attachmentRowHeight, attachmentListHeight) : attachmentListHeight,
                       idealHeight: attachmentListHeight,
                       maxHeight: attachmentListHeight)
                .layoutPriority(-1)
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.never)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("toastty-mobile-attachment-list")
            }
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing attachment…").font(.caption)
                }
            } else if !supportsAttachments && allowsInput {
                Text("Update Toastty on your Mac to attach files.")
                    .font(.caption)
            } else if !attachments.isEmpty {
                Text(dynamicTypeSize.isAccessibilitySize
                     ? "\(attachments.count)/4"
                     : "\(attachments.count)/4 · Up to 8 MB total")
                    .font(.caption)
                    .accessibilityLabel("\(attachments.count) of 4 attachments. Up to 8 MB total.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(ToasttyDesignTokens.secondaryText)
    }
}

private struct ToasttyAttachmentRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let attachment: RemoteMessageAttachment
    let canRemove: Bool
    let remove: () -> Void
    @State private var thumbnail: UIImage?

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else { Image(systemName: "doc").font(.system(size: 24)) }
            }
            .frame(width: 40, height: 40)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(dynamicTypeSize.isAccessibilitySize ? .caption2 : .caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(dynamicTypeSize.isAccessibilitySize
                        ? "\(attachment.filename), \(formattedSize)" : attachment.filename)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(formattedSize)
                        .font(.caption2).foregroundStyle(ToasttyDesignTokens.secondaryText)
                }
            }
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .frame(width: 44, height: 44)
            }
                .fixedSize()
                .disabled(!canRemove)
                .accessibilityLabel("Remove \(attachment.filename)")
                .accessibilityIdentifier("toastty-mobile-attachment-remove")
        }
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 56 : 44)
        .task(id: attachment.id) {
            let data = attachment.data
            let preview = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return Optional<Data>.none }
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 120
                ] as CFDictionary) else { return Optional<Data>.none }
                let result = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else { return Optional<Data>.none }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { return Optional<Data>.none }
                return result as Data
            }.value
            thumbnail = preview.flatMap(UIImage.init(data:))
        }
    }
}

private struct ToasttyAttachmentCamera: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let completion: (Result<Data, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ToasttyAttachmentCamera
        init(parent: ToasttyAttachmentCamera) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.dismiss()
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.85) else {
                parent.completion(.failure(ToasttyAttachmentLoader.ImportError.invalidImage))
                return
            }
            parent.completion(.success(data))
        }
    }
}
