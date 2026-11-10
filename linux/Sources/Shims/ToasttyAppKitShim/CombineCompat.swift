import Foundation
import OpenCombine

// Combine operators OpenCombine 0.14 does not implement yet.
// (OpenCombineFoundation already provides NotificationCenter.publisher(for:)
// and RunLoop/DispatchQueue schedulers on Linux.)

extension Publishers {
    /// Apple's `CombineLatest`: emits a tuple of the latest values once both
    /// upstreams have produced one; finishes when both finish; fails when
    /// either fails.
    public struct CombineLatest<A: Publisher, B: Publisher>: Publisher where A.Failure == B.Failure {
        public typealias Output = (A.Output, B.Output)
        public typealias Failure = A.Failure

        public let a: A
        public let b: B

        public init(_ a: A, _ b: B) {
            self.a = a
            self.b = b
        }

        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let subscription = CombineLatestSubscription<A, B, S>(downstream: subscriber)
            subscriber.receive(subscription: subscription)
            a.subscribe(CombineLatestSide<A.Output, Failure>(index: 0, parent: subscription))
            b.subscribe(CombineLatestSide<B.Output, Failure>(index: 1, parent: subscription))
        }
    }
}

extension Publisher {
    public func combineLatest<P: Publisher>(_ other: P) -> Publishers.CombineLatest<Self, P>
        where P.Failure == Failure {
        Publishers.CombineLatest(self, other)
    }

    public func combineLatest<P: Publisher, T>(
        _ other: P,
        _ transform: @escaping (Output, P.Output) -> T
    ) -> Publishers.Map<Publishers.CombineLatest<Self, P>, T> where P.Failure == Failure {
        Publishers.CombineLatest(self, other).map(transform)
    }
}

private protocol CombineLatestParent: AnyObject {
    associatedtype Failure: Error
    func receiveSubscription(_ subscription: Subscription, index: Int)
    func receiveValue(_ value: Any, index: Int)
    func receiveCompletion(_ completion: Subscribers.Completion<Failure>, index: Int)
}

private final class CombineLatestSide<Input, Failure: Error>: Subscriber {
    let combineIdentifier = CombineIdentifier()
    private let onSubscription: (Subscription) -> Void
    private let onValue: (Input) -> Void
    private let onCompletion: (Subscribers.Completion<Failure>) -> Void

    init<P: CombineLatestParent>(index: Int, parent: P) where P.Failure == Failure {
        onSubscription = { [weak parent] in parent?.receiveSubscription($0, index: index) }
        onValue = { [weak parent] in parent?.receiveValue($0, index: index) }
        onCompletion = { [weak parent] in parent?.receiveCompletion($0, index: index) }
    }

    func receive(subscription: Subscription) { onSubscription(subscription) }

    func receive(_ input: Input) -> Subscribers.Demand {
        onValue(input)
        return .none
    }

    func receive(completion: Subscribers.Completion<Failure>) { onCompletion(completion) }
}

private final class CombineLatestSubscription<A: Publisher, B: Publisher, S: Subscriber>: Subscription, CombineLatestParent, @unchecked Sendable
    where A.Failure == B.Failure, S.Input == (A.Output, B.Output), S.Failure == A.Failure {
    typealias Failure = A.Failure

    private let lock = NSRecursiveLock()
    private var downstream: S?
    private var upstreams: [Subscription?] = [nil, nil]
    private var latestA: A.Output?
    private var latestB: B.Output?
    private var finished = [false, false]
    private var demand: Subscribers.Demand = .none
    private var hasPendingValue = false
    private var isTerminated = false

    init(downstream: S) {
        self.downstream = downstream
    }

    func receiveSubscription(_ subscription: Subscription, index: Int) {
        lock.lock()
        guard isTerminated == false else {
            lock.unlock()
            subscription.cancel()
            return
        }
        upstreams[index] = subscription
        lock.unlock()
        subscription.request(.unlimited)
    }

    func receiveValue(_ value: Any, index: Int) {
        lock.lock()
        guard isTerminated == false else { lock.unlock(); return }
        if index == 0, let value = value as? A.Output { latestA = value }
        if index == 1, let value = value as? B.Output { latestB = value }
        guard latestA != nil, latestB != nil else { lock.unlock(); return }
        hasPendingValue = true
        emitIfPossible()
    }

    func receiveCompletion(_ completion: Subscribers.Completion<Failure>, index: Int) {
        lock.lock()
        guard isTerminated == false else { lock.unlock(); return }
        switch completion {
        case .failure:
            isTerminated = true
            let downstream = self.downstream
            let others = upstreams
            self.downstream = nil
            upstreams = [nil, nil]
            lock.unlock()
            others.enumerated().forEach { if $0.offset != index { $0.element?.cancel() } }
            downstream?.receive(completion: completion)
        case .finished:
            finished[index] = true
            guard finished.allSatisfy({ $0 }) else { lock.unlock(); return }
            isTerminated = true
            let downstream = self.downstream
            self.downstream = nil
            upstreams = [nil, nil]
            lock.unlock()
            downstream?.receive(completion: .finished)
        }
    }

    /// Called with the lock held; releases it.
    private func emitIfPossible() {
        guard hasPendingValue, demand > 0, let a = latestA, let b = latestB, let downstream else {
            lock.unlock()
            return
        }
        hasPendingValue = false
        demand -= 1
        lock.unlock()
        let additional = downstream.receive((a, b))
        lock.lock()
        demand += additional
        lock.unlock()
    }

    func request(_ demand: Subscribers.Demand) {
        lock.lock()
        self.demand += demand
        emitIfPossible()
    }

    func cancel() {
        lock.lock()
        isTerminated = true
        downstream = nil
        let upstreams = self.upstreams
        self.upstreams = [nil, nil]
        lock.unlock()
        upstreams.forEach { $0?.cancel() }
    }
}
