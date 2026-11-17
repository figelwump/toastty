// Crops the captures of capture-demo-screenshots.py into the published images.
//
// Usage: demo-images <raw directory> <output directory> < layout.json
//   layout.json holds the window's frame and element frames in screen
//   points, as Accessibility reports them, keyed by identifier.

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("demo-images: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: demo-images <raw directory> <output directory> < layout.json") }
let raw = URL(fileURLWithPath: arguments[1])
let out = URL(fileURLWithPath: arguments[2])
guard let layout = try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())
    as? [String: Any] else { fail("layout.json is not an object") }

func rect(_ key: String) -> CGRect? {
    guard let value = layout[key] as? [String: Double],
          let x = value["x"], let y = value["y"], let width = value["width"], let height = value["height"] else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
}

func load(_ name: String) -> CGImage {
    let url = raw.appendingPathComponent(name)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(url.path)") }
    return image
}

func save(_ image: CGImage, _ name: String) {
    let url = out.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
    print("demo-images: \(name) \(image.width)x\(image.height)")
}

guard let window = rect("window") else { fail("layout.json has no window frame") }
// Pixels per point: 2 on a Retina display.
let scale = CGFloat(load("window.png").width) / window.width

/// The part of the window capture that `points` covers, in window points.
func crop(_ image: CGImage, _ points: CGRect) -> CGImage {
    let pixels = CGRect(x: points.minX * scale, y: points.minY * scale,
                        width: points.width * scale, height: points.height * scale).integral
    guard let cropped = image.cropping(to: pixels) else { fail("cannot crop \(points)") }
    return cropped
}

func local(_ screen: CGRect) -> CGRect {
    screen.offsetBy(dx: -window.minX, dy: -window.minY)
}

/// The window capture with transparent rounded corners, as a window looks
/// on screen. The app draws its window as a rectangle.
func rounded(_ image: CGImage, radius: CGFloat) -> CGImage {
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    context.draw(image, in: bounds)
    guard let result = context.makeImage() else { fail("cannot round the corners") }
    return result
}

// The window's corner radius, in points, as macOS draws it.
let cornerRadius: CGFloat = 18
let full = rounded(load("window.png"), radius: cornerRadius * scale)
save(full, "window.png")
for name in ["coordinator-dock.png", "tasks-view.png"] {
    save(rounded(load(name), radius: cornerRadius * scale), name)
}
save(load("quick-entry.png"), "quick-entry.png")

// The sidebar, from the window's top down to the lumen card: it ends just
// above the next project, docs-site (the sidebar numbers projects from 1).
// Its right edge mirrors the segmented control's left margin.
guard let segmentAll = rect("sidebar.segment.all").map(local),
      let segmentNeedsYou = rect("sidebar.segment.needsYou").map(local),
      let docsSite = rect("sidebar.workspace.2").map(local) else { fail("layout.json lacks the sidebar frames") }
let sidebarWidth = segmentNeedsYou.maxX + segmentAll.minX
save(crop(full, CGRect(x: 0, y: 0, width: sidebarWidth, height: docsSite.minY - 6)), "sidebar.png")

// The right panel's top, from its left edge.
guard let rightPanel = rect("right-panel").map(local) else { fail("layout.json lacks the right panel frame") }
save(crop(full, CGRect(x: rightPanel.minX, y: 0, width: window.width - rightPanel.minX, height: 560)), "right-panel.png")
