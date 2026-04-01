import CoreGraphics

enum PanelHeaderSearchLayout {
    static let horizontalPadding: CGFloat = 12
    static let headerHeight: CGFloat = 26
    static let interItemSpacing: CGFloat = 8
    static let regularFieldWidth: CGFloat = 236
    static let minimumNavigationFieldWidth: CGFloat = 132
    static let minimumCloseOnlyFieldWidth: CGFloat = 72
    static let matchLabelWidthThreshold: CGFloat = 188
    static let searchFieldHeight: CGFloat = 22
    static let searchButtonSize: CGFloat = 17
    static let searchButtonSpacing: CGFloat = 2
    static let searchControlsSpacing: CGFloat = 4

    static let maximumSearchBarWidth: CGFloat = regularFieldWidth
        + searchControlsSpacing
        + buttonClusterWidth(buttonCount: 3)

    static let minimumSearchBarWidth: CGFloat = minimumCloseOnlyFieldWidth
        + searchControlsSpacing
        + buttonClusterWidth(buttonCount: 1)

    struct SearchChrome: Equatable, Sendable {
        let fieldWidth: CGFloat
        let showsMatchLabel: Bool
        let showsNavigationButtons: Bool
    }

    // Resolve only the chrome inside the search cluster from the width SwiftUI
    // actually assigned to it. Sibling negotiation stays in WorkspaceView.
    static func resolveSearchChrome(availableWidth: CGFloat) -> SearchChrome {
        let clampedWidth = min(max(availableWidth.rounded(.down), 0), maximumSearchBarWidth)
        let fullButtonWidth = buttonClusterWidth(buttonCount: 3)
        let closeOnlyButtonWidth = buttonClusterWidth(buttonCount: 1)
        let showsNavigationButtons =
            clampedWidth >= minimumNavigationFieldWidth + searchControlsSpacing + fullButtonWidth
        let buttonWidth = showsNavigationButtons ? fullButtonWidth : closeOnlyButtonWidth
        let availableFieldWidth = max(clampedWidth - searchControlsSpacing - buttonWidth, 0).rounded(.down)
        let fieldFloor = showsNavigationButtons
            ? minimumNavigationFieldWidth
            : min(minimumCloseOnlyFieldWidth, availableFieldWidth)
        let fieldWidth = min(regularFieldWidth, max(availableFieldWidth, fieldFloor)).rounded(.down)
        let showsMatchLabel = showsNavigationButtons && fieldWidth >= matchLabelWidthThreshold

        return SearchChrome(
            fieldWidth: fieldWidth,
            showsMatchLabel: showsMatchLabel,
            showsNavigationButtons: showsNavigationButtons
        )
    }

    private static func buttonClusterWidth(buttonCount: Int) -> CGFloat {
        guard buttonCount > 0 else {
            return 0
        }

        return (CGFloat(buttonCount) * searchButtonSize)
            + (CGFloat(max(buttonCount - 1, 0)) * searchButtonSpacing)
    }
}
