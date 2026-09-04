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
        switch KeyBindings.load().providerSpec {
        case .none:
            return HerdrProvider()
        case .connect(let socketPath):
            return RemoteProvider(socketPath: socketPath)
        case .launch(let command, let args):
            return launchAndConnect(command: command, args: args)
        }
    }

    /// Terminates a launched provider process, if there is one. Call from
    /// `applicationWillTerminate` — nothing else owns its lifecycle.
    static func terminateLaunchedProcess() {
        launchedProcess?.terminate()
        launchedProcess = nil
    }

    /// Launches the configured command through `/usr/bin/env`, so a bare
    /// name on `$PATH` and an absolute path both work the way they would in
    /// a shell, then connects at the default provider-bridge socket path —
    /// where this repo's own `provider-bridge` binary listens unless told
    /// otherwise. A launch spec that points a *different* binary at a
    /// non-default socket needs a matching `"connect"` spec instead; this
    /// path does not read one back out of `args`.
    private static func launchAndConnect(command: String, args: [String]) -> Provider {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        do {
            try process.run()
            launchedProcess = process
        } catch {
            // Nothing will ever be listening — falling back to the
            // in-process default beats a bridge that can never connect.
            return HerdrProvider()
        }
        // A moment for it to create the socket before the first connect;
        // RemoteProvider's own per-request timeout covers the rest.
        Thread.sleep(forTimeInterval: 0.3)
        return RemoteProvider(socketPath: ProviderBridgePaths.defaultSocketPath())
    }
}
