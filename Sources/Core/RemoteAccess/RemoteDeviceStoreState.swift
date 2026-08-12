import Foundation

extension RemoteDeviceStore {
    public struct State: Codable, Equatable, Sendable {
        public var devices: [RemoteDeviceRecord]
        public var credentials: [RemoteDeviceCredentialRecord]
        public var nativePairingFailures: [RemoteNativePairingFailureRecord]

        private var quarantinedDevices: [StoredJSONValue]
        private var quarantinedCredentials: [StoredJSONValue]
        private var quarantinedNativePairingFailures: [StoredJSONValue]
        private var unknownFields: [String: StoredJSONValue]

        public init(
            devices: [RemoteDeviceRecord] = [],
            credentials: [RemoteDeviceCredentialRecord] = [],
            nativePairingFailures: [RemoteNativePairingFailureRecord] = []
        ) {
            self.devices = Array(devices.prefix(RemoteDeviceStore.maximumDeviceCount))
            self.credentials = Array(credentials.prefix(RemoteDeviceStore.maximumCredentialCount))
            self.nativePairingFailures = Array(nativePairingFailures.prefix(RemoteDeviceStore.maximumNativeFailureIdentityCount))
            quarantinedDevices = []
            quarantinedCredentials = []
            quarantinedNativePairingFailures = []
            unknownFields = [:]
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case devices
            case credentials
            case nativePairingFailures
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let deviceResult: StoredDecodedArray<RemoteDeviceRecord> = try Self.decodeBoundedArray(
                from: container,
                forKey: .devices,
                maximumValidCount: RemoteDeviceStore.maximumDeviceCount
            )
            devices = deviceResult.values
            quarantinedDevices = deviceResult.quarantined

            let credentialResult: StoredDecodedArray<RemoteDeviceCredentialRecord> = try Self.decodeBoundedArray(
                from: container,
                forKey: .credentials,
                maximumValidCount: RemoteDeviceStore.maximumCredentialCount
            )
            credentials = credentialResult.values
            quarantinedCredentials = credentialResult.quarantined

            let failureResult: StoredDecodedArray<RemoteNativePairingFailureRecord> = try Self.decodeBoundedArray(
                from: container,
                forKey: .nativePairingFailures,
                maximumValidCount: RemoteDeviceStore.maximumNativeFailureIdentityCount
            )
            nativePairingFailures = []
            quarantinedNativePairingFailures = failureResult.quarantined
            for record in failureResult.values {
                if RemoteDeviceRecord.isValidTailscaleLogin(record.tailscaleLogin),
                   record.failureTimes.count <= RemoteDeviceStore.maximumNativePairingFailureTimes {
                    nativePairingFailures.append(record)
                } else if quarantinedNativePairingFailures.count < RemoteDeviceStore.maximumQuarantinedRecordCount,
                          let data = try? JSONEncoder().encode(record),
                          let raw = try? JSONDecoder().decode(StoredJSONValue.self, from: data) {
                    quarantinedNativePairingFailures.append(raw)
                }
            }

            let dynamicContainer = try decoder.container(keyedBy: StoredDynamicCodingKey.self)
            let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
            unknownFields = try Dictionary(uniqueKeysWithValues: dynamicContainer.allKeys.compactMap { key in
                guard knownKeys.contains(key.stringValue) == false else { return nil }
                return (key.stringValue, try dynamicContainer.decode(StoredJSONValue.self, forKey: key))
            })
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try Self.encode(values: devices, quarantined: quarantinedDevices, to: &container, forKey: .devices)
            try Self.encode(values: credentials, quarantined: quarantinedCredentials, to: &container, forKey: .credentials)
            try Self.encode(
                values: nativePairingFailures,
                quarantined: quarantinedNativePairingFailures,
                to: &container,
                forKey: .nativePairingFailures
            )
            var dynamicContainer = encoder.container(keyedBy: StoredDynamicCodingKey.self)
            for (key, value) in unknownFields {
                try dynamicContainer.encode(value, forKey: StoredDynamicCodingKey(key))
            }
        }

        public static func == (lhs: State, rhs: State) -> Bool {
            lhs.devices == rhs.devices
                && lhs.credentials == rhs.credentials
                && lhs.nativePairingFailures == rhs.nativePairingFailures
        }

        private static func decodeBoundedArray<Value: Codable>(
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys,
            maximumValidCount: Int
        ) throws -> StoredDecodedArray<Value> {
            guard container.contains(key) else { return StoredDecodedArray() }
            var nested = try container.nestedUnkeyedContainer(forKey: key)
            var values: [Value] = []
            var quarantined: [StoredJSONValue] = []
            while nested.isAtEnd == false {
                let raw = try nested.decode(StoredJSONValue.self)
                if values.count < maximumValidCount,
                   let data = try? JSONEncoder().encode(raw),
                   let value = try? JSONDecoder().decode(Value.self, from: data) {
                    values.append(value)
                } else if quarantined.count < RemoteDeviceStore.maximumQuarantinedRecordCount {
                    quarantined.append(raw)
                }
            }
            return StoredDecodedArray(values: values, quarantined: quarantined)
        }

        private static func encode<Value: Encodable>(
            values: [Value],
            quarantined: [StoredJSONValue],
            to container: inout KeyedEncodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) throws {
            var nested = container.nestedUnkeyedContainer(forKey: key)
            for value in values { try nested.encode(value) }
            for raw in quarantined { try nested.encode(raw) }
        }
    }
}

private struct StoredDecodedArray<Value> {
    var values: [Value] = []
    var quarantined: [StoredJSONValue] = []
}

private struct StoredDynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Codable JSON tree used only to preserve malformed records across a later
/// legitimate write without admitting them into authentication state.
private enum StoredJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([StoredJSONValue])
    case object([String: StoredJSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([StoredJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: StoredJSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
