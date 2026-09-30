import DispatchCore
import DispatchCreatorMicro
import Foundation
import XCTest

final class DriverLightingTests: XCTestCase {
    /// The app can ask for new lighting while an earlier write still waits
    /// for the pad. Overlapping lighting requests interleave their HID
    /// reports, so the pad cannot read either one; it rejected a write,
    /// garbled its answers, and let the next write time out (seen
    /// 2026-09-30 while switching Herdr machines quickly). This transport
    /// likewise cannot answer interleaved requests.
    func testOverlappingAppliesSendOneLightingRequestAtATime() async throws {
        let transport = AnsweringTransport()
        let driver = CreatorMicroDriver(transport: transport, identity: DeviceIdentity(rawValue: "pad"))
        try await driver.connect()

        let red = Self.presentation(DispatchCore.RGBColor(red: 255, green: 0, blue: 0))
        let blue = Self.presentation(DispatchCore.RGBColor(red: 0, green: 0, blue: 255))
        let first = Task { try await driver.apply(red) }
        let second = Task { try await driver.apply(blue) }
        try await first.value
        try await second.value

        let requests = await transport.answeredRequestCount()
        let mostOutstanding = await transport.mostOutstandingRequests()
        XCTAssertGreaterThan(requests, 1)
        XCTAssertEqual(mostOutstanding, 1)
        await driver.disconnect()
    }

    /// stop() and device loss cancel the task that is writing lighting. The
    /// write must end then, not wait out the pad's answer timeout, and a
    /// write queued behind it must not start.
    func testCancellingTheCallerEndsItsLightingWrite() async throws {
        let transport = SilentTransport()
        let driver = CreatorMicroDriver(transport: transport, identity: DeviceIdentity(rawValue: "pad"))
        try await driver.connect()
        let red = Self.presentation(DispatchCore.RGBColor(red: 255, green: 0, blue: 0))
        let blue = Self.presentation(DispatchCore.RGBColor(red: 0, green: 0, blue: 255))

        let inFlight = Task { try await driver.apply(red) }
        try await transport.waitForSentReport()
        let queued = Task { try await driver.apply(blue) }
        try await Task.sleep(for: .milliseconds(20))
        let sentBeforeCancel = await transport.sentReportCount()
        let clock = ContinuousClock()
        let started = clock.now
        queued.cancel()
        inFlight.cancel()

        for write in [queued, inFlight] {
            do {
                try await write.value
                XCTFail("A cancelled write should not succeed")
            } catch is CancellationError {}
        }
        XCTAssertLessThan(clock.now - started, .milliseconds(500))
        let sentAfterCancel = await transport.sentReportCount()
        XCTAssertEqual(sentAfterCancel, sentBeforeCancel)
        await driver.disconnect()
    }

    private static func presentation(_ color: DispatchCore.RGBColor) -> PadPresentation {
        PadPresentation(
            controls: [.key(0): ControlAppearance(color: color)],
            ambient: ControlAppearance(color: color)
        )
    }
}

/// Answers every request after a short delay, like the pad, and records how
/// many requests were waiting for an answer at once.
private actor AnsweringTransport: CreatorMicroReportTransport {
    private let stream: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private var assembler = JSONMessageAssembler()
    private var outstanding = 0
    private var mostOutstanding = 0
    private var answered = 0

    init() { (stream, continuation) = AsyncStream.makeStream() }

    func connect() async throws {}
    func disconnect() async {}
    func incomingReports() async -> AsyncStream<[UInt8]> { stream }

    func send(report: [UInt8]) async throws {
        let payload = try CreatorMicroHIDReport(bytes: report).payload
        for message in try assembler.append(payload) {
            guard case let .object(request) = try JSONDecoder().decode(JSONValue.self, from: message),
                  case let .integer(id)? = request["id"] else { continue }
            outstanding += 1
            mostOutstanding = max(mostOutstanding, outstanding)
            Task { await self.answer(id: id) }
        }
    }

    func answeredRequestCount() -> Int { answered }
    func mostOutstandingRequests() -> Int { mostOutstanding }

    private func answer(id: Int) async {
        try? await Task.sleep(for: .milliseconds(20))
        outstanding -= 1
        answered += 1
        for report in (try? CreatorMicroHIDReport.fragment(Data("{\"id\":\(id),\"r\":true}".utf8))) ?? [] {
            continuation.yield(report.bytes)
        }
    }
}

/// A pad that never answers.
private actor SilentTransport: CreatorMicroReportTransport {
    private let stream: AsyncStream<[UInt8]>
    private var sent = 0

    init() { (stream, _) = AsyncStream.makeStream() }

    func connect() async throws {}
    func disconnect() async {}
    func incomingReports() async -> AsyncStream<[UInt8]> { stream }
    func send(report: [UInt8]) async throws { sent += 1 }
    func sentReportCount() -> Int { sent }

    func waitForSentReport() async throws {
        while sent == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
