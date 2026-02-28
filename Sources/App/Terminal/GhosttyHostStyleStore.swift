import SwiftUI

struct GhosttyHostColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    static let black = GhosttyHostColor(red: 0, green: 0, blue: 0)
}

struct GhosttyUnfocusedSplitStyle: Equatable, Sendable {
    /// Opacity applied to the host fill overlay for unfocused split panes.
    let fillOverlayOpacity: Double
    let fillColor: GhosttyHostColor

    static let disabled = GhosttyUnfocusedSplitStyle(fillOverlayOpacity: 0, fillColor: .black)
}

@MainActor
final class GhosttyHostStyleStore: ObservableObject {
    static let shared = GhosttyHostStyleStore()

    @Published private(set) var unfocusedSplitStyle = GhosttyUnfocusedSplitStyle.disabled

    private init() {}

    func setUnfocusedSplitStyle(_ style: GhosttyUnfocusedSplitStyle) {
        unfocusedSplitStyle = style
    }
}
