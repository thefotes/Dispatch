import Foundation
import WLKit

/// Decides which `Provider` `BridgeController` gets, from `config.json`'s
/// `"provider"` key. Read once at launch — unlike key bindings and dial
/// mode, a provider swap needs a relaunch, not just an off/on toggle: it is
/// fixed for a `BridgeController`'s lifetime (it is a constructor argument,
/// not something `start()` re-reads).
enum ProviderFactory {

    /// Set only when `make()` launched a subprocess, so the app can
    /// terminate it on quit rather than leaving it running.
    private(set) static var launchedProcess: Process?

    static func make() -> Provider {
        let bindings = KeyBindings.load()
        switch bindings.providerSpec {
        case .none:
            // The in-process Herdr provider gets the Herdr-specific knobs
            // its actions read from config.json's `"herdr"` section — the
            // protocol stays generic, this is the concrete implementation's
            // own configuration.
            return makeDefault(bindings)
        case .connect(let socketPath):
            return RemoteProvider(socketPath: socketPath)
        case .launch(let command, let args):
            return launchAndConnect(command: command, args: args, bindings: bindings)
        }
    }

    /// Terminates a launched provider process, if there is one. Call from
    /// `applicationWillTerminate` — nothing else owns its lifecycle.
    static func terminateLaunchedProcess() {
        launchedProcess?.terminate()
        launchedProcess = nil
    }

    private static func makeDefault(_ bindings: KeyBindings) -> Provider {
        HerdrProvider(options: HerdrProvider.Options(
            tools: bindings.herdrTools,
            splitDirection: bindings.herdrSplitDirection
        ))
    }

    /// Launches the configured command through `/usr/bin/env`, so a bare
    /// name on `$PATH` and an absolute path both work the way they would in
    /// a shell, then connects at the default provider-bridge socket path —
    /// where this repo's own `provider-bridge` binary listens unless told
    /// otherwise. A launch spec that points a *different* binary at a
    /// non-default socket needs a matching `"connect"` spec instead; this
    /// path does not read one back out of `args`.
    private static func launchAndConnect(command: String, args: [String], bindings: KeyBindings) -> Provider {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        do {
            try process.run()
            launchedProcess = process
        } catch {
            // Nothing will ever be listening — falling back to the
            // in-process default beats a bridge that can never connect.
            return makeDefault(bindings)
        }
        // Wait for the socket file to actually exist rather than guessing a
        // fixed delay — a fast-starting provider does not pay for a delay it
        // did not need, and a slow one still gets a real chance instead of
        // RemoteProvider's first request just timing out. Capped, so a
        // provider that never starts does not hang launch indefinitely.
        let path = ProviderBridgePaths.defaultSocketPath()
        waitForSocket(at: path)
        return RemoteProvider(socketPath: path)
    }

    private static func waitForSocket(at path: String, pollInterval: TimeInterval = 0.05, cap: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(cap)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }
}
