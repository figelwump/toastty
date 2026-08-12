import RemoteProtocol

public extension RemoteGatewayDeviceSummary {
    init(device: RemoteDeviceRecord) {
        self.init(
            id: device.id,
            name: device.name,
            scopes: Array(device.scopes)
        )
    }
}
