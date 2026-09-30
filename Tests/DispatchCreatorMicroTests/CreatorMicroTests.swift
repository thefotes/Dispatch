import DispatchCore
import DispatchCreatorMicro
import Foundation
import IOKit.hid
import XCTest

final class HIDFramingTests: XCTestCase {
    func testReportRoundTripAndFragmentation() throws {
        let data = Data(repeating: 0x41, count: 140)
        let reports = try CreatorMicroHIDReport.fragment(data)
        XCTAssertEqual(reports.map(\.payload.count), [61, 61, 18])
        XCTAssertEqual(try reports.map { try CreatorMicroHIDReport(bytes: $0.bytes) }, reports)
        XCTAssertEqual(Data(reports.flatMap(\.payload)), data)
    }

    func testAssemblerHandlesSplitAndCoalescedObjectsAndQuotedBraces() throws {
        var assembler = JSONMessageAssembler()
        XCTAssertTrue(try assembler.append(Array(#"{"m":"x","p":{"text":"}""# .utf8)).isEmpty)
        let messages = try assembler.append(Array(#"}} {"id":4,"r":1}"#.utf8))
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(try CreatorMicroRPCMessage.decode(messages[0]), .notification(
            method: "x",
            parameters: .object(["text": .string("}")])
        ))
        XCTAssertEqual(
            try CreatorMicroRPCMessage.decode(messages[1]),
            .response(id: 4, result: .integer(1), error: nil)
        )
    }

    func testInvalidReportIsRejected() {
        XCTAssertThrowsError(try CreatorMicroHIDReport(bytes: [0x06]))
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x05
        XCTAssertThrowsError(try CreatorMicroHIDReport(bytes: bytes))
    }

    func testAssemblerRejectsOversizeObjectAndResets() throws {
        var assembler = JSONMessageAssembler()
        let oversized = Array("{\"x\":\"".utf8)
            + [UInt8](repeating: 0x61, count: JSONMessageAssembler.maximumMessageBytes)
        XCTAssertThrowsError(try assembler.append(oversized)) { error in
            XCTAssertEqual(error as? CreatorMicroError, .messageTooLarge)
        }
        XCTAssertEqual(try assembler.append(Array("{\"id\":1}".utf8)), [Data("{\"id\":1}".utf8)])
    }

    func testAssemblerRejectsStrayUTF8Continuation() throws {
        var assembler = JSONMessageAssembler()
        XCTAssertThrowsError(try assembler.append(Array("{\"x\":\"".utf8) + [0x80])) { error in
            XCTAssertEqual(error as? CreatorMicroError, .invalidUTF8)
        }
    }
}

final class CreatorMicroErrorDescriptionTests: XCTestCase {
    func testPermissionSecureInputAndMissingDeviceErrorsExplainThemselves() {
        XCTAssertEqual(
            String(describing: CreatorMicroError.ioKit(kIOReturnNotPermitted)),
            "Input Monitoring is off for Dispatch. Turn it on in System Settings > "
                + "Privacy & Security > Input Monitoring."
        )
        XCTAssertEqual(String(describing: CreatorMicroError.ioKit(kIOReturnNoDevice)), "The pad is not plugged in.")
        XCTAssertEqual(String(describing: CreatorMicroError.ioKit(kIOReturnBusy)), "IOKit error 0xE00002D5.")
        XCTAssertEqual(
            String(describing: CreatorMicroError.secureInputHeld(.application("Ghostty"))),
            "Ghostty has Secure Input turned on, which blocks the pad. Leave any password field in Ghostty, "
                + "turn off its Secure Keyboard Entry, or lock and unlock the screen."
        )
        XCTAssertEqual(
            String(describing: CreatorMicroError.secureInputHeld(.stale)),
            "Secure Input is stuck on, which blocks the pad. Lock and unlock the screen to reset it."
        )
        XCTAssertEqual(
            String(describing: CreatorMicroError.remoteError(code: 4, message: "Bad key")),
            "The pad rejected the request: Bad key (4)"
        )
    }
}

final class RequestIDTests: XCTestCase {
    func testWraparoundSkipsAllocatedIdentifiers() throws {
        var allocator = RequestIDAllocator(startingAt: 999)
        XCTAssertEqual(try allocator.allocate(), 999)
        XCTAssertEqual(try allocator.allocate(), 0)
        allocator.release(999)
        for expected in 1...998 { XCTAssertEqual(try allocator.allocate(), expected) }
        XCTAssertEqual(try allocator.allocate(), 999)
        XCTAssertThrowsError(try allocator.allocate())
    }

    func testForeignResponseDoesNotCompleteOwnedRequest() async throws {
        let transport = FakeTransport()
        let session = CreatorMicroRPCSession(transport: transport)
        try await session.connect()
        let call = Task { try await session.call(method: "sys.version", timeout: .seconds(2)) }
        let sent = try await transport.waitForSentReport()
        let request = try CreatorMicroHIDReport(bytes: sent)
        let requestValue = try JSONDecoder().decode(JSONValue.self, from: Data(request.payload))
        guard case let .object(object) = requestValue else { return XCTFail("Expected request object") }
        guard case let .integer(id)? = object["id"] else { return XCTFail("Expected request id") }

        try await transport.receive(json: #"{"id":999,"r":"foreign"}"#)
        XCTAssertFalse(call.isCancelled)
        try await transport.receive(json: "{\"id\":\(id),\"r\":\"owned\"}")
        let result = try await call.value
        XCTAssertEqual(result, .string("owned"))
        await session.disconnect()
    }

    func testMalformedReportDoesNotPoisonLaterResponses() async throws {
        let transport = FakeTransport()
        let session = CreatorMicroRPCSession(transport: transport)
        try await session.connect()
        let call = Task { try await session.call(method: "sys.version", timeout: .seconds(2)) }
        let sent = try await transport.waitForSentReport()
        let request = try CreatorMicroHIDReport(bytes: sent)
        let requestValue = try JSONDecoder().decode(JSONValue.self, from: Data(request.payload))
        guard case let .object(object) = requestValue else { return XCTFail("Expected request object") }
        guard case let .integer(id)? = object["id"] else { return XCTFail("Expected request id") }

        var poisoned = [UInt8](Data(#"{"broken":"#.utf8))
        poisoned.append(0xFF)
        for report in try CreatorMicroHIDReport.fragment(Data(poisoned)) {
            await transport.receiveBytes(report.bytes)
        }
        try await transport.receive(json: "{\"id\":\(id),\"r\":\"recovered\"}")
        let result = try await call.value
        XCTAssertEqual(result, .string("recovered"))
        await session.disconnect()
    }

    func testGarbageMidResponseResynchronizesWithinReport() async throws {
        let transport = FakeTransport()
        let session = CreatorMicroRPCSession(transport: transport)
        try await session.connect()
        let call = Task { try await session.call(method: "sys.version", timeout: .seconds(2)) }
        let request = try await transport.waitForSentMessage()
        guard case let .integer(id)? = request["id"] else { return XCTFail("Expected request id") }

        let broken = Array("{\"id\":\"broken".utf8) + [0xFF]
        let response = Array("{\"id\":\(id),\"r\":\"recovered\"}".utf8)
        for report in try CreatorMicroHIDReport.fragment(Data(broken + response)) {
            await transport.receiveBytes(report.bytes)
        }
        let result = try await call.value
        XCTAssertEqual(result, .string("recovered"))
        await session.disconnect()
    }

    func testMalformedReportEnvelopeDoesNotDiscardAFragmentedResponse() async throws {
        let transport = FakeTransport()
        let session = CreatorMicroRPCSession(transport: transport)
        try await session.connect()
        let call = Task { try await session.call(method: "sys.version", timeout: .seconds(2)) }
        let sent = try await transport.waitForSentReport()
        let request = try CreatorMicroHIDReport(bytes: sent)
        let requestValue = try JSONDecoder().decode(JSONValue.self, from: Data(request.payload))
        guard case let .object(object) = requestValue else { return XCTFail("Expected request object") }
        guard case let .integer(id)? = object["id"] else { return XCTFail("Expected request id") }

        let response = Data("{\"id\":\(id),\"r\":\"\(String(repeating: "x", count: 100))\"}".utf8)
        let fragments = try CreatorMicroHIDReport.fragment(response)
        XCTAssertGreaterThan(fragments.count, 1)
        await transport.receiveBytes(fragments[0].bytes)
        var malformedEnvelope = fragments[0].bytes
        malformedEnvelope[0] = 0xFF
        await transport.receiveBytes(malformedEnvelope)
        for fragment in fragments.dropFirst() {
            await transport.receiveBytes(fragment.bytes)
        }

        let result = try await call.value
        XCTAssertEqual(result, .string(String(repeating: "x", count: 100)))
        await session.disconnect()
    }
}

final class KeymapStorageTests: XCTestCase {
    func testReadKeymapNamesTheFileWithTheFileParameter() async throws {
        let transport = FakeTransport()
        let session = CreatorMicroRPCSession(transport: transport)
        try await session.connect()
        let storage = CreatorMicroRPCKeymapStorage(session: session)
        let read = Task { try await storage.readKeymap() }

        let sent = try CreatorMicroHIDReport(bytes: try await transport.waitForSentReport())
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(sent.payload))
        guard case let .object(object) = request else { return XCTFail("Expected request object") }
        XCTAssertEqual(object["m"], .string("fs.read"))
        XCTAssertEqual(object["p"], .object(["file": .string("keymap.json")]))
        guard case let .integer(id)? = object["id"] else { return XCTFail("Expected request id") }

        try await transport.receive(json: "{\"id\":\(id),\"r\":{\"data\":\"{}\"}}")
        let keymap = try await read.value
        XCTAssertEqual(keymap, Data("{}".utf8))
        await session.disconnect()
    }

    func testKeymapWritesBackUpFirstAndNameTheFileWithTheFileParameter() async throws {
        let transport = FakeTransport()
        let session = CreatorMicroRPCSession(transport: transport)
        try await session.connect()
        let storage = CreatorMicroRPCKeymapStorage(session: session)
        let backup = Task { try await storage.writeBackup(Data("{\"a\":1}".utf8)) }

        let backupWrite = try await transport.waitForSentMessage()
        XCTAssertEqual(backupWrite["m"], .string("fs.write"))
        XCTAssertEqual(backupWrite["p"], .object([
            "file": .string("keymap.dispatch-backup.json"),
            "data": .string("{\"a\":1}")
        ]))
        try await transport.respond(to: backupWrite, with: "null")
        try await backup.value

        let keymap = Task { try await storage.writeKeymap(Data("{\"b\":2}".utf8)) }
        let keymapWrite = try await transport.waitForSentMessage()
        XCTAssertEqual(keymapWrite["m"], .string("fs.write"))
        XCTAssertEqual(keymapWrite["p"], .object([
            "file": .string("keymap.json"),
            "data": .string("{\"b\":2}")
        ]))
        try await transport.respond(to: keymapWrite, with: "null")
        try await keymap.value
        await session.disconnect()
    }

    func testKeymapWriteIsRefusedBeforeBackupWithoutSendingFsWrite() async throws {
        let transport = FakeTransport()
        let session = CreatorMicroRPCSession(transport: transport)
        try await session.connect()
        let storage = CreatorMicroRPCKeymapStorage(session: session)

        do {
            try await storage.writeKeymap(Data("{}".utf8))
            XCTFail("Expected the write to be refused")
        } catch {
            XCTAssertNotNil(error as? CreatorMicroError)
        }
        do {
            _ = try await transport.waitForSentReport()
            XCTFail("Expected no fs.write request")
        } catch {
            XCTAssertEqual(error as? CreatorMicroError, .timeout)
        }
        await session.disconnect()
    }

    func testDirectRestoreIsRefusedBeforeBackupWithoutSendingFsWrite() async throws {
        let transport = FakeTransport()
        let session = CreatorMicroRPCSession(transport: transport)
        try await session.connect()
        let storage = CreatorMicroRPCKeymapStorage(session: session)

        do {
            try await storage.restoreKeymap(Data("{}".utf8))
            XCTFail("Expected restore to be refused")
        } catch {
            XCTAssertEqual(
                error as? CreatorMicroError,
                .invalidKeymap("Refusing to write before backup")
            )
        }
        do {
            _ = try await transport.waitForSentReport()
            XCTFail("Expected no fs.write request")
        } catch {
            XCTAssertEqual(error as? CreatorMicroError, .timeout)
        }
        await session.disconnect()
    }

    func testListFilesReturnsTheUninterpretedListing() async throws {
        let transport = FakeTransport()
        let session = CreatorMicroRPCSession(transport: transport)
        try await session.connect()
        let storage = CreatorMicroRPCKeymapStorage(session: session)
        let list = Task { try await storage.listFiles() }

        let sent = try CreatorMicroHIDReport(bytes: try await transport.waitForSentReport())
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(sent.payload))
        guard case let .object(object) = request else { return XCTFail("Expected request object") }
        XCTAssertEqual(object["m"], .string("fs.list"))
        XCTAssertEqual(object["p"], .object(["checksum": .boolean(false), "rec": .boolean(true)]))
        guard case let .integer(id)? = object["id"] else { return XCTFail("Expected request id") }

        try await transport.receive(json: "{\"id\":\(id),\"r\":[\"keymap.json\"]}")
        let listing = try await list.value
        XCTAssertEqual(listing, .array([.string("keymap.json")]))
        await session.disconnect()
    }
}

final class IOHIDMatchingTests: XCTestCase {
    /// The vendor collection shares one interface with the keyboard collection,
    /// so it appears among the device usage pairs rather than as the primary usage.
    func testMatchesVendorCollectionAmongDeviceUsagePairs() {
        let matching = IOHIDCreatorMicroTransport.deviceMatching
        XCTAssertEqual(matching, [
            kIOHIDVendorIDKey: 0x303A,
            kIOHIDDeviceUsagePageKey: 0xFF00,
            kIOHIDDeviceUsageKey: 0x01
        ])
        XCTAssertNil(matching[kIOHIDPrimaryUsagePageKey])
        XCTAssertNil(matching[kIOHIDPrimaryUsageKey])
    }
}

final class GeometryAndDecodingTests: XCTestCase {
    private let source = DeviceIdentity(rawValue: "desk")
    private let timestamp = Date(timeIntervalSince1970: 123)

    func testGeometryReadingOrderAndWideKey() {
        XCTAssertEqual(CreatorMicroGeometry.rowWidths, [2, 4, 4, 3])
        XCTAssertEqual(CreatorMicroGeometry.initialAgentSlots, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(CreatorMicroGeometry.position(forMatrixIndex: 10)?.isWide, true)
        XCTAssertEqual(CreatorMicroGeometry.position(forMatrixIndex: 11)?.isWide, true)
        XCTAssertEqual(CreatorMicroGeometry.position(forMatrixIndex: 12)?.isWide, false)
        XCTAssertEqual(CreatorMicroGeometry.position(forMatrixIndex: 12)?.row, 3)
    }

    func testVendorHIDMapsToDomainWithoutLeakingVendorCode() throws {
        var decoder = CreatorMicroVendorDecoder(source: source)
        let key = try decoder.decode(hid("AG09", pressed: true), timestamp: timestamp)
        XCTAssertEqual(key, DispatchEvent(source: source, control: .key(9), gesture: .pressed, timestamp: timestamp))
        let released = try decoder.decode(hid("AG12", pressed: false), timestamp: timestamp)
        XCTAssertEqual(released?.control, .key(12))
        XCTAssertEqual(released?.gesture, .released)
    }

    func testDialDetentIsOneStepInEachDirection() throws {
        var decoder = CreatorMicroVendorDecoder(source: source)
        XCTAssertEqual(try decoder.decode(hid("AG13", pressed: true))?.gesture, .rotated(steps: 1))
        XCTAssertNil(try decoder.decode(hid("AG13", pressed: false)))
        XCTAssertEqual(try decoder.decode(hid("AG14", pressed: true))?.gesture, .rotated(steps: -1))
        XCTAssertNil(try decoder.decode(hid("AG14", pressed: false)))
    }

    func testJoystickPushIsOneMoveInTheObservedDirection() throws {
        var decoder = CreatorMicroVendorDecoder(source: source)
        let pushes = try (15...18).map { try decoder.decode(hid("AG\($0)", pressed: true))?.gesture }
        XCTAssertEqual(pushes, [
            .moved(direction: .down, magnitude: 1),
            .moved(direction: .left, magnitude: 1),
            .moved(direction: .up, magnitude: 1),
            .moved(direction: .right, magnitude: 1)
        ])
        XCTAssertNil(try decoder.decode(hid("AG17", pressed: false)))
    }

    func testWideKeySwitchesAreOneControl() throws {
        var decoder = CreatorMicroVendorDecoder(source: source)
        let sequence = [("AG11", true), ("AG10", true), ("AG10", false), ("AG11", false)]
        let events = try sequence.map { try decoder.decode(hid($0.0, pressed: $0.1)) }
        XCTAssertEqual(events.map { $0?.control }, [.key(10), nil, nil, .key(10)])
        XCTAssertEqual(events.map { $0?.gesture }, [.pressed, nil, nil, .released])
    }

    /// Replays key 9 chatter observed 2026-09-29: during one physical press
    /// the pad reported a release, then a press 6 ms later, then a release.
    func testChatterAfterAReleaseIsNotASecondPress() throws {
        var decoder = CreatorMicroVendorDecoder(source: source)
        let events = try [(0, true), (38, false), (44, true), (58, false)].map {
            try decoder.decode(hid("AG09", pressed: $0.1), timestamp: at(milliseconds: $0.0))
        }
        XCTAssertEqual(events.map { $0?.gesture }, [.pressed, .released, nil, nil])
        XCTAssertEqual(events.map { $0?.timestamp }, [at(milliseconds: 0), at(milliseconds: 38), nil, nil])
    }

    /// The fastest deliberate taps observed 2026-09-29 came 29 ms after the
    /// previous release.
    func testRapidDeliberateTapsAreAllPresses() throws {
        var decoder = CreatorMicroVendorDecoder(source: source)
        let sequence = [(0, true), (71, false), (100, true), (166, false), (197, true), (240, false)]
        let events = try sequence.map {
            try decoder.decode(hid("AG09", pressed: $0.1), timestamp: at(milliseconds: $0.0))
        }
        XCTAssertEqual(events.map { $0?.gesture }, [.pressed, .released, .pressed, .released, .pressed, .released])
    }

    func testChatterOnOneKeyDoesNotSuppressAnother() throws {
        var decoder = CreatorMicroVendorDecoder(source: source)
        _ = try decoder.decode(hid("AG09", pressed: true), timestamp: at(milliseconds: 0))
        _ = try decoder.decode(hid("AG09", pressed: false), timestamp: at(milliseconds: 40))
        let other = try decoder.decode(hid("AG08", pressed: true), timestamp: at(milliseconds: 45))
        XCTAssertEqual(other?.control, .key(8))
        XCTAssertEqual(other?.gesture, .pressed)
    }

    func testWideKeyChatterIsNotASecondPress() throws {
        var decoder = CreatorMicroVendorDecoder(source: source)
        let events = try [("AG10", 0, true), ("AG10", 40, false), ("AG11", 46, true), ("AG11", 60, false)].map {
            try decoder.decode(hid($0.0, pressed: $0.2), timestamp: at(milliseconds: $0.1))
        }
        XCTAssertEqual(events.map { $0?.gesture }, [.pressed, .released, nil, nil])
    }

    private func at(milliseconds: Int) -> Date {
        timestamp.addingTimeInterval(Double(milliseconds) / 1000)
    }

    private func hid(_ code: String, pressed: Bool) -> CreatorMicroRPCMessage {
        .notification(method: "v.oai.hid", parameters: .object(["k": .string(code), "act": .integer(pressed ? 1 : 0)]))
    }
}

final class LightingTests: XCTestCase {
    func testPresentationConversionClampsBrightness() {
        let presentation = PadPresentation(
            controls: [
                .key(2): ControlAppearance(
                    color: RGBColor(red: 1, green: 2, blue: 3),
                    brightness: 2,
                    effect: .shallowBreath,
                    speed: 0.5
                )
            ],
            ambient: ControlAppearance(color: RGBColor(red: 4, green: 5, blue: 6), brightness: -1)
        )
        let frame = CreatorMicroDriver.lightingFrame(for: presentation)
        XCTAssertEqual(frame.threads[2]?.color.packedRGB, 0x010203)
        XCTAssertEqual(frame.threads[2]?.brightness, 255)
        XCTAssertEqual(frame.threads[2]?.effect, .shallowBreath)
        XCTAssertEqual(frame.threads[2]?.speed, 128)
        XCTAssertEqual(frame.ambientZone.brightness, 0)
    }

    func testPresentationConversionTreatsNaNAsDark() {
        let presentation = PadPresentation(
            controls: [
                .key(2): ControlAppearance(color: RGBColor(red: 1, green: 2, blue: 3), brightness: .nan, speed: .nan)
            ],
            ambient: ControlAppearance(color: RGBColor(red: 4, green: 5, blue: 6), brightness: .nan)
        )
        let frame = CreatorMicroDriver.lightingFrame(for: presentation)
        XCTAssertEqual(frame.threads[2]?.brightness, 0)
        XCTAssertEqual(frame.threads[2]?.speed, 0)
        XCTAssertEqual(frame.ambientZone.brightness, 0)
    }

    func testWideKeyLightsBothOfItsThreads() {
        let appearance = ControlAppearance(color: RGBColor(red: 9, green: 8, blue: 7))
        let frame = CreatorMicroDriver.lightingFrame(for: PadPresentation(controls: [.key(10): appearance]))
        XCTAssertEqual(frame.threads.keys.sorted(), [10, 11])
        XCTAssertEqual(frame.threads[10], frame.threads[11])
    }

    func testDiffSendsOnlyChangedThreadsAndClearsRemovedThread() {
        let red = CreatorMicroLight(color: .init(red: 255, green: 0, blue: 0))
        let previous = CreatorMicroLightingFrame(threads: [1: red, 2: red])
        let desired = CreatorMicroLightingFrame(threads: [1: red])
        let update = CreatorMicroLightingEncoder.update(from: previous, to: desired)
        guard case let .array(changes)? = update.threadParameters else { return XCTFail("Expected changes") }
        XCTAssertEqual(changes.count, 1)
        guard case let .object(change) = changes[0] else { return XCTFail("Expected change object") }
        XCTAssertEqual(change["id"], .number(2))
        XCTAssertEqual(change["e"], .number(0))
        XCTAssertNil(update.zoneParameters)
    }

    func testClearAllIncludesTwentyThreadsAndBothDarkZones() {
        let update = CreatorMicroLightingEncoder.clearAll()
        guard case let .array(threads)? = update.threadParameters else { return XCTFail("Expected threads") }
        XCTAssertEqual(threads.count, 13)
        XCTAssertNotNil(update.zoneParameters)
    }

    func testFirstFrameClearsEveryUnspecifiedThread() {
        let update = CreatorMicroLightingEncoder.update(
            from: nil,
            to: CreatorMicroLightingFrame(threads: [3: .init(color: .init(red: 1, green: 2, blue: 3))])
        )
        guard case let .array(threads)? = update.threadParameters else { return XCTFail("Expected threads") }
        XCTAssertEqual(threads.count, 13)
        guard case let .object(thread) = threads[3] else { return XCTFail("Expected thread object") }
        XCTAssertEqual(thread["id"], .number(3))
        XCTAssertEqual(thread["e"], .number(1))
    }
}

final class KeymapTests: XCTestCase {
    func testPlanBindsActiveProfileFirstLayerAndPreservesEverythingElse() throws {
        let plan = try CreatorMicroKeymapPlanner.plan(original: Data(Self.unpreparedKeymap.utf8))
        let planned = try JSONDecoder().decode(JSONValue.self, from: plan.desired)
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(Self.preparedKeymap.utf8))
        XCTAssertEqual(planned, expected)
        XCTAssertEqual(plan.backup, Data(Self.unpreparedKeymap.utf8))
        XCTAssertTrue(plan.verifies(readBack: plan.desired))
    }

    func testAlreadyPreparedKeymapVerifiesUnchanged() throws {
        let original = Data(Self.preparedKeymap.utf8)
        XCTAssertTrue(try CreatorMicroKeymapPlanner.plan(original: original).verifies(readBack: original))
    }

    func testNegativeActiveProfileUsesProfileZero() throws {
        let original = Self.unpreparedKeymap
            .replacingOccurrences(of: #""activeProfileId":7"#, with: #""activeProfileId":-2"#)
        let plan = try CreatorMicroKeymapPlanner.plan(original: Data(original.utf8))
        guard case let .object(root) = try JSONDecoder().decode(JSONValue.self, from: plan.desired),
              case let .array(profiles)? = root["profiles"],
              case let .object(profileZero) = profiles[1] else { return XCTFail("Expected profiles") }
        XCTAssertEqual(profileZero["id"], .integer(0))
        XCTAssertTrue(plan.desired.range(of: Data("KV_OAI_AG12".utf8)) != nil)
    }

    func testIncompatibleLayoutIsRejectedWithoutAPlan() {
        let flat = Self.unpreparedKeymap.replacingOccurrences(of: #"["old0","old1"],"#, with: "")
        XCTAssertThrowsError(try CreatorMicroKeymapPlanner.plan(original: Data(flat.utf8)))
        let noCardinal = Self.unpreparedKeymap
            .replacingOccurrences(of: #""a1":0.1875,"a2":0.3125"#, with: #""a1":0.2,"a2":0.4"#)
        XCTAssertThrowsError(try CreatorMicroKeymapPlanner.plan(original: Data(noCardinal.utf8)))
    }

    func testProvisioningDoesNotWriteAnAlreadyPreparedKeymap() async throws {
        let storage = RecordingKeymapStorage(data: Data(Self.preparedKeymap.utf8))
        try await CreatorMicroKeymapProvisioner.provision(using: storage)
        let counts = await storage.writeCounts()
        XCTAssertEqual(counts.backups, 0)
        XCTAssertEqual(counts.keymaps, 0)
    }

    func testChangedKeymapBacksUpBeforeWritingAndVerifies() async throws {
        let storage = RecordingKeymapStorage(data: Data(Self.unpreparedKeymap.utf8))
        try await CreatorMicroKeymapProvisioner.provision(using: storage)
        let counts = await storage.writeCounts()
        XCTAssertEqual(counts.backups, 1)
        XCTAssertEqual(counts.keymaps, 1)
    }

    func testChangedLayoutIsReportedWithoutWriting() async throws {
        let storage = RecordingKeymapStorage(data: Data(Self.unpreparedKeymap.utf8))
        let state = try await CreatorMicroKeymapProvisioner.state(using: storage)
        XCTAssertEqual(state, .changed)
        let counts = await storage.writeCounts()
        XCTAssertEqual(counts.backups, 0)
        XCTAssertEqual(counts.keymaps, 0)
    }

    func testBackupIsRefreshedFromLatestUserLayout() async throws {
        let storage = RecordingKeymapStorage(data: Data(Self.unpreparedKeymap.utf8))
        try await CreatorMicroKeymapProvisioner.provision(using: storage)
        let edited = Data(Self.unpreparedKeymap.replacingOccurrences(of: "old0", with: "edited0").utf8)
        await storage.replaceKeymap(edited)
        try await CreatorMicroKeymapProvisioner.provision(using: storage)
        let backup = await storage.backup()
        XCTAssertEqual(backup, edited)
    }

    func testPartialDispatchLayoutPreservesOriginalBackup() async throws {
        let original = Data(Self.unpreparedKeymap.utf8)
        let storage = RecordingKeymapStorage(data: original)
        try await CreatorMicroKeymapProvisioner.provision(using: storage)
        let partial = Data(Self.preparedKeymap.replacingOccurrences(of: "KV_OAI_AG01", with: "edited1").utf8)
        await storage.replaceKeymap(partial)
        try await CreatorMicroKeymapProvisioner.provision(using: storage)
        let backup = await storage.backup()
        XCTAssertEqual(backup, original)
        let counts = await storage.writeCounts()
        XCTAssertEqual(counts.backups, 1)
    }

    func testRestoreWritesBackupAndVerifiesReadBack() async throws {
        let original = Data(Self.unpreparedKeymap.utf8)
        let storage = RecordingKeymapStorage(data: Data(Self.preparedKeymap.utf8), backup: original)
        try await CreatorMicroKeymapProvisioner.restore(using: storage)
        let restored = try await storage.readKeymap()
        let backup = await storage.backup()
        XCTAssertEqual(restored, original)
        XCTAssertEqual(backup, original)
    }

    func testRestoreFailsWithoutBackupOrOnMismatch() async throws {
        let storage = RecordingKeymapStorage(data: Data(Self.preparedKeymap.utf8))
        do {
            try await CreatorMicroKeymapProvisioner.restore(using: storage)
            XCTFail("Expected missing backup")
        } catch {
            XCTAssertTrue(String(describing: error).contains("No Dispatch backup"))
        }
        await storage.setBackup(Data(Self.unpreparedKeymap.utf8))
        await storage.ignoreRestoreWrites()
        do {
            try await CreatorMicroKeymapProvisioner.restore(using: storage)
            XCTFail("Expected verification failure")
        } catch {
            XCTAssertEqual(error as? CreatorMicroError, .verificationFailed)
        }
    }

    func testFailedBackupPreventsKeymapWrite() async throws {
        let storage = RecordingKeymapStorage(data: Data(Self.unpreparedKeymap.utf8))
        await storage.failBackupWrites()
        do {
            try await CreatorMicroKeymapProvisioner.provision(using: storage)
            XCTFail("Expected backup failure")
        } catch {
            XCTAssertNotNil(error as? CreatorMicroError)
        }
        let counts = await storage.writeCounts()
        XCTAssertEqual(counts.keymaps, 0)
    }

    /// Shaped like the `keymap.json` read from firmware 0.6.2, with a second
    /// profile so the active profile is found by identifier, not position.
    private static let unpreparedKeymap = #"""
    {"version":1,"activeProfileId":7,"macros":[{"id":0,"color":null,"actions":[]}],"profiles":[
    {"id":7,"layers":[{"id":0,"layout":{
    "keymap":[["old0","old1"],["old2","old3","old4","old5"],["old6","old7","old8","old9"],["old10","old11","old12"]],
    "encoders":[["oldCW","oldCCW","KC_MPLY"]],
    "joystick":{"type":"RADIAL","sectors":[
    {"k":"oldDown","a1":0.1875,"a2":0.3125},{"k":"KC_P1","a1":0.3125,"a2":0.4375},
    {"k":"oldLeft","a1":0.4375,"a2":0.5625},{"k":"KC_P3","a1":0.5625,"a2":0.6875},
    {"k":"oldUp","a1":0.6875,"a2":0.8125},{"k":"KC_P5","a1":0.8125,"a2":0.9375},
    {"k":"oldRight","a1":0.9375,"a2":0.0625},{"k":"KC_P7","a1":0.0625,"a2":0.1875}]}},
    "lights":{"underglow":{"effect":"rainbow","brightness":1,"speed":0.55}}},
    {"id":1,"layout":{"keymap":[["KC_NONE"]],"encoders":[],"joystick":{"type":"JOYSTICK","sectors":[]}}}]},
    {"id":0,"layers":[{"id":0,"layout":{
    "keymap":[["a","b"],["c","d","e","f"],["g","h","i","j"],["k","l","m"]],
    "encoders":[["cw","ccw","press"]],
    "joystick":{"type":"RADIAL","sectors":[
    {"k":"s","a1":0.1875,"a2":0.3125},{"k":"w","a1":0.4375,"a2":0.5625},
    {"k":"n","a1":0.6875,"a2":0.8125},{"k":"e","a1":0.9375,"a2":0.0625}]}}}]}]}
    """#

    private static let preparedKeymap = unpreparedKeymap
        .replacingOccurrences(of: #""old(\d+)""#, with: "\"KV_OAI_AG$1\"", options: .regularExpression)
        .replacingOccurrences(of: #""KV_OAI_AG(\d)""#, with: "\"KV_OAI_AG0$1\"", options: .regularExpression)
        .replacingOccurrences(of: "oldCW", with: "KV_OAI_AG13")
        .replacingOccurrences(of: "oldCCW", with: "KV_OAI_AG14")
        .replacingOccurrences(of: "oldDown", with: "KV_OAI_AG15")
        .replacingOccurrences(of: "oldLeft", with: "KV_OAI_AG16")
        .replacingOccurrences(of: "oldUp", with: "KV_OAI_AG17")
        .replacingOccurrences(of: "oldRight", with: "KV_OAI_AG18")
}

private actor RecordingKeymapStorage: CreatorMicroKeymapStorage {
    private var data: Data
    private var backupData: Data?
    private var backupWrites = 0
    private var keymapWrites = 0
    private var ignoreRestore = false
    private var failBackup = false

    init(data: Data, backup: Data? = nil) {
        self.data = data
        backupData = backup
    }
    func readKeymap() async throws -> Data { data }
    func readBackup() async throws -> Data {
        guard let backupData else { throw CreatorMicroError.invalidKeymap("No Dispatch backup exists on the pad") }
        return backupData
    }
    func writeBackup(_ data: Data) async throws {
        if failBackup { throw CreatorMicroError.invalidKeymap("Backup write failed") }
        backupWrites += 1
        backupData = data
    }
    func writeKeymap(_ data: Data) async throws {
        keymapWrites += 1
        self.data = data
    }
    func restoreKeymap(_ data: Data) async throws {
        if !ignoreRestore { self.data = data }
    }
    func replaceKeymap(_ data: Data) { self.data = data }
    func backup() -> Data? { backupData }
    func setBackup(_ data: Data) { backupData = data }
    func ignoreRestoreWrites() { ignoreRestore = true }
    func failBackupWrites() { failBackup = true }
    func writeCounts() -> (backups: Int, keymaps: Int) { (backupWrites, keymapWrites) }
}

private actor FakeTransport: CreatorMicroReportTransport {
    private let stream: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private var sent: [[UInt8]] = []

    init() { (stream, continuation) = AsyncStream.makeStream() }
    func connect() async throws {}
    func disconnect() async {}
    func incomingReports() async -> AsyncStream<[UInt8]> { stream }
    func send(report: [UInt8]) async throws { sent.append(report) }

    func waitForSentReport() async throws -> [UInt8] {
        for _ in 0..<100 {
            if !sent.isEmpty { return sent.removeFirst() }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CreatorMicroError.timeout
    }

    func waitForSentMessage() async throws -> [String: JSONValue] {
        var assembler = JSONMessageAssembler()
        while true {
            let report = try CreatorMicroHIDReport(bytes: try await waitForSentReport())
            if let message = try assembler.append(report.payload).first {
                guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: message) else {
                    throw CreatorMicroError.malformedEnvelope("Expected request object")
                }
                return object
            }
        }
    }

    func respond(to request: [String: JSONValue], with result: String) async throws {
        guard case let .integer(id)? = request["id"] else {
            throw CreatorMicroError.malformedEnvelope("Expected request id")
        }
        try await receive(json: "{\"id\":\(id),\"r\":\(result)}")
    }

    func receive(json: String) async throws {
        for report in try CreatorMicroHIDReport.fragment(Data(json.utf8)) {
            continuation.yield(report.bytes)
        }
    }

    func receiveBytes(_ bytes: [UInt8]) async {
        continuation.yield(bytes)
    }
}
