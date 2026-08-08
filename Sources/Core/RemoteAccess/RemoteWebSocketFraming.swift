import Foundation

/// RFC 6455 frame encoding/decoding for the gateway's server side.
///
/// Scope is deliberately minimal: text, ping/pong, and close frames, no
/// extensions, no fragmentation (fragmented client messages are rejected by
/// closing the connection — the v0/v1 client protocol never needs them).
public enum RemoteWebSocketFraming {
    public static let maximumPayloadBytes = 256 * 1024

    public enum Opcode: UInt8, Equatable, Sendable {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    public struct Frame: Equatable, Sendable {
        public var opcode: Opcode
        public var payload: Data

        public init(opcode: Opcode, payload: Data) {
            self.opcode = opcode
            self.payload = payload
        }
    }

    public enum DecodeOutcome: Equatable, Sendable {
        case frame(Frame, consumedBytes: Int)
        case needMoreData
        /// Protocol violation (unmasked client frame, fragmentation, oversize
        /// payload, reserved bits); the connection must close.
        case invalid
    }

    /// Encodes a server-to-client frame (never masked).
    public static func encodeServerFrame(opcode: Opcode, payload: Data) -> Data {
        var data = Data()
        data.append(0x80 | opcode.rawValue)
        if payload.count < 126 {
            data.append(UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            data.append(126)
            data.append(UInt8((payload.count >> 8) & 0xFF))
            data.append(UInt8(payload.count & 0xFF))
        } else {
            data.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }
        data.append(payload)
        return data
    }

    public static func encodeServerTextFrame(_ text: String) -> Data {
        encodeServerFrame(opcode: .text, payload: Data(text.utf8))
    }

    public static func encodeServerCloseFrame(code: UInt16 = 1000) -> Data {
        var payload = Data()
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        return encodeServerFrame(opcode: .close, payload: payload)
    }

    /// Decodes one client-to-server frame from the start of `buffer`. Client
    /// frames must be masked and unfragmented.
    public static func decodeClientFrame(_ buffer: Data) -> DecodeOutcome {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return .needMoreData }

        let first = bytes[0]
        let fin = (first & 0x80) != 0
        let reservedBits = first & 0x70
        guard reservedBits == 0 else { return .invalid }
        guard let opcode = Opcode(rawValue: first & 0x0F) else { return .invalid }
        // No fragmentation support: every frame must be final and control
        // frames may not be fragmented anyway.
        guard fin, opcode != .continuation else { return .invalid }

        let second = bytes[1]
        let masked = (second & 0x80) != 0
        guard masked else { return .invalid }

        var payloadLength = Int(second & 0x7F)
        var offset = 2
        if payloadLength == 126 {
            guard bytes.count >= 4 else { return .needMoreData }
            payloadLength = (Int(bytes[2]) << 8) | Int(bytes[3])
            offset = 4
        } else if payloadLength == 127 {
            guard bytes.count >= 10 else { return .needMoreData }
            var length: UInt64 = 0
            for index in 2..<10 {
                length = (length << 8) | UInt64(bytes[index])
            }
            guard length <= UInt64(maximumPayloadBytes) else { return .invalid }
            payloadLength = Int(length)
            offset = 10
        }
        guard payloadLength <= maximumPayloadBytes else { return .invalid }

        guard bytes.count >= offset + 4 else { return .needMoreData }
        let mask = Array(bytes[offset..<(offset + 4)])
        offset += 4

        guard bytes.count >= offset + payloadLength else { return .needMoreData }
        var payload = Data(capacity: payloadLength)
        for index in 0..<payloadLength {
            payload.append(bytes[offset + index] ^ mask[index % 4])
        }

        return .frame(
            Frame(opcode: opcode, payload: payload),
            consumedBytes: offset + payloadLength
        )
    }
}
