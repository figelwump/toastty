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

extension Publishers {
    /// Apple's `Merge3`: the values of three upstreams of one type, as they
    /// come; finishes when all three finish; fails when one fails. OpenCombine
    /// has no `Merge`; this one asks each upstream for unlimited values and
    /// passes them on through a subject, which honours downstream demand.
    public struct Merge3<A: Publisher, B: Publisher, C: Publisher>: Publisher
        where A.Output == B.Output, B.Output == C.Output, A.Failure == B.Failure, B.Failure == C.Failure {
        public typealias Output = A.Output
        public typealias Failure = A.Failure

        public let a: A
        public let b: B
        public let c: C

        public init(_ a: A, _ b: B, _ c: C) {
            self.a = a
            self.b = b
            self.c = c
        }

        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let merger = MergeAll<Output, Failure>(upstreamCount: 3)
            merger.subject
                .handleEvents(receiveCancel: { [merger] in merger.cancel() })
                .receive(subscriber: subscriber)
            merger.attach(a)
            merger.attach(b)
            merger.attach(c)
        }
    }
}

private final class MergeAll<Output, Failure: Error>: @unchecked Sendable {
    let subject = PassthroughSubject<Output, Failure>()
    private let lock = NSLock()
    private var remaining: Int
    private var cancellables: [AnyCancellable] = []
    private var isDone = false

    init(upstreamCount: Int) {
        remaining = upstreamCount
    }

    func attach<P: Publisher>(_ upstream: P) where P.Output == Output, P.Failure == Failure {
        let cancellable = upstream.sink(
            receiveCompletion: { [weak self] completion in self?.complete(completion) },
            receiveValue: { [weak self] value in
                guard let self, self.lock.withLock({ self.isDone }) == false else { return }
                self.subject.send(value)
            }
        )
        let keep = lock.withLock { () -> Bool in
            guard isDone == false else { return false }
            cancellables.append(cancellable)
            return true
        }
        if keep == false { cancellable.cancel() }
    }

    func cancel() {
        let toCancel = lock.withLock { () -> [AnyCancellable] in
            isDone = true
            defer { cancellables = [] }
            return cancellables
        }
        toCancel.forEach { $0.cancel() }
    }

    private func complete(_ completion: Subscribers.Completion<Failure>) {
        let finish: Subscribers.Completion<Failure>? = lock.withLock {
            guard isDone == false else { return nil }
            switch completion {
            case .failure:
                isDone = true
                return completion
            case .finished:
                remaining -= 1
                guard remaining == 0 else { return nil }
                isDone = true
                return completion
            }
        }
        guard let finish else { return }
        subject.send(completion: finish)
        if case .failure = finish { cancel() }
    }
}
