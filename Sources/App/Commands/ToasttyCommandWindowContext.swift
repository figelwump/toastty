import Foundation
import SwiftUI

extension FocusedValues {
    var toasttyCommandWindowID: UUID? {
        get { self[ToasttyCommandWindowIDKey.self] }
        set { self[ToasttyCommandWindowIDKey.self] = newValue }
    }
}

private struct ToasttyCommandWindowIDKey: FocusedValueKey {
    typealias Value = UUID
}
