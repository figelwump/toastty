import Foundation

// Foundation API present on Darwin but missing from swift-corelibs-foundation.

extension NSString {
    /// `~`-abbreviated path, like Darwin's `abbreviatingWithTildeInPath`.
    public var abbreviatingWithTildeInPath: String {
        let path = self as String
        let home = NSHomeDirectory()
        guard home.isEmpty == false, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

extension NSString {
    /// Darwin's encoding detection, reduced to what Toastty's previews need:
    /// a BOM (UTF-8/16/32), strict UTF-8, BOM-less UTF-16 (NUL-pattern
    /// heuristic), then Windows-1252/Latin-1, which decode any byte string.
    /// Returns 0 when nothing decodes. Never reports lossy conversion.
    public class func stringEncoding(
        for data: Data,
        encodingOptions: [StringEncodingDetectionOptionsKey: Any]? = nil,
        convertedString: UnsafeMutablePointer<NSString?>?,
        usedLossyConversion: UnsafeMutablePointer<ObjCBool>?
    ) -> UInt {
        _ = encodingOptions
        usedLossyConversion?.pointee = false
        func accept(_ string: String, _ encoding: String.Encoding) -> UInt {
            convertedString?.pointee = string as NSString
            return encoding.rawValue
        }
        let bytes = [UInt8](data)
        let boms: [([UInt8], String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
        ]
        for (bom, encoding) in boms where bytes.starts(with: bom) {
            if let string = String(data: Data(bytes.dropFirst(bom.count)), encoding: encoding) {
                return accept(string, encoding)
            }
        }
        if let string = String(validatingUTF8CString: bytes) ?? String(bytes: bytes, encoding: .utf8) {
            return accept(string, .utf8)
        }
        if bytes.count >= 2, bytes.count % 2 == 0 {
            let evenZeros = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
            let oddZeros = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
            let half = bytes.count / 2
            if oddZeros * 2 > half, evenZeros == 0, let string = String(data: data, encoding: .utf16LittleEndian) {
                return accept(string, .utf16LittleEndian)
            }
            if evenZeros * 2 > half, oddZeros == 0, let string = String(data: data, encoding: .utf16BigEndian) {
                return accept(string, .utf16BigEndian)
            }
        }
        if let string = String(data: data, encoding: .windowsCP1252) {
            return accept(string, .windowsCP1252)
        }
        if let string = String(data: data, encoding: .isoLatin1) {
            return accept(string, .isoLatin1)
        }
        return 0
    }
}

private extension String {
    /// Strict UTF-8 decode that rejects invalid sequences (the failable
    /// `String(bytes:encoding:)` on corelibs can repair them).
    init?(validatingUTF8CString bytes: [UInt8]) {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        var scalars = String.UnicodeScalarView()
        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: break loop
            case .error: return nil
            }
        }
        self = String(scalars)
    }
}

/// Darwin's `StringEncodingDetectionOptionsKey` (absent from corelibs).
public struct StringEncodingDetectionOptionsKey: RawRepresentable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let allowLossyKey = Self(rawValue: "NSStringEncodingDetectionAllowLossyKey")
    public static let suggestedEncodingsKey = Self(rawValue: "NSStringEncodingDetectionSuggestedEncodingsKey")
    public static let useOnlySuggestedEncodingsKey = Self(rawValue: "NSStringEncodingDetectionUseOnlySuggestedEncodingsKey")
}

public typealias CFAbsoluteTime = Double

/// Seconds since 2001-01-01 (CoreFoundation's reference date).
public func CFAbsoluteTimeGetCurrent() -> CFAbsoluteTime {
    Date().timeIntervalSinceReferenceDate
}
