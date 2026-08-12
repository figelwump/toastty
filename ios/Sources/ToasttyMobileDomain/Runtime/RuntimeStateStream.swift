import Foundation

/// A latest-value state stream for actor-owned runtimes.
///
/// Every subscriber receives the current value immediately. Subsequent values
/// use a single-element newest-value buffer so a slow UI consumer cannot apply
/// backpressure to a runtime. The runtime's own actor state must remain the
/// source of truth; this stream is only a bounded observation channel.
public actor RuntimeStateStream<State: Sendable> {
    private var value: State
    private var continuations: [UUID: AsyncStream<State>.Continuation] = [:]
    private var isFinished = false

    public init(_ initialValue: State) {
        value = initialValue
    }

    public func currentValue() -> State {
        value
    }

    public func states() -> AsyncStream<State> {
        let subscriberID = UUID()
        let (stream, continuation) = AsyncStream<State>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        continuation.yield(value)

        guard !isFinished else {
            continuation.finish()
            return stream
        }

        continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removeSubscriber(subscriberID)
            }
        }
        continuations[subscriberID] = continuation
        return stream
    }

    public func yield(_ newValue: State) {
        guard !isFinished else { return }
        value = newValue
        for continuation in continuations.values {
            continuation.yield(newValue)
        }
    }

    public func finish() {
        guard !isFinished else { return }
        isFinished = true

        let activeContinuations = Array(continuations.values)
        continuations.removeAll()
        for continuation in activeContinuations {
            continuation.finish()
        }
    }

    func subscriberCount() -> Int {
        continuations.count
    }

    private func removeSubscriber(_ subscriberID: UUID) {
        continuations.removeValue(forKey: subscriberID)
    }
}
