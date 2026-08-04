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
}
