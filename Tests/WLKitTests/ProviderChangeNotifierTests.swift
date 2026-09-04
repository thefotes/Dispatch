import XCTest
@testable import WLKit

final class ProviderChangeNotifierTests: XCTestCase {

    func testNotifyBeforeAnySubscribeDoesNothing() {
        let notifier = ProviderChangeNotifier()
        notifier.notify()   // must not crash with nothing installed
    }

    func testNotifyFiresTheInstalledCallback() {
        let notifier = ProviderChangeNotifier()
        var fired = 0
        // Held for the test's duration — ProviderSubscription cancels
        // itself on deinit, so a discarded token clears the callback
        // immediately, before notify() ever runs.
        let subscription = notifier.subscribe({ fired += 1 }, onTeardown: {})

        notifier.notify()
        notifier.notify()

        XCTAssertEqual(fired, 2)
        withExtendedLifetime(subscription) {}
    }

    func testCancellingClearsTheCallback() {
        let notifier = ProviderChangeNotifier()
        var fired = 0
        let subscription = notifier.subscribe({ fired += 1 }, onTeardown: {})

        subscription.cancel()
        notifier.notify()

        XCTAssertEqual(fired, 0)
    }

    /// `onTeardown` is the provider's own cleanup — it must run exactly
    /// once per cancel, and only after the callback is already cleared, so
    /// a `notify()` racing the cancel never both fires the old callback and
    /// sees teardown incomplete.
    func testCancellingRunsTeardownExactlyOnce() {
        let notifier = ProviderChangeNotifier()
        var teardownCount = 0
        let subscription = notifier.subscribe({}, onTeardown: { teardownCount += 1 })

        subscription.cancel()
        subscription.cancel()

        XCTAssertEqual(teardownCount, 1)
    }

    /// A second `subscribe()` replaces the first — matches how a provider
    /// only ever has one active subscriber (`BridgeController`) at a time.
    func testANewSubscribeReplacesThePreviousCallback() {
        let notifier = ProviderChangeNotifier()
        var firstFired = 0
        var secondFired = 0
        let first = notifier.subscribe({ firstFired += 1 }, onTeardown: {})
        let second = notifier.subscribe({ secondFired += 1 }, onTeardown: {})

        notifier.notify()

        XCTAssertEqual(firstFired, 0)
        XCTAssertEqual(secondFired, 1)
        withExtendedLifetime((first, second)) {}
    }
}
