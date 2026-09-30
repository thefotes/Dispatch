import DispatchCore
import XCTest

final class EventBroadcastTests: XCTestCase {
    func testCancellingOneConsumerDoesNotEndLaterSubscriptions() async throws {
        let broadcast = EventBroadcast<Int>()
        let first = Task {
            for await _ in broadcast.subscribe() {}
        }
        first.cancel()
        await first.value

        let second = broadcast.subscribe()
        broadcast.yield(7)
        broadcast.finish()

        var received: [Int] = []
        for await value in second { received.append(value) }
        XCTAssertEqual(received, [7])
    }

    func testEverySubscriberReceivesEachValue() async throws {
        let broadcast = EventBroadcast<Int>()
        let first = broadcast.subscribe()
        let second = broadcast.subscribe()
        broadcast.yield(1)
        broadcast.finish()

        var firstValues: [Int] = []
        for await value in first { firstValues.append(value) }
        var secondValues: [Int] = []
        for await value in second { secondValues.append(value) }
        XCTAssertEqual(firstValues, [1])
        XCTAssertEqual(secondValues, [1])
    }

    func testSubscriptionAfterFinishEndsImmediately() async throws {
        let broadcast = EventBroadcast<Int>()
        broadcast.finish()
        broadcast.yield(1)

        var received: [Int] = []
        for await value in broadcast.subscribe() { received.append(value) }
        XCTAssertEqual(received, [])
    }
}
