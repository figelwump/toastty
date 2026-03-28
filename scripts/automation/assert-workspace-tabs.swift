import AppKit
import Foundation

private struct RGB {
    let red: Int
    let green: Int
    let blue: Int

    init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: Int) {
        red = (hex >> 16) & 0xFF
        green = (hex >> 8) & 0xFF
        blue = hex & 0xFF
    }
}

private struct HeaderTabSnapshot {
    let image: ImageSampler
    let scale: Double
    let accentRowY: Int
    let accentRun: ClosedRange<Int>
    let selectedTabRun: ClosedRange<Int>
    let tabWidth: Int
    let spacingWidth: Int
    let tabRuns: [ClosedRange<Int>]
}

private enum WorkspaceTabAssertionError: Error, CustomStringConvertible {
    case invalidArguments
    case imageLoadFailed(String)
    case assertionFailed(String)

    var description: String {
        switch self {
        case .invalidArguments:
            return """
                usage: swift scripts/automation/assert-workspace-tabs.swift \
                <single-tab.png> <two-tabs.png> <two-tabs-hidden-sidebar.png> <nine-tabs.png> <ten-tabs.png>
                """
        case .imageLoadFailed(let path):
            return "failed to load image: \(path)"
        case .assertionFailed(let message):
            return message
        }
    }
}

private final class ImageSampler {
    let bitmap: NSBitmapImageRep
    let width: Int
    let height: Int

    init(path: String) throws {
        guard let image = NSImage(contentsOfFile: path),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            throw WorkspaceTabAssertionError.imageLoadFailed(path)
        }
        self.bitmap = bitmap
        width = bitmap.pixelsWide
        height = bitmap.pixelsHigh
    }

    func color(topX x: Int, topY y: Int) -> RGB {
        let clampedX = min(max(x, 0), width - 1)
        let clampedY = min(max(y, 0), height - 1)
        guard let color = bitmap.colorAt(x: clampedX, y: clampedY)?
            .usingColorSpace(.deviceRGB) else {
            return RGB(hex: 0x000000)
        }
        return RGB(
            red: Int(round(color.redComponent * 255)),
            green: Int(round(color.greenComponent * 255)),
            blue: Int(round(color.blueComponent * 255))
        )
    }
}

private let chromeBackground = RGB(hex: 0x111111)
private let selectedBackground = RGB(hex: 0x1A1A1A)
private let hairline = RGB(hex: 0x1F1F1F)

private let windowWidthPoints = 2300.0
private let topBarHeightPoints = 37.0
private let tabHeightPoints = 34.0
private let tabSpacingPoints = 6.0
private let tabTrailingPaddingPoints = 10.0
private let tabTrailingSlotWidthPoints = 24.0

private extension ClosedRange<Int> {
    var length: Int { upperBound - lowerBound + 1 }
}

private func maxChannelDistance(_ lhs: RGB, _ rhs: RGB) -> Int {
    max(
        abs(lhs.red - rhs.red),
        abs(lhs.green - rhs.green),
        abs(lhs.blue - rhs.blue)
    )
}

private func isNear(_ lhs: RGB, _ rhs: RGB, tolerance: Int) -> Bool {
    maxChannelDistance(lhs, rhs) <= tolerance
}

private func isAccentLike(_ color: RGB) -> Bool {
    color.red >= 145 &&
    color.green >= 110 &&
    color.blue >= 40 &&
    color.red > color.green &&
    color.green > color.blue
}

private func scaled(_ points: Double, scale: Double) -> Int {
    Int(round(points * scale))
}

private func assertCondition(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw WorkspaceTabAssertionError.assertionFailed(message)
    }
}

private func longestAccentRun(
    in image: ImageSampler,
    yRange: Range<Int>,
    startSearchX: Int
) throws -> (rowY: Int, run: ClosedRange<Int>) {
    var best: (rowY: Int, run: ClosedRange<Int>)?

    for y in yRange {
        var x = startSearchX
        while x < image.width {
            while x < image.width && !isAccentLike(image.color(topX: x, topY: y)) {
                x += 1
            }
            guard x < image.width else { break }
            let start = x
            while x < image.width && isAccentLike(image.color(topX: x, topY: y)) {
                x += 1
            }
            let run = start...(x - 1)
            if let currentBest = best {
                if run.length > currentBest.run.length {
                    best = (rowY: y, run: run)
                }
            } else {
                best = (rowY: y, run: run)
            }
        }
    }

    guard let best else {
        throw WorkspaceTabAssertionError.assertionFailed("failed to find selected tab accent band")
    }
    return best
}

private func tabRun(
    in image: ImageSampler,
    rowY: Int,
    seedX: Int
) throws -> ClosedRange<Int> {
    var start = seedX
    while start >= 0 && !isNear(image.color(topX: start, topY: rowY), chromeBackground, tolerance: 10) {
        start -= 1
    }
    start += 1

    var end = seedX
    while end < image.width && !isNear(image.color(topX: end, topY: rowY), chromeBackground, tolerance: 10) {
        end += 1
    }
    end -= 1

    try assertCondition(end >= start, "failed to resolve tab bounds at row \(rowY)")
    return start...end
}

private func headerTabSnapshot(path: String, expectedTabCount: Int) throws -> HeaderTabSnapshot {
    let image = try ImageSampler(path: path)
    let scale = Double(image.width) / windowWidthPoints
    let accentSearchBottomY = max(scaled(12, scale: scale), 4)
    let accent = try longestAccentRun(
        in: image,
        yRange: 0..<min(accentSearchBottomY, image.height),
        startSearchX: 0
    )
    let rowY = min(
        image.height - 1,
        max(accent.rowY + scaled(10, scale: scale), scaled(tabHeightPoints - 6, scale: scale))
    )
    let firstRun = try tabRun(
        in: image,
        rowY: rowY,
        seedX: (accent.run.lowerBound + accent.run.upperBound) / 2
    )
    let spacingWidth = scaled(tabSpacingPoints, scale: scale)
    let tabWidth = firstRun.length
    let runs = (0..<expectedTabCount).map { index in
        let start = firstRun.lowerBound + index * (tabWidth + spacingWidth)
        return start...(start + tabWidth - 1)
    }

    return HeaderTabSnapshot(
        image: image,
        scale: scale,
        accentRowY: accent.rowY,
        accentRun: accent.run,
        selectedTabRun: firstRun,
        tabWidth: tabWidth,
        spacingWidth: spacingWidth,
        tabRuns: runs
    )
}

private func countNonBackgroundPixels(
    in image: ImageSampler,
    xRange: ClosedRange<Int>,
    yRange: ClosedRange<Int>,
    background: RGB,
    tolerance: Int
) -> Int {
    var count = 0
    for y in yRange {
        for x in xRange {
            if !isNear(image.color(topX: x, topY: y), background, tolerance: tolerance) {
                count += 1
            }
        }
    }
    return count
}

private func assertSingleTabScreenshot(path: String) throws {
    let snapshot = try headerTabSnapshot(path: path, expectedTabCount: 1)
    let run = snapshot.selectedTabRun
    try assertCondition(snapshot.tabWidth > scaled(100, scale: snapshot.scale), "single visible tab is unexpectedly narrow")
    try assertCondition(
        snapshot.accentRun.lowerBound >= run.lowerBound && snapshot.accentRun.upperBound <= run.upperBound,
        "single-tab accent band is not contained within the tab bounds"
    )

    let selectedBottomColor = snapshot.image.color(
        topX: (run.lowerBound + run.upperBound) / 2,
        topY: min(snapshot.image.height - 1, scaled(topBarHeightPoints - 1, scale: snapshot.scale))
    )
    try assertCondition(
        isNear(selectedBottomColor, selectedBackground, tolerance: 10),
        "single selected tab no longer covers the header bottom seam"
    )
}

private func assertTwoTabScreenshot(path: String) throws -> HeaderTabSnapshot {
    let snapshot = try headerTabSnapshot(path: path, expectedTabCount: 2)
    let image = snapshot.image
    let scale = snapshot.scale
    let selectedRun = snapshot.selectedTabRun
    let unselectedRun = snapshot.tabRuns[1]

    try assertCondition(
        snapshot.accentRun.lowerBound >= selectedRun.lowerBound &&
            snapshot.accentRun.upperBound <= selectedRun.upperBound,
        "selected tab accent extends outside the first tab bounds"
    )
    try assertCondition(snapshot.accentRun.length > scaled(120, scale: scale), "selected tab top accent line is missing")

    let seamY = min(image.height - 1, scaled(topBarHeightPoints - 1, scale: scale))
    let selectedBottomSeamColor = image.color(
        topX: (selectedRun.lowerBound + selectedRun.upperBound) / 2,
        topY: seamY
    )
    try assertCondition(
        isNear(selectedBottomSeamColor, selectedBackground, tolerance: 10),
        "selected header tab does not cover the header bottom seam"
    )

    let unselectedBottomSeamColor = image.color(
        topX: (unselectedRun.lowerBound + unselectedRun.upperBound) / 2,
        topY: seamY
    )
    try assertCondition(
        isNear(unselectedBottomSeamColor, hairline, tolerance: 12),
        "idle header tab area no longer shows the header seam"
    )

    let panelHeaderContinuityColor = image.color(
        topX: (selectedRun.lowerBound + selectedRun.upperBound) / 2,
        topY: min(image.height - 1, scaled(topBarHeightPoints + 2, scale: scale))
    )
    try assertCondition(
        isNear(panelHeaderContinuityColor, selectedBackground, tolerance: 10),
        "panel header no longer visually connects with the selected tab"
    )

    try assertBadgeVisibility(snapshot: snapshot, tabIndex: 2, expectedVisible: true)
    return snapshot
}

private func assertHiddenSidebarTwoTabScreenshot(visible: HeaderTabSnapshot, hiddenPath: String) throws {
    let hidden = try headerTabSnapshot(path: hiddenPath, expectedTabCount: 2)
    try assertCondition(
        hidden.tabRuns[0].lowerBound < visible.tabRuns[0].lowerBound - scaled(70, scale: hidden.scale),
        "hidden-sidebar header tabs did not shift left enough"
    )
}

private func assertBadgeVisibility(
    snapshot: HeaderTabSnapshot,
    tabIndex: Int,
    expectedVisible: Bool
) throws {
    let image = snapshot.image
    let scale = snapshot.scale
    let frame = snapshot.tabRuns[tabIndex - 1]
    let slotStartX = frame.upperBound - scaled(tabTrailingPaddingPoints + tabTrailingSlotWidthPoints, scale: scale) + scaled(2, scale: scale)
    let slotEndX = frame.upperBound - scaled(tabTrailingPaddingPoints, scale: scale) - scaled(2, scale: scale)
    let slotTopY = min(image.height - 1, scaled(6, scale: scale))
    let slotBottomY = min(image.height - 1, scaled(tabHeightPoints - 6, scale: scale))
    let nonBackgroundPixelCount = countNonBackgroundPixels(
        in: image,
        xRange: slotStartX...slotEndX,
        yRange: slotTopY...slotBottomY,
        background: chromeBackground,
        tolerance: 10
    )

    if expectedVisible {
        try assertCondition(
            nonBackgroundPixelCount > scaled(12, scale: scale),
            "expected badge pixels for tab \(tabIndex), but trailing slot looks empty"
        )
    } else {
        try assertCondition(
            nonBackgroundPixelCount < scaled(6, scale: scale),
            "expected tab \(tabIndex) trailing slot to be empty, but badge-like pixels are still present"
        )
    }
}

private func assertNineAndTenTabScreenshots(
    ninePath: String,
    tenPath: String,
    referenceTwoTabSnapshot: HeaderTabSnapshot
) throws {
    let nine = try headerTabSnapshot(path: ninePath, expectedTabCount: 9)
    let ten = try headerTabSnapshot(path: tenPath, expectedTabCount: 10)

    try assertCondition(
        ten.tabWidth < referenceTwoTabSnapshot.tabWidth,
        "ten-tab header did not compress tabs relative to the two-tab layout"
    )
    try assertCondition(
        abs(nine.tabRuns[1].lowerBound - nine.tabRuns[0].upperBound - 1 - nine.spacingWidth) <= 3,
        "compressed tabs no longer preserve the expected inter-tab spacing"
    )

    try assertBadgeVisibility(snapshot: nine, tabIndex: 9, expectedVisible: true)
    try assertBadgeVisibility(snapshot: ten, tabIndex: 9, expectedVisible: true)
    try assertBadgeVisibility(snapshot: ten, tabIndex: 10, expectedVisible: false)

    try assertCondition(
        ten.accentRun.length >= max(ten.tabWidth - scaled(6, scale: ten.scale), scaled(80, scale: ten.scale)),
        "selected compressed tab accent line is missing"
    )
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 5 else {
        throw WorkspaceTabAssertionError.invalidArguments
    }

    try assertSingleTabScreenshot(path: arguments[0])
    let twoTabSnapshot = try assertTwoTabScreenshot(path: arguments[1])
    try assertHiddenSidebarTwoTabScreenshot(visible: twoTabSnapshot, hiddenPath: arguments[2])
    try assertNineAndTenTabScreenshots(
        ninePath: arguments[3],
        tenPath: arguments[4],
        referenceTwoTabSnapshot: twoTabSnapshot
    )
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
