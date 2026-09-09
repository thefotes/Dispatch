import XCTest
import AppKit
@testable import WLKit

/// Recovering from a session that died while nobody was looking.
///
/// The bug these pin, in the order it happens: the Mac sleeps, the USB bus
/// powers down, and macOS never delivers the removal callback — so the handle
/// stays non-nil, `deviceConnected` stays true, and the reopen loop is never
/// armed. Nothing writes to the pad overnight either, because `refresh()`
/// returns at its fingerprint guard while the agents sit idle, so nothing
/// ever discovers the session is gone. In the morning the app is confidently
/// connected to a pad that stopped listening hours ago, and the only fix is
/// to quit and relaunch.
///
/// Three things have to be true for that to stop being the fix: a wake has to
/// rebuild the session, a quiet stretch has to be checked rather than
/// assumed, and an open has to be proved before it counts as a connection.
@MainActor
final class ReconnectTests: XCTestCase {

    /// What a dead HID session looks like from up here: the handle is open,
    /// the writes go out, and the answer never comes.
    private let wedged = "IOHIDDeviceSetReport failed (0xE00002E2)"

    private func startedBridge(
        pollInterval: TimeInterval = 2.5
    ) async -> (BridgeController, PadEmulator) {
        let bridge = BridgeController(provider: FakeProvider(), loadBindings: { KeyBindings() })
        await bridge.useEmulator(true)
        guard let emulator = bridge.emulator else {
            fatalError("useEmulator(true) should have installed a virtual pad")
        }
        bridge.config.pollInterval = pollInterval
        await bridge.start()
        XCTAssertTrue(bridge.deviceConnected)
        return (bridge, emulator)
    }

    private func versionCalls(_ emulator: PadEmulator) -> Int {
        emulator.traffic.filter { $0.hasPrefix("sys.version") }.count
    }

    // MARK: - The heartbeat

    /// The gap the heartbeat fills. Herdr has nothing new to say, so the poll
    /// repaints nothing and writes nothing — and a poll that never writes can
    /// never notice that writes have stopped working.
    func testTheProviderPollAloneCannotSeeADeadSession() async {
        let (bridge, emulator) = await startedBridge(pollInterval: 0.05)
        emulator.failEveryCall = wedged

        try? await Task.sleep(nanoseconds: 400_000_000)   // several polls

        XCTAssertTrue(bridge.deviceConnected,
                      "polling the provider is not a liveness check — that is why the heartbeat exists")
        await bridge.probeLiveness()
        XCTAssertFalse(bridge.deviceConnected, "asking the pad directly does see it")
        await bridge.stop()
    }

    /// And having seen it, it hands over to the reopen loop the same way a
    /// genuinely unplugged pad does.
    func testADeadSessionIsDroppedRatherThanRetriedForever() async {
        let (bridge, emulator) = await startedBridge()
        emulator.failEveryCall = wedged

        await bridge.probeLiveness()

        XCTAssertFalse(bridge.deviceConnected)
        XCTAssertEqual(bridge.lastError?.contains("stopped answering"), true, "\(bridge.lastError ?? "nil")")
        await bridge.stop()
    }

    /// The heartbeat is a backstop, not a metronome: traffic the bridge sent
    /// anyway already proved the session, so a busy pad is never asked.
    func testTheHeartbeatStaysQuietWhileTheBridgeIsTalkingToThePadAnyway() async {
        let (bridge, emulator) = await startedBridge()
        let before = versionCalls(emulator)

        await bridge.heartbeatTick()

        XCTAssertEqual(versionCalls(emulator), before, "start() just talked to the pad")
        XCTAssertTrue(bridge.deviceConnected)
        await bridge.stop()
    }

    /// Once it has been quiet for an interval, it does ask.
    func testTheHeartbeatAsksOnceThePadHasBeenQuiet() async {
        let (bridge, emulator) = await startedBridge()
        bridge.config.heartbeatInterval = 0
        let before = versionCalls(emulator)

        await bridge.heartbeatTick()

        XCTAssertEqual(versionCalls(emulator), before + 1)
        XCTAssertTrue(bridge.deviceConnected)
        await bridge.stop()
    }

    // MARK: - Sleep and wake

    /// Closing on the way down is the cheap half: the bus is still there, so
    /// the handle goes away cleanly instead of becoming the stale one.
    func testGoingToSleepClosesTheSession() async {
        let (bridge, _) = await startedBridge()

        bridge.systemWillSleep()

        XCTAssertFalse(bridge.deviceConnected)
        await bridge.stop()
    }

    /// And stands the retry loop down with it: a loop left armed keeps
    /// calling into IOKit right through the transition into sleep, for a pad
    /// that is on its way off the bus.
    func testGoingToSleepStandsDownTheRetryLoop() async {
        let (bridge, emulator) = await startedBridge()
        emulator.failEveryCall = wedged
        await bridge.probeLiveness()
        XCTAssertTrue(bridge.isRetryingToReopen, "a dropped session arms the loop")

        bridge.systemWillSleep()

        XCTAssertFalse(bridge.isRetryingToReopen, "nothing to retry until the Mac is awake")
        await bridge.stop()
    }

    /// Which is only safe because the loop gets armed again from more than
    /// one place. If the wake never arrives — the notification missed, the
    /// sleep abandoned — the heartbeat is what notices that a running bridge
    /// has nothing retrying and puts it back.
    func testTheHeartbeatRearmsARetryThatWentMissing() async {
        let (bridge, emulator) = await startedBridge()
        emulator.failEveryCall = wedged
        await bridge.probeLiveness()
        bridge.systemWillSleep()
        XCTAssertFalse(bridge.isRetryingToReopen)

        await bridge.heartbeatTick()

        XCTAssertTrue(bridge.isRetryingToReopen)
        await bridge.stop()
    }

    /// The other half. Note what is *not* required here: the emulator was
    /// never disconnected, so this is the case where the sleep notification
    /// never arrived and the handle looks perfectly fine. It is opened again
    /// regardless, because looking fine is exactly what the broken one does.
    func testWakingRebuildsTheSessionEvenWhenItLooksHealthy() async {
        let (bridge, emulator) = await startedBridge()
        let before = versionCalls(emulator)

        await bridge.systemDidWake()

        XCTAssertTrue(bridge.deviceConnected)
        XCTAssertGreaterThan(versionCalls(emulator), before,
                             "a wake reopens and re-proves the session rather than trusting it")
        await bridge.stop()
    }

    /// A wake with the pad still unreachable must not paper over it: the
    /// panel says disconnected, and the retry loop keeps trying.
    func testWakingAgainstAPadThatStillDoesNotAnswerReportsTheTruth() async {
        let (bridge, emulator) = await startedBridge()
        emulator.failEveryCall = wedged

        await bridge.systemDidWake()

        XCTAssertFalse(bridge.deviceConnected)
        await bridge.stop()
    }

    /// And when it comes back, the wake is all it takes — no relaunch, and no
    /// waiting on the 3 s retry loop either.
    func testWakingRecoversAWedgedSession() async {
        let (bridge, emulator) = await startedBridge()
        emulator.failEveryCall = wedged
        await bridge.probeLiveness()
        XCTAssertFalse(bridge.deviceConnected)

        emulator.failEveryCall = nil            // the pad is back on the bus
        await bridge.systemDidWake()

        XCTAssertTrue(bridge.deviceConnected)
        await bridge.stop()
    }

    // MARK: - The wiring

    /// The handlers above are only worth anything if they are subscribed, to
    /// the right names, for as long as the bridge is running — which is the
    /// one part calling them directly cannot show. So post the real
    /// notifications instead.
    func testTheWakeNotificationReachesTheBridge() async {
        let (bridge, emulator) = await startedBridge()
        let before = versionCalls(emulator)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(nanoseconds: 300_000_000)   // the handler hops to the main actor

        XCTAssertGreaterThan(versionCalls(emulator), before)
        XCTAssertTrue(bridge.deviceConnected)
        await bridge.stop()
    }

    func testTheSleepNotificationReachesTheBridge() async {
        let (bridge, _) = await startedBridge()

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(bridge.deviceConnected)
        await bridge.stop()
    }

    /// And unsubscribed when it stops: a stopped bridge that still reopened
    /// the pad on every wake would be a bridge you cannot turn off.
    func testAStoppedBridgeIgnoresTheWake() async {
        let (bridge, emulator) = await startedBridge()
        await bridge.stop()
        let before = versionCalls(emulator)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(versionCalls(emulator), before)
        XCTAssertFalse(bridge.deviceConnected)
    }

    // MARK: - An open is not a connection

    /// The failure that made toggling the bridge off and on useless: the BLE
    /// interface opened every time, so the app called it connected every
    /// time, and the probe that would have caught it was a `try?` whose
    /// result went in the bin.
    func testAnInterfaceThatOpensButNeverAnswersIsNotAConnection() async {
        let bridge = BridgeController(provider: FakeProvider(), loadBindings: { KeyBindings() })
        await bridge.useEmulator(true)
        bridge.emulator?.failEveryCall = wedged

        await bridge.start()

        XCTAssertFalse(bridge.deviceConnected)
        XCTAssertEqual(bridge.lastError?.contains("never answered"), true, "\(bridge.lastError ?? "nil")")
        XCTAssertEqual(bridge.firmware, "—", "nothing answered, so there is no version to show")
        await bridge.stop()
    }
}
