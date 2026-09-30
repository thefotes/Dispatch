@testable import DispatchApp
import DispatchCreatorMicro
import Foundation
import XCTest

@MainActor
final class KeymapSetupPreferenceTests: XCTestCase {
    func testPreparedLayoutIsReadyWithoutConsentOrWrites() async throws {
        let defaults = try makeDefaults()
        let storage = EditedKeymapStorage(data: try Self.preparedKeymap())

        let status = try await KeymapSetupPreference(defaults: defaults).statusAfterConnecting {
            try await CreatorMicroKeymapProvisioner.state(using: storage)
        }

        XCTAssertEqual(status, .ready)
        let writes = await storage.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testUserLayoutNeedsConsentWithoutWriting() async throws {
        let defaults = try makeDefaults()
        let storage = EditedKeymapStorage(data: Self.userKeymap)

        let status = try await KeymapSetupPreference(defaults: defaults).statusAfterConnecting {
            try await CreatorMicroKeymapProvisioner.state(using: storage)
        }

        XCTAssertEqual(status, .consentNeeded)
        let writes = await storage.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testPersistedConsentReportsEditedLayoutWithoutWriting() async throws {
        let defaults = try makeDefaults()
        let storage = EditedKeymapStorage(data: try Self.editedDispatchKeymap())
        KeymapSetupPreference(defaults: defaults).setAllowed(true)

        let reconnect = KeymapSetupPreference(defaults: defaults)
        let status = try await reconnect.statusAfterConnecting {
            try await CreatorMicroKeymapProvisioner.state(using: storage)
        }

        XCTAssertEqual(status, .changed)
        let writes = await storage.writeCount
        XCTAssertEqual(writes, 0)
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "DispatchKeymapTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    private static let userKeymap = Data(#"""
    {"activeProfileId":0,"profiles":[{"id":0,"layers":[{"layout":{
    "keymap":[["a","b"],["c","d","e","f"],["g","h","i","j"],["k","l","m"]],
    "encoders":[["cw","ccw","press"]],"joystick":{"sectors":[
    {"k":"down","a1":0.1875,"a2":0.3125},
    {"k":"left","a1":0.4375,"a2":0.5625},
    {"k":"up","a1":0.6875,"a2":0.8125},
    {"k":"right","a1":0.9375,"a2":0.0625}]}}}]}]}
    """#.utf8)

    private static func preparedKeymap() throws -> Data {
        try CreatorMicroKeymapPlanner.plan(original: userKeymap).desired
    }

    private static func editedDispatchKeymap() throws -> Data {
        let text = try XCTUnwrap(String(data: try preparedKeymap(), encoding: .utf8))
        return Data(text.replacingOccurrences(of: "KV_OAI_AG00", with: "my-key").utf8)
    }
}

private actor EditedKeymapStorage: CreatorMicroKeymapStorage {
    let data: Data
    private(set) var writeCount = 0

    init(data: Data) { self.data = data }
    func readKeymap() -> Data { data }
    func readBackup() throws -> Data { throw CreatorMicroError.invalidKeymap("No backup") }
    func writeBackup(_ data: Data) { writeCount += 1 }
    func writeKeymap(_ data: Data) { writeCount += 1 }
    func restoreKeymap(_ data: Data) { writeCount += 1 }
}
