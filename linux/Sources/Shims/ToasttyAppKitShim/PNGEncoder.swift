import Foundation

/// Minimal PNG writer: 8-bit RGBA, filter 0, zlib "stored" deflate blocks.
/// No compression, which is fine for QR codes and screenshots handed straight
/// to GdkTexture; output is a valid PNG any decoder reads.
enum PNGEncoder {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func encode(_ bitmap: LinuxBitmap) -> Data {
        var out = Data(signature)
        var header = Data()
        header.appendBigEndian(UInt32(bitmap.width))
        header.appendBigEndian(UInt32(bitmap.height))
        header.append(contentsOf: [8, 6, 0, 0, 0]) // depth 8, RGBA, deflate, filter 0, no interlace
        appendChunk("IHDR", header, to: &out)

        var raw = [UInt8]()
        raw.reserveCapacity((bitmap.width * 4 + 1) * bitmap.height)
        for y in 0..<bitmap.height {
            raw.append(0)
            let start = y * bitmap.width * 4
            raw.append(contentsOf: bitmap.rgba[start..<(start + bitmap.width * 4)])
        }
        appendChunk("IDAT", zlibStored(raw), to: &out)
        appendChunk("IEND", Data(), to: &out)
        return out
    }

    private static func zlibStored(_ bytes: [UInt8]) -> Data {
        var out = Data([0x78, 0x01])
        var offset = 0
        repeat {
            let count = min(65_535, bytes.count - offset)
            let isFinal = offset + count >= bytes.count
            out.append(isFinal ? 1 : 0)
            out.append(UInt8(count & 0xFF))
            out.append(UInt8(count >> 8))
            out.append(UInt8(~count & 0xFF))
            out.append(UInt8((~count >> 8) & 0xFF))
            out.append(contentsOf: bytes[offset..<(offset + count)])
            offset += count
        } while offset < bytes.count
        out.appendBigEndian(adler32(bytes))
        return out
    }

    private static func appendChunk(_ type: String, _ data: Data, to out: inout Data) {
        out.appendBigEndian(UInt32(data.count))
        let typeBytes = Data(type.utf8)
        out.append(typeBytes)
        out.append(data)
        out.appendBigEndian(crc32(typeBytes + data))
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
