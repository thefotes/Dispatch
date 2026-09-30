import Darwin
import DispatchProviders
import Foundation
import XCTest

final class SSHHerdrTunnelsTests: XCTestCase {
    func testClosingTheLifelineStopsTheTunnel() async throws {
        let fake = try FakeSSH(forwardBehavior: .bindAndStay)
        let tunnels = SSHHerdrTunnels(sshPath: fake.executable.path)

        let path = try await tunnels.socketPath(for: fake.machine)
        let pid = try fake.forwardPID()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(isRunning(pid))

        await tunnels.closeAll()

        try await waitUntil { !self.isRunning(pid) }
    }

    func testALeftoverSocketFileIsNotMistakenForAReadyTunnel() async throws {
        let fake = try FakeSSH(forwardBehavior: .failWithoutBinding)
        let tunnels = SSHHerdrTunnels(sshPath: fake.executable.path)
        let localPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-herdr-\(fake.machine.id.prefix(12)).sock").path
        FileManager.default.createFile(atPath: localPath, contents: nil)

        do {
            _ = try await tunnels.socketPath(for: fake.machine)
            XCTFail("Expected the failed forward to be reported")
        } catch let error as HerdrIntegrationError {
            XCTAssertEqual(error, .unavailableState("Could not forward Herdr's socket on Fake."))
        }
    }

    func testDeadTunnelIsReplacedWithoutRetainingItsLifeline() async throws {
        let fake = try FakeSSH(forwardBehavior: .bindAndStay)
        let tunnels = SSHHerdrTunnels(sshPath: fake.executable.path)
        let firstPath = try await tunnels.socketPath(for: fake.machine)
        let firstPID = try fake.forwardPID()
        let openLifelines = try writablePipeCount()

        XCTAssertEqual(kill(firstPID, SIGTERM), 0)
        try await waitUntil { !self.isRunning(firstPID) }
        let secondPath = try await tunnels.socketPath(for: fake.machine)
        let secondPID = try fake.forwardPID()

        XCTAssertEqual(secondPath, firstPath)
        XCTAssertNotEqual(secondPID, firstPID)
        XCTAssertTrue(isRunning(secondPID))
        XCTAssertLessThanOrEqual(try writablePipeCount(), openLifelines)
        await tunnels.closeAll()
        try await waitUntil { !self.isRunning(secondPID) }
    }

    func testAStalledSSHSessionFailsWithinTheDeadline() async throws {
        let fake = try FakeSSH(forwardBehavior: .bindAndStay, queryStalls: true)
        let tunnels = SSHHerdrTunnels(sshPath: fake.executable.path, commandTimeout: .milliseconds(300))
        let started = ContinuousClock.now

        do {
            _ = try await tunnels.socketPath(for: fake.machine)
            XCTFail("Expected the stalled session to time out")
        } catch let error as HerdrIntegrationError {
            XCTAssertEqual(error, .unavailableState("fake-host did not answer over SSH in time."))
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    private func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func writablePipeCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap(Int32.init).filter { descriptor in
            var info = stat()
            let flags = fcntl(descriptor, F_GETFL)
            return fstat(descriptor, &info) == 0
                && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO)
                && flags >= 0 && flags & O_ACCMODE == O_WRONLY
        }.count
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition was not met before timeout")
    }
}

/// Stands in for `/usr/bin/ssh`: answers the remote socket-path query, and for
/// `-N -L local:remote` records its PID and either binds `local` and stays up
/// or exits without binding.
private struct FakeSSH {
    enum ForwardBehavior {
        case bindAndStay
        case failWithoutBinding
    }

    let executable: URL
    let machine: HerdrSavedMachine
    private let pidFile: URL

    init(forwardBehavior: ForwardBehavior, queryStalls: Bool = false) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-fake-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("ssh")
        pidFile = directory.appendingPathComponent("forward.pid")
        machine = HerdrSavedMachine(
            id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)),
            label: "Fake",
            target: "fake-host",
            session: "default"
        )
        let forward = switch forwardBehavior {
        case .bindAndStay: #"touch "${spec%%:*}"; exec sleep 30"#
        case .failWithoutBinding: "exit 255"
        }
        let script = """
            #!/bin/sh
            spec=""
            previous=""
            for argument in "$@"; do
                [ "$previous" = "-L" ] && spec="$argument"
                previous="$argument"
            done
            if [ -z "$spec" ]; then
                \(queryStalls ? "exec sleep 30" : "printf %s /remote/herdr.sock")
                exit 0
            fi
            echo $$ > "\(pidFile.path)"
            \(forward)
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func forwardPID() throws -> pid_t {
        let text = try String(contentsOf: pidFile, encoding: .utf8)
        return try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
