import Foundation

public protocol ConnectionSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousConnectionSleeper: ConnectionSleeping {
    private let clock = ContinuousClock()

    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

public protocol ConnectionJitterProviding: Sendable {
    /// A deterministic unit-interval sample. Implementations clamp out-of-range
    /// values at the policy boundary rather than letting a bad source create an
    /// unbounded reconnect delay.
    func sample() async -> Double
}

public struct SystemConnectionJitter: ConnectionJitterProviding {
    public init() {}

    public func sample() async -> Double {
        Double.random(in: 0...1)
    }
}

public struct ConnectionRetryPolicy: Equatable, Sendable {
    public var initialDelay: Duration
    public var maximumDelay: Duration
    public var bannerFailureCount: Int

    public init(
        initialDelay: Duration = .seconds(1),
        maximumDelay: Duration = .seconds(30),
        bannerFailureCount: Int = 2
    ) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.bannerFailureCount = max(1, bannerFailureCount)
    }

    public func delay(afterFailureCount failureCount: Int, jitterUnit: Double) -> Duration {
        guard failureCount > 0 else { return .zero }
        let exponent = min(failureCount - 1, 30)
        let base = min(
            durationSeconds(initialDelay) * pow(2, Double(exponent)),
            durationSeconds(maximumDelay)
        )
        let clampedJitter = min(max(jitterUnit, 0), 1)
        let factor = 0.8 + (0.4 * clampedJitter)
        return .seconds(min(base * factor, durationSeconds(maximumDelay)))
    }

    public func shouldShowReconnectingBanner(afterFailureCount failureCount: Int) -> Bool {
        failureCount >= bannerFailureCount
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}
