import Foundation
import RemoteProtocol

// Linux replacement for Sources/App/RemoteAccess/RemoteAccessPairingQRCode.swift,
// which renders through CoreImage's CIQRCodeGenerator. Same API and
// behavior: byte-mode QR code, error correction level M, the smallest
// version that fits, rendered as an RGBA bitmap (`NSImage.bitmap`, PNG via
// `NSImage.pngData`) the GTK frontend can show with GdkTexture.

/// First-party QR rendering for the native pairing offer. The source payload
/// remains an in-memory value owned by the pairing view; callers must not use
/// it as an accessibility label, log field, URL, or diagnostic attachment.
@MainActor
enum RemoteAccessPairingQRCode {
    /// Quiet zone in modules (CIQRCodeGenerator uses a one-module margin;
    /// the QR spec asks for four, which phone cameras handle best).
    static let quietZoneModules = 4

    static func image(payload: String, scale: CGFloat = 8) -> NSImage? {
        let data = Data(payload.utf8)
        guard data.isEmpty == false,
              data.count <= RemoteNativePairingQRPayload.maximumEncodedByteCount,
              scale >= 1,
              let code = QRCodeEncoder.encode(bytes: [UInt8](data)) else {
            return nil
        }
        let moduleScale = max(1, Int(scale.rounded(.down)))
        let bitmap = code.bitmap(moduleScale: moduleScale, quietZone: quietZoneModules)
        return NSImage(bitmap: bitmap)
    }
}

enum RemoteAccessPairingPresentation {
    static func expiryLabel(expiresAt: Date, at date: Date) -> String {
        let remaining = max(0, Int(ceil(expiresAt.timeIntervalSince(date))))
        return "Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))"
    }
}

@MainActor
enum RemoteAccessPairingClipboard {
    @discardableResult
    static func copy(_ code: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(code, forType: .string)
    }
}

/// A QR code symbol: `size` x `size` modules, `true` is dark.
struct QRCodeSymbol: Equatable {
    let version: Int
    let size: Int
    let mask: Int
    let modules: [[Bool]]

    func bitmap(moduleScale: Int, quietZone: Int) -> LinuxBitmap {
        let side = (size + quietZone * 2) * moduleScale
        var rgba = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<size {
            for x in 0..<size where modules[y][x] {
                for py in 0..<moduleScale {
                    let row = (quietZone + y) * moduleScale + py
                    for px in 0..<moduleScale {
                        let column = (quietZone + x) * moduleScale + px
                        let offset = (row * side + column) * 4
                        rgba[offset] = 0
                        rgba[offset + 1] = 0
                        rgba[offset + 2] = 0
                    }
                }
            }
        }
        return LinuxBitmap(width: side, height: side, rgba: rgba)
    }
}

/// QR Code Model 2 encoder (ISO/IEC 18004), byte mode, ECC level M.
/// Follows the reference structure of Project Nayuki's QR Code generator.
enum QRCodeEncoder {
    // Index 0 is unused; indexes are versions 1...40. Error correction level M.
    private static let eccCodewordsPerBlock: [Int] = [
        -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
        26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28,
    ]
    private static let errorCorrectionBlocks: [Int] = [
        -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
        17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49,
    ]

    static func encode(bytes: [UInt8]) -> QRCodeSymbol? {
        for version in 1...40 {
            let countBits = version <= 9 ? 8 : 16
            guard bytes.count < (1 << countBits) else { continue }
            let capacityBits = dataCodewordCount(version: version) * 8
            let usedBits = 4 + countBits + bytes.count * 8
            guard usedBits <= capacityBits else { continue }
            return makeSymbol(version: version, bytes: bytes, countBits: countBits, capacityBits: capacityBits)
        }
        return nil
    }

    private static func makeSymbol(version: Int, bytes: [UInt8], countBits: Int, capacityBits: Int) -> QRCodeSymbol {
        var bits = BitBuffer()
        bits.append(0b0100, count: 4) // byte mode
        bits.append(bytes.count, count: countBits)
        for byte in bytes {
            bits.append(Int(byte), count: 8)
        }
        bits.append(0, count: min(4, capacityBits - bits.count))
        bits.append(0, count: (8 - bits.count % 8) % 8)
        var padByte = 0xEC
        while bits.count < capacityBits {
            bits.append(padByte, count: 8)
            padByte ^= 0xEC ^ 0x11
        }
        let dataCodewords = bits.bytes()
        let codewords = addErrorCorrectionAndInterleave(dataCodewords, version: version)

        var grid = ModuleGrid(version: version)
        grid.drawFunctionPatterns()
        grid.drawCodewords(codewords)

        var bestMask = 0
        var bestPenalty = Int.max
        for mask in 0..<8 {
            var candidate = grid
            candidate.applyMask(mask)
            candidate.drawFormatBits(mask: mask)
            let penalty = candidate.penaltyScore()
            if penalty < bestPenalty {
                bestPenalty = penalty
                bestMask = mask
            }
        }
        grid.applyMask(bestMask)
        grid.drawFormatBits(mask: bestMask)
        return QRCodeSymbol(version: version, size: grid.size, mask: bestMask, modules: grid.modules)
    }

    static func rawDataModuleCount(version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let alignmentCount = version / 7 + 2
            result -= (25 * alignmentCount - 10) * alignmentCount - 55
            if version >= 7 {
                result -= 36
            }
        }
        return result
    }

    static func dataCodewordCount(version: Int) -> Int {
        rawDataModuleCount(version: version) / 8
            - eccCodewordsPerBlock[version] * errorCorrectionBlocks[version]
    }

    private static func addErrorCorrectionAndInterleave(_ data: [UInt8], version: Int) -> [UInt8] {
        let blockCount = errorCorrectionBlocks[version]
        let eccLength = eccCodewordsPerBlock[version]
        let rawCodewords = rawDataModuleCount(version: version) / 8
        let shortBlockCount = blockCount - rawCodewords % blockCount
        let shortBlockLength = rawCodewords / blockCount
        let divisor = ReedSolomon.divisor(degree: eccLength)

        var blocks: [[UInt8]] = []
        var offset = 0
        for index in 0..<blockCount {
            let length = shortBlockLength - eccLength + (index < shortBlockCount ? 0 : 1)
            var block = Array(data[offset..<(offset + length)])
            offset += length
            let ecc = ReedSolomon.remainder(block, divisor: divisor)
            if index < shortBlockCount {
                block.append(0)
            }
            blocks.append(block + ecc)
        }

        var result: [UInt8] = []
        result.reserveCapacity(rawCodewords)
        for column in 0..<blocks[0].count {
            for (index, block) in blocks.enumerated() {
                if column != shortBlockLength - eccLength || index >= shortBlockCount {
                    result.append(block[column])
                }
            }
        }
        return result
    }
}

private struct BitBuffer {
    private(set) var bits: [Bool] = []
    var count: Int { bits.count }

    mutating func append(_ value: Int, count: Int) {
        guard count > 0 else { return }
        for shift in stride(from: count - 1, through: 0, by: -1) {
            bits.append((value >> shift) & 1 == 1)
        }
    }

    func bytes() -> [UInt8] {
        var result = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (index, bit) in bits.enumerated() where bit {
            result[index >> 3] |= UInt8(1 << (7 - (index & 7)))
        }
        return result
    }
}

private enum ReedSolomon {
    static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z: Int = 0
        for shift in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> shift) & 1) * Int(x)
        }
        return UInt8(z & 0xFF)
    }

    static func divisor(degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for index in 0..<degree {
                result[index] = multiply(result[index], root)
                if index + 1 < degree {
                    result[index] ^= result[index + 1]
                }
            }
            root = multiply(root, 0x02)
        }
        return result
    }

    static func remainder(_ data: [UInt8], divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for index in 0..<result.count {
                result[index] ^= multiply(divisor[index], factor)
            }
        }
        return result
    }
}

private struct ModuleGrid {
    let version: Int
    let size: Int
    var modules: [[Bool]]
    var isFunction: [[Bool]]

    init(version: Int) {
        self.version = version
        size = version * 4 + 17
        modules = Array(repeating: Array(repeating: false, count: size), count: size)
        isFunction = modules
    }

    mutating func setFunction(_ x: Int, _ y: Int, _ dark: Bool) {
        modules[y][x] = dark
        isFunction[y][x] = true
    }

    mutating func drawFunctionPatterns() {
        for index in 0..<size {
            setFunction(6, index, index % 2 == 0)
            setFunction(index, 6, index % 2 == 0)
        }
        drawFinderPattern(3, 3)
        drawFinderPattern(size - 4, 3)
        drawFinderPattern(3, size - 4)
        let positions = alignmentPatternPositions()
        let count = positions.count
        for i in 0..<count {
            for j in 0..<count {
                let isFinderCorner = (i == 0 && j == 0) || (i == 0 && j == count - 1) || (i == count - 1 && j == 0)
                if isFinderCorner == false {
                    drawAlignmentPattern(positions[i], positions[j])
                }
            }
        }
        drawFormatBits(mask: 0)
        drawVersion()
    }

    mutating func drawFinderPattern(_ x: Int, _ y: Int) {
        for dy in -4...4 {
            for dx in -4...4 {
                let distance = max(abs(dx), abs(dy))
                let xx = x + dx
                let yy = y + dy
                if (0..<size).contains(xx), (0..<size).contains(yy) {
                    setFunction(xx, yy, distance != 2 && distance != 4)
                }
            }
        }
    }

    mutating func drawAlignmentPattern(_ x: Int, _ y: Int) {
        for dy in -2...2 {
            for dx in -2...2 {
                setFunction(x + dx, y + dy, max(abs(dx), abs(dy)) != 1)
            }
        }
    }

    func alignmentPatternPositions() -> [Int] {
        guard version > 1 else { return [] }
        let count = version / 7 + 2
        let step = (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2
        var result = (0..<(count - 1)).map { size - 7 - $0 * step }
        result.append(6)
        return result.reversed()
    }

    mutating func drawFormatBits(mask: Int) {
        let data = QRCodeEncoderFormat.eccBits << 3 | mask
        var remainder = data
        for _ in 0..<10 {
            remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537)
        }
        let bits = (data << 10 | remainder) ^ 0x5412
        func bit(_ index: Int) -> Bool { (bits >> index) & 1 != 0 }

        for index in 0...5 {
            setFunction(8, index, bit(index))
        }
        setFunction(8, 7, bit(6))
        setFunction(8, 8, bit(7))
        setFunction(7, 8, bit(8))
        for index in 9..<15 {
            setFunction(14 - index, 8, bit(index))
        }
        for index in 0..<8 {
            setFunction(size - 1 - index, 8, bit(index))
        }
        for index in 8..<15 {
            setFunction(8, size - 15 + index, bit(index))
        }
        setFunction(8, size - 8, true)
    }

    mutating func drawVersion() {
        guard version >= 7 else { return }
        var remainder = version
        for _ in 0..<12 {
            remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25)
        }
        let bits = version << 12 | remainder
        for index in 0..<18 {
            let dark = (bits >> index) & 1 != 0
            let a = size - 11 + index % 3
            let b = index / 3
            setFunction(a, b, dark)
            setFunction(b, a, dark)
        }
    }

    mutating func drawCodewords(_ data: [UInt8]) {
        var bitIndex = 0
        let totalBits = data.count * 8
        var right = size - 1
        while right >= 1 {
            if right == 6 {
                right = 5
            }
            for vertical in 0..<size {
                for offset in 0..<2 {
                    let x = right - offset
                    let upward = ((right + 1) & 2) == 0
                    let y = upward ? size - 1 - vertical : vertical
                    if isFunction[y][x] == false, bitIndex < totalBits {
                        modules[y][x] = (data[bitIndex >> 3] >> (7 - (bitIndex & 7))) & 1 != 0
                        bitIndex += 1
                    }
                }
            }
            right -= 2
        }
    }

    mutating func applyMask(_ mask: Int) {
        for y in 0..<size {
            for x in 0..<size where isFunction[y][x] == false {
                let invert: Bool
                switch mask {
                case 0: invert = (x + y) % 2 == 0
                case 1: invert = y % 2 == 0
                case 2: invert = x % 3 == 0
                case 3: invert = (x + y) % 3 == 0
                case 4: invert = (x / 3 + y / 2) % 2 == 0
                case 5: invert = x * y % 2 + x * y % 3 == 0
                case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0
                default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
                }
                if invert {
                    modules[y][x].toggle()
                }
            }
        }
    }

    func penaltyScore() -> Int {
        let n1 = 3, n2 = 3, n3 = 40, n4 = 10
        var result = 0

        func scoreLine(_ line: (Int) -> Bool) -> Int {
            var score = 0
            var runColor = false
            var runLength = 0
            var history = [Int](repeating: 0, count: 7)
            for index in 0..<size {
                if line(index) == runColor {
                    runLength += 1
                    if runLength == 5 {
                        score += n1
                    } else if runLength > 5 {
                        score += 1
                    }
                } else {
                    addHistory(runLength, &history)
                    if runColor == false {
                        score += countFinderPatterns(history) * n3
                    }
                    runColor = line(index)
                    runLength = 1
                }
            }
            if runColor {
                addHistory(runLength, &history)
                runLength = 0
            }
            runLength += size
            addHistory(runLength, &history)
            score += countFinderPatterns(history) * n3
            return score
        }

        func addHistory(_ length: Int, _ history: inout [Int]) {
            var length = length
            if history[0] == 0 {
                length += size
            }
            history.removeLast()
            history.insert(length, at: 0)
        }

        func countFinderPatterns(_ history: [Int]) -> Int {
            let n = history[1]
            let core = n > 0 && history[2] == n && history[3] == n * 3 && history[4] == n && history[5] == n
            return (core && history[0] >= n * 4 && history[6] >= n ? 1 : 0)
                + (core && history[6] >= n * 4 && history[0] >= n ? 1 : 0)
        }

        for y in 0..<size {
            result += scoreLine { modules[y][$0] }
        }
        for x in 0..<size {
            result += scoreLine { modules[$0][x] }
        }
        for y in 0..<(size - 1) {
            for x in 0..<(size - 1) {
                let color = modules[y][x]
                if color == modules[y][x + 1], color == modules[y + 1][x], color == modules[y + 1][x + 1] {
                    result += n2
                }
            }
        }
        let dark = modules.reduce(0) { $0 + $1.filter { $0 }.count }
        let total = size * size
        let k = (abs(dark * 20 - total * 10) + total - 1) / total - 1
        result += k * n4
        return result
    }
}

private enum QRCodeEncoderFormat {
    /// Error correction level M's two format bits.
    static let eccBits = 0
}
