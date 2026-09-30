import DispatchCore
import DispatchCreatorMicro
import Foundation
import XCTest

final class DriverReconnectTests: XCTestCase {
    func testTransportEndFailsPendingCallReportsLossAndReconnects() async throws {
        let transport = ReconnectingTransport()
        let driver = CreatorMicroDriver(transport: transport, identity: DeviceIdentity(rawValue: "pad"))
        try await driver.connect()
        let events = driver.events()
        let ended = Task {
            for await _ in events {}
        }
        let call = Task { try await driver.deviceStatus() }
        try await transport.waitForSentReport()

        await transport.endConnection()
        do {
            _ = try await call.value
            XCTFail("Pending RPC should fail when transport ends")
        } catch let error as CreatorMicroError {
            XCTAssertEqual(error, .disconnected)
        }
        await ended.value
        let connectedAfterLoss = await driver.isConnected
        XCTAssertFalse(connectedAfterLoss)
        do {
            _ = try await driver.deviceStatus()
            XCTFail("An ended connection should reject new RPCs")
        } catch let error as CreatorMicroError {
            XCTAssertEqual(error, .disconnected)
        }

        try await driver.connect()
        let connectedAfterReconnect = await driver.isConnected
        XCTAssertTrue(connectedAfterReconnect)
        await driver.disconnect()
    }

    func testInputIsSuppressedUntilEnabled() async throws {
        let transport = ReconnectingTransport()
        let driver = CreatorMicroDriver(transport: transport, identity: DeviceIdentity(rawValue: "pad"))
        try await driver.connect()
        let events = driver.events()
        await transport.receive(json: #"{"m":"v.oai.hid","p":{"k":"AG00","act":1}}"#)
        try await Task.sleep(for: .milliseconds(20))
        await driver.setInputEnabled(true)
        await transport.receive(json: #"{"m":"v.oai.hid","p":{"k":"AG01","act":1}}"#)
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event?.control, .key(1))
        await driver.disconnect()
    }
    func testConnectWithoutConsentDoesNotWriteKeymap() async throws {
        let transport = ReconnectingTransport()
        let driver = CreatorMicroDriver(transport: transport, identity: DeviceIdentity(rawValue: "pad"))
        try await driver.connect()
        let sent = await transport.sentReports()
        XCTAssertTrue(sent.isEmpty)
        await driver.disconnect()
    }

    /// The runtime cancels its event consumer on device loss and on stop, then
    /// reconnects and subscribes again. Input must still arrive afterwards.
    func testEventsArriveAfterConsumerCancellationAndReconnect() async throws {
        let transport = ReconnectingTransport()
        let driver = CreatorMicroDriver(transport: transport, identity: DeviceIdentity(rawValue: "pad"))
        try await driver.connect()
        let firstConsumer = Task {
            for await _ in driver.events() {}
        }
        firstConsumer.cancel()
        await firstConsumer.value
        await driver.disconnect()

        try await driver.connect()
        await driver.setInputEnabled(true)
        let events = driver.events()
        let received = Task { () -> DispatchEvent? in
            for await event in events { return event }
            return nil
        }
        await transport.receive(json: #"{"m":"v.oai.hid","p":{"k":"AG00","act":1}}"#)
        let timeout = Task {
            try await Task.sleep(for: .seconds(1))
            received.cancel()
        }
        let event = await received.value
        timeout.cancel()

        XCTAssertEqual(event?.control, .key(0))
        XCTAssertEqual(event?.gesture, .pressed)
        await driver.disconnect()
    }
}

/// Like the HID transport, each connection gets a new report stream.
private actor ReconnectingTransport: CreatorMicroReportTransport {
    private var stream: AsyncStream<[UInt8]>
    private var continuation: AsyncStream<[UInt8]>.Continuation
    private var sent: [[UInt8]] = []
    private var sentWaiter: CheckedContinuation<Void, Never>?

    init() { (stream, continuation) = AsyncStream.makeStream() }

    func connect() async throws {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func disconnect() async { continuation.finish() }
    func send(report: [UInt8]) async throws {
        sent.append(report)
        sentWaiter?.resume()
        sentWaiter = nil
    }
    func sentReports() -> [[UInt8]] { sent }
    func waitForSentReport() async throws {
        if !sent.isEmpty { return }
        await withCheckedContinuation { sentWaiter = $0 }
    }
    func endConnection() { continuation.finish() }
    func incomingReports() async -> AsyncStream<[UInt8]> { stream }

    func receive(json: String) {
        for report in (try? CreatorMicroHIDReport.fragment(Data(json.utf8))) ?? [] {
            continuation.yield(report.bytes)
        }
    }
}
