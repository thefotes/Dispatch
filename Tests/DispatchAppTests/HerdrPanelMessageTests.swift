import DispatchProviders
import XCTest
@testable import DispatchApp

final class HerdrPanelMessageTests: XCTestCase {
    func testDisconnectedWithoutSocketExplainsHowToStartHerdr() {
        XCTAssertEqual(
            HerdrPanelMessage.message(for: .disconnected, socketExists: false),
            "Herdr isn't running. Start Herdr in your terminal. "
                + "If you don't use Herdr, see the README's \"Is this for you?\" section."
        )
    }

    func testDisconnectedWithSocketExplainsConnectionOrProtocolFailure() {
        XCTAssertEqual(
            HerdrPanelMessage.message(for: .disconnected, socketExists: true),
            "Herdr's socket is present, but Dispatch can't connect or understand its response. "
                + "Check that Herdr 0.9.1 or later is running (protocol 22)."
        )
    }

    func testConnectingShowsProgressRegardlessOfSocketPresence() {
        let state = HerdrState(availability: .connecting)
        XCTAssertEqual(HerdrPanelMessage.message(for: state, socketExists: false), "Connecting to Herdr…")
        XCTAssertEqual(HerdrPanelMessage.message(for: state, socketExists: true), "Connecting to Herdr…")
    }

    func testAvailableHasNoGuidanceRegardlessOfSocketPresence() {
        let state = HerdrState(availability: .available)
        XCTAssertNil(HerdrPanelMessage.message(for: state, socketExists: false))
        XCTAssertNil(HerdrPanelMessage.message(for: state, socketExists: true))
    }
}
