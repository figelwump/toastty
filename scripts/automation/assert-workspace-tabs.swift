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
            return "usage: swift scripts/automation/assert-workspace-tabs.swift <two-tabs.png> <nine-tabs.png> <ten-tabs.png>"
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
private let selectedBackground = RGB(hex: 0x222222)
private let unselectedBackground = RGB(hex: 0x161616)
private let accent = RGB(hex: 0xF5A623)

private let windowWidthPoints = 2300.0
private let sidebarWidthPoints = 180.0
private let sidebarDividerWidthPoints = 1.0
private let tabLeadingPaddingPoints = 6.0
private let topBarHeightPoints = 32.0
private let topBarDividerHeightPoints = 1.0
private let tabBarVerticalPaddingPoints = 4.0
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
    color.red >= 200 &&
    color.green >= 140 &&
    color.blue >= 30 &&
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
    let startSearchX = scaled(sidebarWidthPoints + sidebarDividerWidthPoints, scale: Double(image.width) / windowWidthPoints)
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
    let originY = topBarHeightPoints + topBarDividerHeightPoints + tabBarVerticalPaddingPoints
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
    let rowY = scaled(topBarHeightPoints + topBarDividerHeightPoints + tabBarVerticalPaddingPoints + tabHeightPoints - 4, scale: scale)

    let expectedStartX = scaled(sidebarWidthPoints + sidebarDividerWidthPoints + tabLeadingPaddingPoints, scale: scale)
    let expectedTabWidth = scaled(tabWidthPoints, scale: scale)
    let expectedSpacing = scaled(tabSpacingPoints, scale: scale)

    let firstRun = try firstTabRun(in: image, rowY: rowY)
    let secondRun = try nextTabRun(in: image, rowY: rowY, after: firstRun)

    try assertCondition(abs(firstRun.lowerBound - expectedStartX) <= scaled(3, scale: scale), "first tab is not shifted far enough left")
    try assertCondition(abs(firstRun.length - expectedTabWidth) <= scaled(3, scale: scale), "first tab width does not match expected fixed width")
    try assertCondition(abs(secondRun.length - expectedTabWidth) <= scaled(3, scale: scale), "second tab width does not match expected fixed width")
    try assertCondition(abs(secondRun.lowerBound - firstRun.upperBound - 1 - expectedSpacing) <= scaled(2, scale: scale), "tab spacing does not match expected layout")

    let selectedFrame = tabFrame(index: 1, scale: scale)
    let borderBandThickness = max(Int(round(scale)) + 1, 3)
    let minX = Int(selectedFrame.minX)
    let maxX = Int(selectedFrame.maxX)
    let minY = Int(selectedFrame.minY)
    let maxY = Int(selectedFrame.maxY)
    var accentPixelCount = 0

    for y in minY...(minY + borderBandThickness) {
        for x in minX...maxX where isAccentLike(image.color(topX: x, topY: y)) {
            accentPixelCount += 1
        }
    }

    for y in (maxY - borderBandThickness)...maxY {
        for x in minX...maxX where isAccentLike(image.color(topX: x, topY: y)) {
            accentPixelCount += 1
        }
    }

    for x in minX...(minX + borderBandThickness) {
        for y in minY...maxY where isAccentLike(image.color(topX: x, topY: y)) {
            accentPixelCount += 1
        }
    }

    for x in (maxX - borderBandThickness)...maxX {
        for y in minY...maxY where isAccentLike(image.color(topX: x, topY: y)) {
            accentPixelCount += 1
        }
    }

    try assertCondition(accentPixelCount > scaled(120, scale: scale), "selected tab border does not use the accent color")
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
        background: unselectedBackground,
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
    guard arguments.count == 3 else {
        throw WorkspaceTabAssertionError.invalidArguments
    }

    try assertTwoTabScreenshot(path: arguments[0])
    try assertNineAndTenTabScreenshots(ninePath: arguments[1], tenPath: arguments[2])
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
