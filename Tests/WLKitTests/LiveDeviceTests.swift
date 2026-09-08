import XCTest
@testable import WLKit

/// Reads the keymap off a connected pad. Skipped when no pad is present or the
/// test runner has no Input Monitoring grant, so the suite still passes on a
/// machine without hardware.
///
/// This is worth a live test because the failure it catches is invisible: the
/// firmware answers `{"ok":1}` to a keymap it did not apply, so a pad that
/// silently kept its F-keys looks identical to a bound one from the host side.
final class LiveDeviceTests: XCTestCase {

    private func connected() throws -> WLDevice {
        let device = WLDevice()
        do {
            try device.connect()
        } catch {
            throw XCTSkip("no pad: \(error.localizedDescription)")
        }
        return device
    }

    func testDeviceKeymapHasTheStackKeyBound() async throws {
        let device = try connected()
        defer { device.disconnect(reason: nil) }

        let config = try await KeymapManager.read(device)
        let keymap = try XCTUnwrap(KeymapManager.activeLayerKeymap(config))
        keymap.enumerated().forEach { print("row \($0.offset): \($0.element)") }

        let at = try XCTUnwrap(Pad.position(of: Pad.stackKeyID))
        XCTAssertEqual(keymap[at.row][at.column], "KV_OAI_AG06")
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(config))
    }

    /// A pad that has ever been paired offers more than one interface — the
    /// cable and the Bluetooth node both carry the vendor collection, and
    /// both open. `connect` has to take the best one on the bus rather than
    /// whatever `IOHIDManagerCopyDevices` happened to put first in its `Set`;
    /// taking the other one is a session that opens, reports connected, and
    /// answers nothing.
    func testTheLivePadOpensTheBestInterfaceOnTheBus() throws {
        let device = WLDevice()
        let interfaces: [WLDevice.Candidate]
        do {
            interfaces = try device.availableInterfaces()
        } catch {
            throw XCTSkip("no pad: \(error.localizedDescription)")
        }
        for interface in interfaces {
            print("candidate: registry id \(interface.registryID) · \(interface.transport)"
                  + " · primary usage page \(String(format: "0x%04X", interface.primaryUsagePage))")
        }

        try device.connect()
        defer { device.disconnect(reason: nil) }
        let info = try XCTUnwrap(device.info)
        print("opened: \(info.product) · \(info.transport) · registry id \(info.registryID)")

        XCTAssertEqual(info.registryID, interfaces.first?.registryID,
                       "connect must take the head of the preference order, not a Set's first element")
        XCTAssertNotEqual(info.registryID, 0,
                          "an interface that cannot be named cannot be skipped on a retry")
    }
}
