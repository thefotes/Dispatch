import DispatchCore
import Foundation

/// Where the adapter sends one Herdr request.
public protocol HerdrConnecting: Sendable {
    func request(_ body: [String: JSONValue]) async throws -> [String: JSONValue]
}

extension HerdrUnixSocketClient: HerdrConnecting {}

/// A saved SSH machine from Herdr's client state (`endpoints.json`).
public struct HerdrSavedMachine: Sendable, Equatable, Codable {
    public let id: String
    public let label: String
    public let target: String
    public let session: String?

    public init(id: String, label: String, target: String, session: String? = nil) {
        self.id = id
        self.label = label
        self.target = target
        self.session = session
    }
}

/// Reads which machine Herdr's window shows. Herdr 0.9.1 keeps this client
/// state in `endpoint-selection.json` beside `endpoints.json` and rewrites it
/// as the window switches machines; `selected_profile` is null for Local.
/// These files are observed, not documented. A missing selection file means
/// Herdr has never shown another machine, so it is Local; a file that exists
/// but cannot be read fails the request rather than guess Local, because a
/// guess would act on the wrong machine.
public struct HerdrClientSelection: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `$XDG_STATE_HOME/herdr/client`, or `~/.local/state/herdr/client`.
    public static var defaultDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        let stateHome = environment["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        return stateHome.appendingPathComponent("herdr/client")
    }

    /// The selected saved machine, or nil when the window shows Local.
    public func selectedMachine() throws -> HerdrSavedMachine? {
        let selectionURL = directory.appendingPathComponent("endpoint-selection.json")
        guard FileManager.default.fileExists(atPath: selectionURL.path) else { return nil }
        let selection: Selection
        do {
            selection = try JSONDecoder().decode(Selection.self, from: Data(contentsOf: selectionURL))
        } catch {
            throw HerdrIntegrationError.unavailableState("Could not read which machine Herdr shows.")
        }
        guard let profileID = selection.selectedProfile else { return nil }
        let endpoints: Endpoints
        do {
            endpoints = try JSONDecoder().decode(
                Endpoints.self,
                from: Data(contentsOf: directory.appendingPathComponent("endpoints.json"))
            )
        } catch {
            throw HerdrIntegrationError.unavailableState("Could not read the machines saved in Herdr.")
        }
        guard let machine = endpoints.ssh.first(where: { $0.id == profileID }) else {
            throw HerdrIntegrationError.unavailableState("Herdr shows a machine that is not saved.")
        }
        return machine
    }
}

private struct Selection: Decodable {
    let selectedProfile: String?

    private enum CodingKeys: String, CodingKey {
        case selectedProfile = "selected_profile"
    }
}

private struct Endpoints: Decodable {
    let ssh: [HerdrSavedMachine]
}

/// Makes a saved machine's Herdr socket reachable at a local path.
public protocol HerdrTunnelOpening: Sendable {
    func socketPath(for machine: HerdrSavedMachine) async throws -> String
}

/// Sends each request to the Herdr server whose machine the window shows, so
/// an action acts where the user is looking.
public actor HerdrSelectedMachineConnection: HerdrConnecting {
    private let local: HerdrUnixSocketClient
    private let selection: HerdrClientSelection
    private let tunnels: any HerdrTunnelOpening
    private let timeout: Duration
    private var remoteClients: [String: HerdrUnixSocketClient] = [:]
    private var lastMachineID: String?

    public init(
        local: HerdrUnixSocketClient,
        selection: HerdrClientSelection,
        tunnels: any HerdrTunnelOpening,
        timeout: Duration = .seconds(2)
    ) {
        self.local = local
        self.selection = selection
        self.tunnels = tunnels
        self.timeout = timeout
    }

    public func request(_ body: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let machine = try selection.selectedMachine() else {
            if lastMachineID != nil {
                Log.logger.info("Herdr now shows Local.")
                lastMachineID = nil
            }
            return try await local.request(body)
        }
        if lastMachineID != machine.id {
            Log.logger.info("Herdr now shows machine \(machine.label, privacy: .public).")
            lastMachineID = machine.id
        }
        let path = try await tunnels.socketPath(for: machine)
        if let client = remoteClients[path] {
            return try await client.request(body)
        }
        Log.logger.info("Opening a Herdr connection to \(machine.label, privacy: .public).")
        let client = HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: timeout))
        remoteClients[path] = client
        return try await client.request(body)
    }
}

/// Forwards a saved machine's Herdr socket over OpenSSH, reusing one `ssh -N`
/// per machine while it runs. Authentication stays with the user's SSH setup,
/// as it does for Herdr's own machine connections.
///
/// Each `ssh` runs under a shell that holds the read end of a pipe from
/// Dispatch. Whenever Dispatch exits, including a crash or force quit, the
/// pipe closes and the shell stops `ssh`, so no tunnel outlives Dispatch.
public actor SSHHerdrTunnels: HerdrTunnelOpening {
    private struct Tunnel {
        let process: Process
        let lifeline: FileHandle
        let path: String
    }

    /// Runs `ssh` (`$0`) with its arguments until it exits or standard input
    /// reaches end of file. A background list reads `/dev/null` unless told
    /// otherwise, so the watcher reads the lifeline through descriptor 3.
    private static let watchdog = """
        exec 3<&0
        "$0" "$@" </dev/null 3<&- &
        tunnel=$!
        { read -r _ <&3; kill "$tunnel" 2>/dev/null; } &
        watcher=$!
        wait "$tunnel"
        kill "$watcher" 2>/dev/null
        """

    private static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]

    private let sshPath: String
    private let commandTimeout: Duration
    private var tunnels: [String: Tunnel] = [:]

    public init(sshPath: String = "/usr/bin/ssh", commandTimeout: Duration = .seconds(8)) {
        self.sshPath = sshPath
        self.commandTimeout = commandTimeout
    }

    public func socketPath(for machine: HerdrSavedMachine) async throws -> String {
        if let tunnel = tunnels[machine.id] {
            if tunnel.process.isRunning { return tunnel.path }
            try? tunnel.lifeline.close()
            tunnels[machine.id] = nil
        }
        guard machine.session == nil || machine.session == "default" else {
            throw HerdrIntegrationError.unavailableState(
                "Dispatch reaches only the default Herdr session on \(machine.label)."
            )
        }
        let remotePath = try await run(
            machine.target,
            command: #"printf %s "${XDG_CONFIG_HOME:-$HOME/.config}/herdr/herdr.sock""#
        )
        let localPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-herdr-\(machine.id.prefix(12)).sock").path
        // A socket left by an earlier tunnel would look ready before `ssh` binds.
        try? FileManager.default.removeItem(atPath: localPath)
        let lifeline = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.watchdog, sshPath] + Self.sshOptions + [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StreamLocalBindUnlink=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-N", "-L", "\(localPath):\(remotePath)", machine.target
        ]
        process.standardInput = lifeline
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        Log.logger.info("Opened an SSH tunnel to \(machine.label, privacy: .public).")
        let tunnel = Tunnel(process: process, lifeline: lifeline.fileHandleForWriting, path: localPath)
        tunnels[machine.id] = tunnel
        try await waitForSocket(of: tunnel, machine: machine)
        return localPath
    }

    /// Closing a lifeline is what Dispatch's exit does, so a normal close and
    /// a crash stop `ssh` the same way.
    public func closeAll() {
        for tunnel in tunnels.values {
            Log.logger.info("Closing the SSH tunnel at \(tunnel.path, privacy: .private).")
            try? tunnel.lifeline.close()
        }
        tunnels = [:]
    }

    private func run(_ target: String, command: String) async throws -> String {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = Self.sshOptions + [target, command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // `ConnectTimeout` bounds only the TCP connect; a session that stalls
        // after it would otherwise hold every pad event behind this press.
        let deadline = ContinuousClock.now + commandTimeout
        while process.isRunning {
            guard ContinuousClock.now < deadline else {
                process.terminate()
                Log.logger.error("SSH to \(target, privacy: .private) did not answer in time.")
                throw HerdrIntegrationError.unavailableState("\(target) did not answer over SSH in time.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // The answer is one short path, well inside the pipe's buffer, so
        // reading after exit cannot block.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            let status = process.terminationStatus
            Log.logger.error("SSH to \(target, privacy: .private) failed with status \(status, privacy: .public).")
            throw HerdrIntegrationError.unavailableState("Could not reach \(target) over SSH.")
        }
        return text
    }

    /// `ssh` binds the local socket only after it connects, so a request sent
    /// sooner would find no listener.
    private func waitForSocket(of tunnel: Tunnel, machine: HerdrSavedMachine) async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: tunnel.path) { return }
            guard tunnel.process.isRunning else { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try? tunnel.lifeline.close()
        tunnels[machine.id] = nil
        Log.logger.error("The SSH tunnel for \(machine.label, privacy: .public) never became ready.")
        throw HerdrIntegrationError.unavailableState("Could not forward Herdr's socket on \(machine.label).")
    }
}
