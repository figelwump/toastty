import CoreGraphics

struct PanelHeaderSearchLayout: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case regular
        case compact
        case tight
    }

    static let horizontalPadding: CGFloat = 12
    static let interItemSpacing: CGFloat = 8
    static let regularFieldWidth: CGFloat = 196
    static let minimumFieldWidth: CGFloat = 132
    static let matchLabelWidthThreshold: CGFloat = 156
    static let titleMinimumWidth: CGFloat = 64
    private static let indicatorReservedWidth: CGFloat = 16
    private static let profileBadgeReservedWidth: CGFloat = 96
    private static let searchButtonsReservedWidth: CGFloat = 60
    private static let searchClusterSpacing: CGFloat = 6

    let mode: Mode
    let fieldWidth: CGFloat
    let showsMatchLabel: Bool
    let showsProfileBadge: Bool

    static func resolve(
        availableWidth: CGFloat,
        hasProfileBadge: Bool,
        showsIndicator: Bool
    ) -> Self {
        let contentWidth = max(availableWidth - (horizontalPadding * 2), 0)
        let leadingReserve = titleMinimumWidth
            + (showsIndicator ? indicatorReservedWidth : 0)
        let searchChromeWidth = searchButtonsReservedWidth + searchClusterSpacing
        let profileReserve = hasProfileBadge
            ? profileBadgeReservedWidth + interItemSpacing
            : 0
        let showsProfileBadge = hasProfileBadge
            && contentWidth >= leadingReserve + profileReserve + searchChromeWidth + regularFieldWidth
        let availableFieldWidth = contentWidth
            - leadingReserve
            - (showsProfileBadge ? profileReserve : 0)
            - searchChromeWidth
        let fieldWidth = min(
            regularFieldWidth,
            max(availableFieldWidth, minimumFieldWidth)
        ).rounded(.down)
        let showsMatchLabel = fieldWidth >= matchLabelWidthThreshold

        let mode: Mode
        if fieldWidth >= regularFieldWidth {
            mode = .regular
        } else if showsMatchLabel {
            mode = .compact
        } else {
            mode = .tight
        }

        return Self(
            mode: mode,
            fieldWidth: fieldWidth,
            showsMatchLabel: showsMatchLabel,
            showsProfileBadge: showsProfileBadge
        )
    }
}
