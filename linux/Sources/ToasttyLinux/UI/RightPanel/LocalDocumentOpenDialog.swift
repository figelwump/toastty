import CGtk
import CoreState
import Foundation

/// "Open Local File": a `GtkFileDialog` filtered to the formats the local
/// document panel renders (`LocalDocumentClassifier`), starting in the
/// focused terminal's directory. Recently opened documents appear under
/// Recent (GTK's recent manager).
@MainActor
public enum LocalDocumentOpenDialog {
    private final class Box: @unchecked Sendable {
        let completion: @MainActor (String) -> Void
        init(_ completion: @escaping @MainActor (String) -> Void) { self.completion = completion }
    }

    private static let callback: GAsyncReadyCallback = { source, result, data in
        let box = Unmanaged<Box>.fromOpaque(data!).takeRetainedValue()
        var error: UnsafeMutablePointer<GError>?
        let dialog = OpaquePointer(source!)
        let file = gtk_file_dialog_open_finish(dialog, result, &error)
        if let error { g_error_free(error) }
        var path: String?
        if let file {
            if let raw = g_file_get_path(file) {
                path = String(cString: raw)
                g_free(raw)
            }
            g_object_unref(UnsafeMutableRawPointer(file))
        }
        g_object_unref(UnsafeMutableRawPointer(dialog))
        if let path { MainActor.assumeIsolated { box.completion(path) } }
    }

    public static func present(parent: WidgetPtr, initialDirectory: String? = nil, completion: @escaping @MainActor (String) -> Void) {
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, "Open Local File")
        gtk_file_dialog_set_accept_label(dialog, "_Open")
        gtk_file_dialog_set_modal(dialog, 1)

        let filters = g_list_store_new(gtk_file_filter_get_type())!
        let documents = gtk_file_filter_new()!
        gtk_file_filter_set_name(documents, "Documents and Code")
        for suffix in LocalDocumentClassifier.supportedFilenameExtensions {
            gtk_file_filter_add_suffix(documents, suffix)
        }
        for name in LocalDocumentClassifier.supportedExactFileNames {
            gtk_file_filter_add_pattern(documents, name)
        }
        gtk_file_filter_add_pattern(documents, ".env*")
        g_list_store_append(filters, UnsafeMutableRawPointer(documents))
        let markdown = gtk_file_filter_new()!
        gtk_file_filter_set_name(markdown, "Markdown")
        for suffix in ["md", "markdown", "mdown", "mkd"] { gtk_file_filter_add_suffix(markdown, suffix) }
        g_list_store_append(filters, UnsafeMutableRawPointer(markdown))
        let all = gtk_file_filter_new()!
        gtk_file_filter_set_name(all, "All Files")
        gtk_file_filter_add_pattern(all, "*")
        g_list_store_append(filters, UnsafeMutableRawPointer(all))
        gtk_file_dialog_set_filters(dialog, filters)
        gtk_file_dialog_set_default_filter(dialog, documents)
        for filter in [documents, markdown, all] { g_object_unref(UnsafeMutableRawPointer(filter)) }
        g_object_unref(UnsafeMutableRawPointer(filters))

        if let initialDirectory, FileManager.default.fileExists(atPath: initialDirectory) {
            let folder = g_file_new_for_path(initialDirectory)!
            gtk_file_dialog_set_initial_folder(dialog, folder)
            g_object_unref(UnsafeMutableRawPointer(folder))
        }

        let window = gtk_widget_get_root(parent)
        let box = Unmanaged.passRetained(Box(completion)).toOpaque()
        gtk_file_dialog_open(dialog, window.map { cast($0) }, nil, callback, box)
    }
}
