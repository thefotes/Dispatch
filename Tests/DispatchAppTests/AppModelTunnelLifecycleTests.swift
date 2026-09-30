@testable import DispatchApp
import Darwin
import DispatchCore
import DispatchCreatorMicro
import DispatchProviders
import DispatchRuntime
import DispatchTestSupport
import Foundation
import XCTest

@MainActor
final class AppModelTunnelLifecycleTests: XCTestCase {
    func testTurnOffStopsPollingAndClosesTheTunnel() async throws {
        let fake = try FakeSSH()
        let tunnels = SSHHerdrTunnels(sshPath: fake.executable.path)
        let client = CountingHerdrClient()
        let herdr = HerdrAdapter(client: client, encoder: HerdrProtocol22Codec())
        let pad = FakePadDevice()
        pad.setConnectionError(.connectionFailed)
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: []))
        )
        let model = AppModel(
            inputMonitoringRequester: GrantedInputMonitoringRequester(),
            tunnels: tunnels,
            herdr: herdr,
            runtime: runtime,
            herdrPollInterval: .milliseconds(20)
        )

        await model.start()
        try await waitUntil { await client.requestCount > 0 }
        _ = try await tunnels.socketPath(for: fake.machine)
        let pid = try fake.forwardPID()
        XCTAssertEqual(kill(pid, 0), 0)

        await model.stop()

        try await waitUntil { kill(pid, 0) != 0 }
        let countAfterStop = await client.requestCount
        try await Task.sleep(for: .milliseconds(100))
        let finalCount = await client.requestCount
        XCTAssertEqual(finalCount, countAfterStop)
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition was not met before timeout")
    }
}

private actor CountingHerdrClient: HerdrConnecting {
    private(set) var requestCount = 0

    func request(_ body: [String: JSONValue]) async throws -> [String: JSONValue] {
        requestCount += 1
        return [:]
    }
}

private actor GrantedInputMonitoringRequester: InputMonitoringPermissionRequesting {
    func check() async -> InputMonitoringPermission { .granted }
    func request() async -> InputMonitoringPermission { .granted }
}

private struct FakeSSH {
    let executable: URL
    let machine: HerdrSavedMachine
    private let pidFile: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-app-fake-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("ssh")
        pidFile = directory.appendingPathComponent("forward.pid")
        machine = HerdrSavedMachine(
            id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)),
            label: "Fake",
            target: "fake-host"
        )
        let script = """
            #!/bin/sh
            spec=""
            previous=""
            for argument in "$@"; do
                [ "$previous" = "-L" ] && spec="$argument"
                previous="$argument"
            done
            if [ -z "$spec" ]; then
                printf %s /remote/herdr.sock
                exit 0
            fi
            echo $$ > "\(pidFile.path)"
            touch "${spec%%:*}"
            exec sleep 30
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func forwardPID() throws -> pid_t {
        let text = try String(contentsOf: pidFile, encoding: .utf8)
        return try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
