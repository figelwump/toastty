import CoreState
import Foundation
@testable import ToasttyApp

/// Builds an AnnotationStyleStore rooted in a unique temporary runtime home
/// so tests never touch the developer's real `~/.toastty` state.
@MainActor
func makeTestAnnotationStyleStore() -> AnnotationStyleStore {
    let runtimeHomeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-annotation-style-tests-\(UUID().uuidString)", isDirectory: true)
    return AnnotationStyleStore(
        runtimePaths: ToasttyRuntimePaths.resolve(
            homeDirectoryPath: runtimeHomeURL.path,
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHomeURL.path]
        )
    )
}
