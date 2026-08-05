import XCTest
@testable import WLKit

/// Exercises the emulator through `WLDevice`, the way the bridge reaches it.
///
/// These run everywhere, with no pad attached — which is the point of having
/// an emulator at all. They pin the firmware behaviours that are invisible on
/// real hardware: silent acceptance of any payload, and keys that cannot light
/// until they are bound.
final class PadEmulatorTests: XCTestCase {

    private func connected() throws -> (WLDevice, PadEmulator) {
        let emulator = PadEmulator()
        let device = WLDevice(emulator: emulator)
        try device.connect()
        XCTAssertTrue(device.isConnected)
        return (device, emulator)
    }

    func testConnectsWithoutHardware() throws {
        let (device, _) = try connected()
        XCTAssertEqual(device.info?.transport, "emulated")
        device.disconnect(reason: nil)
        XCTAssertFalse(device.isConnected)
    }

    func testAnswersTheBaselineCalls() async throws {
        let (device, _) = try connected()
        let version = try await device.callAsync("sys.version") as? [String: Any]
        XCTAssertEqual(version?["version"] as? String, PadEmulator.firmware)

        let status = try await device.callAsync("device.status") as? [String: Any]
        XCTAssertNotNil(status?["battery"])
    }

    func testUnregisteredMethodIsNotFound() async throws {
        let (device, _) = try connected()
        do {
            _ = try await device.callAsync("v.oai.hid")   // a notification, not callable
            XCTFail("expected Method not found")
        } catch {
            XCTAssertTrue("\(error)".contains("Method not found"), "\(error)")
        }
    }

    /// A stock pad ships with F-keys, so nothing can light until the app binds
    /// them. This is the failure that looks like working code on hardware.
    func testStockKeymapBindsNothingUntilApplied() async throws {
        let (device, emulator) = try connected()
        XCTAssertTrue(emulator.bound.isEmpty, "a stock pad has no AG bindings")

        let config = try await KeymapManager.read(device)
        XCTAssertFalse(KeymapManager.isAgentKeymapApplied(config))

        let changed = try await KeymapManager.apply(device)
        XCTAssertTrue(changed)
        for key in Pad.boundKeyIDs {
            XCTAssertTrue(emulator.bound.contains(key), "key \(key) should be bound")
        }
        // The dial and the joystick's cardinals bind too.
        XCTAssertTrue(emulator.bound.isSuperset(of: [Pad.dialUpID, Pad.dialDownID,
                                                     Pad.joyNorthID, Pad.joyEastID,
                                                     Pad.joySouthID, Pad.joyWestID]))
    }

    func testBoundKeyLightsAndUnboundKeyStaysDarkWithoutComplaint() async throws {
        let (device, emulator) = try connected()
        _ = try await KeymapManager.apply(device)

        // Key 19 is inside the firmware's id space but not on the pad, so the
        // app never binds it — the perfect stand-in for an unbound key.
        let threads = [OAI.Thread(id: 0, color: 0xFF0000, brightness: 1, effect: .solid),
                       OAI.Thread(id: 19, color: 0x00FF00, brightness: 1, effect: .solid)]
        let result = try await device.callAsync(OAI.methodThreads,
                                                params: OAI.threadsParams(threads))
        // The firmware says ok to both, which is exactly the trap.
        XCTAssertEqual((result as? [String: Any])?["ok"] as? Int, 1)

        XCTAssertEqual(emulator.keys[0]?.color, 0xFF0000)
        XCTAssertTrue(emulator.keys[0]?.isLit == true)
        XCTAssertTrue(emulator.bound.contains(0))
        XCTAssertFalse(emulator.bound.contains(19), "key 19 is not on the pad")
    }

    func testOmittedFieldsLeaveThatAspectAlone() async throws {
        let (device, emulator) = try connected()
        _ = try await KeymapManager.apply(device)

        _ = try await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(
            [OAI.Thread(id: 2, color: 0x123456, brightness: 1, effect: .solid, speed: 0.4)]))
        // Change only the brightness; colour and effect must survive.
        _ = try await device.callAsync(OAI.methodThreads,
                                       params: [["id": 2, "b": 0.25]])
        XCTAssertEqual(emulator.keys[2]?.color, 0x123456)
        XCTAssertEqual(emulator.keys[2]?.effect, .solid)
        XCTAssertEqual(emulator.keys[2]?.brightness, 0.25)
    }

    func testZonesAreStored() async throws {
        let (device, emulator) = try connected()
        _ = try await device.callAsync(OAI.methodRGBConfig, params: OAI.rgbConfigParams(
            keys: .dark, ambient: OAI.Zone(effect: .solid, brightness: 1, color: 0x00C853)))
        XCTAssertEqual(emulator.ambientZone.color, 0x00C853)
        XCTAssertEqual(emulator.keysZone.effect, .off)
    }

    /// The whole point of the virtual pad: pressing a key drives the app.
    func testPressingABoundKeyPushesAHIDReport() async throws {
        let (device, emulator) = try connected()
        _ = try await KeymapManager.apply(device)

        let press = expectation(description: "press reported")
        var seen: [Int] = []
        device.onNotification = { method, params in
            guard method == OAI.notifyHID,
                  let dict = params as? [String: Any],
                  let index = OAI.agIndex(dict["k"] as? String),
                  (dict["act"] as? Int) == 1
            else { return }
            seen.append(index)
            press.fulfill()
        }

        emulator.press(4)
        await fulfillment(of: [press], timeout: 2)
        XCTAssertEqual(seen, [4])
    }

    /// An unbound key sends a keystroke on real hardware, not a report.
    func testPressingAnUnboundKeyReportsNothing() throws {
        let (device, emulator) = try connected()
        var reports = 0
        device.onNotification = { method, _ in
            if method == OAI.notifyHID { reports += 1 }
        }
        emulator.press(0)   // still the stock keymap: nothing is bound
        XCTAssertEqual(reports, 0)
    }

    func testResetReturnsAStockPad() async throws {
        let (device, emulator) = try connected()
        _ = try await KeymapManager.apply(device)
        XCTAssertFalse(emulator.bound.isEmpty)

        emulator.reset()
        XCTAssertTrue(emulator.bound.isEmpty)
        XCTAssertTrue(emulator.keys.isEmpty)
    }
}
