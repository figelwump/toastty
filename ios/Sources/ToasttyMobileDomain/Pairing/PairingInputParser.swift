import Foundation
import RemoteProtocol

public struct PairingCandidate: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Proof: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        case qr(offerID: UUID, secret: String, expiresAt: Date)
        case manual(fallbackCode: String)

        public var description: String { "<redacted pairing proof>" }
        public var debugDescription: String { description }
    }

    public let gatewayURL: URL
    public let proof: Proof

    public init(gatewayURL: URL, proof: Proof) {
        self.gatewayURL = gatewayURL
        self.proof = proof
    }

    public var description: String {
        "<redacted pairing candidate>"
    }
    public var debugDescription: String { description }
}

public enum PairingInputError: Error, Equatable, Sendable {
    case inputTooLarge
    case invalidEncoding
    case unsupportedVersion
    case invalidGateway
    case invalidProof
    case expired
}

/// Parses pairing material without performing network activity. The returned
/// candidate is intentionally a separate value so UI can confirm the canonical
/// hostname before handing it to `NativePairingClient`.
public struct PairingInputParser: Sendable {
    public init() {}

    public func parseQRCode(_ value: String, now: Date = Date()) throws -> PairingCandidate {
        guard value.utf8.count <= RemoteNativePairingQRPayload.maximumEncodedByteCount else {
            throw PairingInputError.inputTooLarge
        }

        let payload: RemoteNativePairingQRPayload
        do {
            payload = try RemoteNativePairingQRPayload(encodedString: value)
        } catch RemoteNativePairingQRPayloadError.unsupportedVersion {
            throw PairingInputError.unsupportedVersion
        } catch RemoteNativePairingQRPayloadError.invalidEncoding {
            throw PairingInputError.invalidEncoding
        } catch {
            throw PairingInputError.invalidProof
        }

        let gatewayURL = try Self.canonicalGatewayURL(payload.gatewayURL.absoluteString)
        guard payload.expiresAt > now else { throw PairingInputError.expired }
        guard Self.isValidCredentialMaterial(payload.secret) else {
            throw PairingInputError.invalidProof
        }
        return PairingCandidate(
            gatewayURL: gatewayURL,
            proof: .qr(
                offerID: payload.offerID,
                secret: payload.secret,
                expiresAt: payload.expiresAt
            )
        )
    }

    public func parseManual(gateway: String, code: String) throws -> PairingCandidate {
        guard gateway.utf8.count <= 255, code.utf8.count <= 32 else {
            throw PairingInputError.inputTooLarge
        }
        let gatewayURL = try Self.canonicalGatewayURL(gateway)
        guard let fallbackCode = Self.canonicalFallbackCode(code) else {
            throw PairingInputError.invalidProof
        }
        return PairingCandidate(
            gatewayURL: gatewayURL,
            proof: .manual(fallbackCode: fallbackCode)
        )
    }

    public static func canonicalGatewayURL(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 255,
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII }),
              !trimmed.contains("%") else {
            throw PairingInputError.invalidGateway
        }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw PairingInputError.invalidGateway
        }

        let host = rawHost.lowercased()
        guard Self.isCanonicalTailscaleHostname(host),
              let url = URL(string: "https://\(host)") else {
            throw PairingInputError.invalidGateway
        }
        return url
    }

    static func isValidCredentialMaterial(_ value: String) -> Bool {
        guard value.utf8.count == 43,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 48...57, 65...90, 95, 97...122: true
                  default: false
                  }
              }) else {
            return false
        }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append("=")
        return Data(base64Encoded: base64)?.count == 32
    }

    private static func isCanonicalTailscaleHostname(_ host: String) -> Bool {
        guard host.utf8.count <= 253,
              host == host.lowercased(),
              host.hasSuffix(".ts.net"),
              host.count > ".ts.net".count,
              host.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, labels.suffix(2).map(String.init) == ["ts", "net"] else {
            return false
        }
        return labels.allSatisfy { label in
            guard (1...63).contains(label.utf8.count),
                  label.first != "-", label.last != "-" else { return false }
            return label.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 45, 48...57, 97...122: true
                default: false
                }
            }
        }
    }

    private static func canonicalFallbackCode(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let ungrouped: String
        if trimmed.count == 14 {
            let characters = Array(trimmed)
            guard characters[4] == "-", characters[9] == "-" else { return nil }
            ungrouped = String(characters[0..<4] + characters[5..<9] + characters[10..<14])
        } else if trimmed.count == 12 {
            ungrouped = trimmed
        } else {
            return nil
        }
        let alphabet = CharacterSet(charactersIn: "23456789ABCDEFGHJKMNPQRSTVWXYZ")
        guard ungrouped.unicodeScalars.allSatisfy({ alphabet.contains($0) }) else { return nil }
        let characters = Array(ungrouped)
        return "\(String(characters[0..<4]))-\(String(characters[4..<8]))-\(String(characters[8..<12]))"
    }
}
