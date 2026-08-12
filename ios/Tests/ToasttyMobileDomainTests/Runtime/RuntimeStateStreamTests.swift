import XCTest
@testable import ToasttyMobileDomain

final class RuntimeStateStreamTests: XCTestCase {
    func testSubscriberImmediatelyReceivesCurrentValue() async {
        let stateStream = RuntimeStateStream(41)
        await stateStream.yield(42)

        let stream = await stateStream.states()
        var iterator = stream.makeAsyncIterator()
        let firstValue = await iterator.next()

        XCTAssertEqual(firstValue, 42)
    }

    func testSlowSubscriberKeepsOnlyNewestBufferedValue() async {
        let stateStream = RuntimeStateStream(0)
        let stream = await stateStream.states()
        var iterator = stream.makeAsyncIterator()

        let initialValue = await iterator.next()
        XCTAssertEqual(initialValue, 0)

        await stateStream.yield(1)
        await stateStream.yield(2)
        await stateStream.yield(3)

        let bufferedValue = await iterator.next()
        XCTAssertEqual(bufferedValue, 3)
        let currentValue = await stateStream.currentValue()
        XCTAssertEqual(currentValue, 3)
    }

    func testSubscribersHaveIndependentNewestValueBuffers() async {
        let stateStream = RuntimeStateStream("initial")
        let firstStream = await stateStream.states()
        let secondStream = await stateStream.states()
        var firstIterator = firstStream.makeAsyncIterator()
        var secondIterator = secondStream.makeAsyncIterator()

        let firstInitial = await firstIterator.next()
        let secondInitial = await secondIterator.next()
        XCTAssertEqual(firstInitial, "initial")
        XCTAssertEqual(secondInitial, "initial")

        await stateStream.yield("old")
        let firstOld = await firstIterator.next()
        XCTAssertEqual(firstOld, "old")

        await stateStream.yield("new")
        let firstNew = await firstIterator.next()
        let secondNewest = await secondIterator.next()
        XCTAssertEqual(firstNew, "new")
        XCTAssertEqual(secondNewest, "new")
    }

    func testFinishTerminatesAllSubscribersAndIsIdempotent() async {
        let stateStream = RuntimeStateStream(7)
        let firstStream = await stateStream.states()
        let secondStream = await stateStream.states()
        var firstIterator = firstStream.makeAsyncIterator()
        var secondIterator = secondStream.makeAsyncIterator()

        _ = await firstIterator.next()
        _ = await secondIterator.next()
        let subscriberCountBeforeFinish = await stateStream.subscriberCount()
        XCTAssertEqual(subscriberCountBeforeFinish, 2)

        await stateStream.finish()
        await stateStream.finish()

        let firstCompletion = await firstIterator.next()
        let secondCompletion = await secondIterator.next()
        XCTAssertNil(firstCompletion)
        XCTAssertNil(secondCompletion)
        let subscriberCountAfterFinish = await stateStream.subscriberCount()
        XCTAssertEqual(subscriberCountAfterFinish, 0)
    }

    func testSubscriptionAfterFinishGetsFinalValueThenTerminates() async {
        let stateStream = RuntimeStateStream("final")
        await stateStream.finish()
        await stateStream.yield("ignored")

        let stream = await stateStream.states()
        var iterator = stream.makeAsyncIterator()
        let finalValue = await iterator.next()
        let completion = await iterator.next()

        XCTAssertEqual(finalValue, "final")
        XCTAssertNil(completion)
    }
}
