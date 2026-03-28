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

private enum WorkspaceTabAssertionError: Error, CustomStringConvertible {
    case invalidArguments
    case imageLoadFailed(String)
    case assertionFailed(String)

    var description: String {
        switch self {
        case .invalidArguments:
            return "usage: swift scripts/automation/assert-workspace-tabs.swift <two-tabs.png> <two-tabs-hidden-sidebar.png> <nine-tabs.png> <ten-tabs.png>"
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
private let selectedBackground = RGB(hex: 0x0D0D0D)
private let hairline = RGB(hex: 0x1F1F1F)
private let accent = RGB(hex: 0xF5A623)

private let windowWidthPoints = 2300.0
private let sidebarWidthPoints = 180.0
private let sidebarDividerWidthPoints = 1.0
private let tabLeadingPaddingPoints = 6.0
private let topBarHeightPoints = 32.0
private let topBarDividerHeightPoints = 1.0
private let tabBarHeightPoints = 34.0
private let tabStripSearchTopPoints = 18.0
private let tabStripSearchBottomPoints = 50.0
private let tabWidthPoints = 190.0
private let tabHeightPoints = 26.0
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

private func firstTabRun(in image: ImageSampler, rowY: Int) throws -> ClosedRange<Int> {
    try firstTabRun(
        in: image,
        rowY: rowY,
        startSearchX: scaled(
            sidebarWidthPoints + sidebarDividerWidthPoints,
            scale: Double(image.width) / windowWidthPoints
        )
    )
}

private func firstTabRun(in image: ImageSampler, rowY: Int, startSearchX: Int) throws -> ClosedRange<Int> {
    var x = startSearchX
    while x < image.width && isNear(image.color(topX: x, topY: rowY), chromeBackground, tolerance: 10) {
        x += 1
    }
    try assertCondition(x < image.width, "failed to find first tab start at row \(rowY)")
    let start = x

    while x < image.width && !isNear(image.color(topX: x, topY: rowY), chromeBackground, tolerance: 10) {
        x += 1
    }
    try assertCondition(x > start, "failed to find first tab end at row \(rowY)")
    return start...(x - 1)
}

private func nextTabRun(in image: ImageSampler, rowY: Int, after previousRun: ClosedRange<Int>) throws -> ClosedRange<Int> {
    var x = previousRun.upperBound + 1
    while x < image.width && isNear(image.color(topX: x, topY: rowY), chromeBackground, tolerance: 10) {
        x += 1
    }
    try assertCondition(x < image.width, "failed to find next tab start at row \(rowY)")
    let start = x

    while x < image.width && !isNear(image.color(topX: x, topY: rowY), chromeBackground, tolerance: 10) {
        x += 1
    }
    try assertCondition(x > start, "failed to find next tab end at row \(rowY)")
    return start...(x - 1)
}

private func firstAccentRun(in image: ImageSampler, rowY: Int, startSearchX: Int) throws -> ClosedRange<Int> {
    var x = startSearchX
    while x < image.width && !isAccentLike(image.color(topX: x, topY: rowY)) {
        x += 1
    }
    try assertCondition(x < image.width, "failed to find accent band start at row \(rowY)")
    let start = x

    while x < image.width && isAccentLike(image.color(topX: x, topY: rowY)) {
        x += 1
    }
    try assertCondition(x > start, "failed to find accent band end at row \(rowY)")
    return start...(x - 1)
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

private func accentBounds(
    in image: ImageSampler,
    yRange: Range<Int>,
    startSearchX: Int
) throws -> (minX: Int, maxX: Int, count: Int) {
    var minX = image.width
    var maxX = -1
    var count = 0

    for y in yRange {
        for x in startSearchX..<image.width where isAccentLike(image.color(topX: x, topY: y)) {
            minX = min(minX, x)
            maxX = max(maxX, x)
            count += 1
        }
    }

    guard maxX >= minX else {
        throw WorkspaceTabAssertionError.assertionFailed("failed to find selected tab accent pixels")
    }

    return (minX: minX, maxX: maxX, count: count)
}

private func countMatchingPixels(
    in image: ImageSampler,
    xRange: ClosedRange<Int>,
    yRange: ClosedRange<Int>,
    target: RGB,
    tolerance: Int
) -> Int {
    var count = 0
    for y in yRange {
        for x in xRange {
            if isNear(image.color(topX: x, topY: y), target, tolerance: tolerance) {
                count += 1
            }
        }
    }
    return count
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

private func tabFrame(index: Int, scale: Double) -> CGRect {
    let originX = sidebarWidthPoints + sidebarDividerWidthPoints + tabLeadingPaddingPoints
        + Double(index - 1) * (tabWidthPoints + tabSpacingPoints)
    let originY = topBarHeightPoints + topBarDividerHeightPoints + (tabBarHeightPoints - tabHeightPoints)
    return CGRect(
        x: originX * scale,
        y: originY * scale,
        width: tabWidthPoints * scale,
        height: tabHeightPoints * scale
    )
}

private func assertTwoTabScreenshot(path: String) throws {
    let image = try ImageSampler(path: path)
    let scale = Double(image.width) / windowWidthPoints
    let selectedFrame = tabFrame(index: 1, scale: scale)
    let unselectedFrame = tabFrame(index: 2, scale: scale)
    let accentBounds = try accentBounds(
        in: image,
        yRange: scaled(tabStripSearchTopPoints, scale: scale)..<scaled(tabStripSearchBottomPoints, scale: scale),
        startSearchX: scaled(sidebarWidthPoints, scale: scale)
    )

    try assertCondition(
        accentBounds.minX >= Int(selectedFrame.minX),
        "selected tab accent appears before the expected tab frame"
    )
    try assertCondition(
        accentBounds.maxX <= Int(selectedFrame.maxX),
        "selected tab accent extends beyond the expected tab frame"
    )
    try assertCondition(accentBounds.count > scaled(120, scale: scale), "selected tab top accent line is missing")

    let accentBandThickness = max(scaled(2, scale: scale), 2)
    let minX = Int(selectedFrame.minX)
    let maxX = Int(selectedFrame.maxX)
    let maxY = Int(selectedFrame.maxY)

    let bottomAccentPixelCount = countMatchingPixels(
        in: image,
        xRange: minX...maxX,
        yRange: (maxY - accentBandThickness)...maxY,
        target: accent,
        tolerance: 35
    )
    try assertCondition(bottomAccentPixelCount < scaled(20, scale: scale), "selected tab still shows accent on the bottom edge")

    let selectedInteriorCount = countMatchingPixels(
        in: image,
        xRange: (minX + scaled(20, scale: scale))...(maxX - scaled(20, scale: scale)),
        yRange: (maxY - scaled(6, scale: scale))...(maxY - scaled(3, scale: scale)),
        target: selectedBackground,
        tolerance: 10
    )
    try assertCondition(selectedInteriorCount > scaled(180, scale: scale), "selected tab interior does not match the content background")

    let selectedBottomSeamColor = image.color(
        topX: Int(selectedFrame.midX),
        topY: scaled(topBarHeightPoints + topBarDividerHeightPoints + tabBarHeightPoints - 1, scale: scale)
    )
    try assertCondition(
        isNear(selectedBottomSeamColor, selectedBackground, tolerance: 10),
        "selected tab does not cover the tab-strip bottom seam"
    )

    let unselectedBottomSeamColor = image.color(
        topX: Int(unselectedFrame.midX),
        topY: scaled(topBarHeightPoints + topBarDividerHeightPoints + tabBarHeightPoints - 1, scale: scale)
    )
    try assertCondition(
        isNear(unselectedBottomSeamColor, hairline, tolerance: 10),
        "idle tab area no longer shows the tab-strip bottom seam"
    )

    try assertBadgeVisibility(path: path, tabIndex: 2, expectedVisible: true)
}

private func assertHiddenSidebarTwoTabScreenshot(visiblePath: String, hiddenPath: String) throws {
    let visibleImage = try ImageSampler(path: visiblePath)
    let hiddenImage = try ImageSampler(path: hiddenPath)
    let visibleScale = Double(visibleImage.width) / windowWidthPoints
    let hiddenScale = Double(hiddenImage.width) / windowWidthPoints

    let visibleBounds = try accentBounds(
        in: visibleImage,
        yRange: scaled(tabStripSearchTopPoints, scale: visibleScale)..<scaled(tabStripSearchBottomPoints, scale: visibleScale),
        startSearchX: scaled(sidebarWidthPoints, scale: visibleScale)
    )
    let hiddenBounds = try accentBounds(
        in: hiddenImage,
        yRange: scaled(tabStripSearchTopPoints, scale: hiddenScale)..<scaled(tabStripSearchBottomPoints, scale: hiddenScale),
        startSearchX: 0
    )

    try assertCondition(
        hiddenBounds.minX < visibleBounds.minX - scaled(100, scale: hiddenScale),
        "hidden-sidebar tab strip did not shift left enough"
    )
}

private func assertBadgeVisibility(path: String, tabIndex: Int, expectedVisible: Bool) throws {
    let image = try ImageSampler(path: path)
    let scale = Double(image.width) / windowWidthPoints
    let frame = tabFrame(index: tabIndex, scale: scale)
    let slotStartX = Int(frame.maxX) - scaled(tabTrailingPaddingPoints + tabTrailingSlotWidthPoints, scale: scale) + scaled(2, scale: scale)
    let slotEndX = Int(frame.maxX) - scaled(tabTrailingPaddingPoints, scale: scale) - scaled(2, scale: scale)
    let slotTopY = Int(frame.minY) + scaled(6, scale: scale)
    let slotBottomY = Int(frame.maxY) - scaled(6, scale: scale)
    let nonBackgroundPixelCount = countNonBackgroundPixels(
        in: image,
        xRange: slotStartX...slotEndX,
        yRange: slotTopY...slotBottomY,
        background: chromeBackground,
        tolerance: 10
    )

    if expectedVisible {
        try assertCondition(nonBackgroundPixelCount > scaled(12, scale: scale), "expected badge pixels for tab \(tabIndex), but trailing slot looks empty")
    } else {
        try assertCondition(nonBackgroundPixelCount < scaled(6, scale: scale), "expected tab \(tabIndex) trailing slot to be empty, but badge-like pixels are still present")
    }
}

private func assertNineAndTenTabScreenshots(ninePath: String, tenPath: String) throws {
    try assertBadgeVisibility(path: ninePath, tabIndex: 9, expectedVisible: true)
    try assertBadgeVisibility(path: tenPath, tabIndex: 9, expectedVisible: true)
    try assertBadgeVisibility(path: tenPath, tabIndex: 10, expectedVisible: false)
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 4 else {
        throw WorkspaceTabAssertionError.invalidArguments
    }

    try assertTwoTabScreenshot(path: arguments[0])
    try assertHiddenSidebarTwoTabScreenshot(visiblePath: arguments[0], hiddenPath: arguments[1])
    try assertNineAndTenTabScreenshots(ninePath: arguments[2], tenPath: arguments[3])
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
