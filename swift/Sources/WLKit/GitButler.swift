import Foundation

/// Runs `but` commands for a directory.
///
/// The awkward part is finding `but` at all. A menu-bar app launched by
/// launchd inherits launchd's `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), not the
/// one your shell sets up, so the binary the terminal finds instantly is
/// invisible here. Hence the explicit search, with a login shell as the last
/// resort for installs in places this list has never heard of.
public enum GitButler {

    public struct StatusOutput: Sendable {
        /// Combined stdout and stderr, still carrying its ANSI escapes.
        public var text: String
        public var succeeded: Bool
        public var directory: String
    }

    public enum Failure: LocalizedError {
        case binaryNotFound
        case launchFailed(String)
        case commandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Could not find the `but` binary. Set WL_BUT_PATH to its full path."
            case .launchFailed(let reason):
                return "Could not run `but`: \(reason)"
            case .commandFailed(let detail):
                return detail
            }
        }
    }

    /// Where `but` typically lands, most likely first.
    static let searchPaths = [
        "/opt/homebrew/bin/but",
        "/usr/local/bin/but",
        "~/.cargo/bin/but",
        "~/.local/bin/but",
        "/usr/bin/but",
    ]

    private static let cache = BinaryCache()

    public static func locateBinary() -> String? {
        if let cached = cache.value { return cached }
        guard let found = searchForBinary() else { return nil }
        cache.value = found
        return found
    }

    private static func searchForBinary() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["WL_BUT_PATH"], !explicit.isEmpty,
           FileManager.default.isExecutableFile(atPath: explicit) {
            return explicit
        }
        for candidate in searchPaths {
            let path = (candidate as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return askLoginShell()
    }

    /// Last resort: whatever the user's own shell resolves, which covers mise,
    /// asdf, nvm-style installs that only exist once a profile has been read.
    private static func askLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v but"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    // MARK: - Running

    public static func status(in directory: String, timeout: TimeInterval = 15) async throws -> StatusOutput {
        try await run(["status"], in: directory, timeout: timeout)
    }

    /// `but land --yes <branch>`. A land can push to a real remote, so it gets
    /// a network-sized timeout.
    public static func land(
        _ branch: String,
        in directory: String,
        timeout: TimeInterval = 120
    ) async throws -> StatusOutput {
        try await run(["land", "--yes", branch], in: directory, timeout: timeout)
    }

    /// Applied branches in landing order: bottom-most first within each stack,
    /// branches already integrated into the target skipped.
    public static func landPlan(in directory: String, timeout: TimeInterval = 15) async throws -> [String] {
        let output = try await run(
            ["status", "--json"], in: directory, color: false, timeout: timeout
        )
        guard output.succeeded else {
            throw Failure.commandFailed(
                output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try parseLandPlan(Data(output.text.utf8))
    }

    static func parseLandPlan(_ data: Data) throws -> [String] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stacks = json["stacks"] as? [[String: Any]]
        else { throw Failure.commandFailed("`but status --json` returned something unexpected.") }

        return stacks.flatMap { stack -> [String] in
            let branches = stack["branches"] as? [[String: Any]] ?? []
            // Status lists branches top first; landing goes bottom up.
            return branches.reversed().compactMap { branch -> String? in
                guard let name = branch["name"] as? String, !name.isEmpty,
                      (branch["branchStatus"] as? String) != "integrated"
                else { return nil }
                return name
            }
        }
    }

    public static func run(
        _ arguments: [String],
        in directory: String,
        color: Bool = true,
        timeout: TimeInterval = 15
    ) async throws -> StatusOutput {
        guard let binary = locateBinary() else { throw Failure.binaryNotFound }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try launch(
                        binary, arguments: arguments, in: directory,
                        color: color, timeout: timeout
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func launch(
        _ binary: String,
        arguments: [String],
        in directory: String,
        color: Bool,
        timeout: TimeInterval
    ) throws -> StatusOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        var environment = ProcessInfo.processInfo.environment
        // `but` drops colour when stdout is not a terminal, and colour is most
        // of what makes the stack readable. JSON goes the other way: forced
        // colour has no business inside machine-readable output.
        if color {
            environment["CLICOLOR_FORCE"] = "1"
        }
        environment["TERM"] = "xterm-256color"
        environment["PATH"] = [
            (binary as NSString).deletingLastPathComponent,
            environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ].joined(separator: ":")
        process.environment = environment

        // One pipe for both streams: it keeps the error text interleaved where
        // it belongs, and sidesteps the deadlock of draining two pipes in turn.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return StatusOutput(
            text: String(decoding: data, as: UTF8.self),
            succeeded: process.terminationStatus == 0,
            directory: directory
        )
    }

    /// Resolving through a login shell costs a shell startup, so hold onto the
    /// answer. Nothing invalidates it: a `but` that moves mid-session is worth
    /// a relaunch.
    private final class BinaryCache: @unchecked Sendable {
        private var stored: String?
        private let lock = NSLock()
        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
