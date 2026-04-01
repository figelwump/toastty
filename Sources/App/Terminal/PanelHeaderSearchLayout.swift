import CoreGraphics

struct PanelHeaderSearchLayout: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case regular
        case compact
        case tight
    }

    static let horizontalPadding: CGFloat = 12
    static let headerHeight: CGFloat = 26
    static let interItemSpacing: CGFloat = 8
    static let regularFieldWidth: CGFloat = 220
    static let minimumFieldWidth: CGFloat = 132
    static let matchLabelWidthThreshold: CGFloat = 156
    static let titleMinimumWidth: CGFloat = 64
    static let searchFieldHeight: CGFloat = 22
    static let searchButtonSize: CGFloat = 17
    static let searchButtonSpacing: CGFloat = 2
    static let searchControlsSpacing: CGFloat = 4
    private static let indicatorReservedWidth: CGFloat = 16
    private static let profileBadgeReservedWidth: CGFloat = 96
    private static let searchButtonsReservedWidth: CGFloat =
        (searchButtonSize * 3) + (searchButtonSpacing * 2)
    private static let searchClusterSpacing: CGFloat = searchControlsSpacing

    let mode: Mode
    let fieldWidth: CGFloat
    let showsMatchLabel: Bool
    let showsProfileBadge: Bool
    let showsTitle: Bool

    static func resolve(
        availableWidth: CGFloat,
        hasProfileBadge: Bool,
        showsIndicator: Bool
    ) -> Self {
        let contentWidth = max(availableWidth - (horizontalPadding * 2), 0)
        let searchChromeWidth = searchButtonsReservedWidth + searchClusterSpacing
        let indicatorReserve = showsIndicator ? indicatorReservedWidth : 0
        let profileReserve = hasProfileBadge
            ? profileBadgeReservedWidth + interItemSpacing
            : 0
        let titleReserve = titleMinimumWidth
        let minimumSearchClusterWidth = searchChromeWidth + minimumFieldWidth
        let showsProfileBadge = hasProfileBadge
            && contentWidth >= indicatorReserve + titleReserve + profileReserve + searchChromeWidth + regularFieldWidth
        let showsTitle = contentWidth >= indicatorReserve
            + (showsProfileBadge ? profileReserve : 0)
            + titleReserve
            + minimumSearchClusterWidth
        let leadingReserve = indicatorReserve + (showsTitle ? titleReserve : 0)
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
            showsProfileBadge: showsProfileBadge,
            showsTitle: showsTitle
        )
    }
}
