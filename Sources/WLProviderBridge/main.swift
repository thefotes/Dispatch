import Foundation
import WLKit

// `provider-bridge`: HerdrProvider behind a ProviderBridgeServer, runnable as
// its own process. Proof that the Provider protocol does not need to run
// in-process inside Micromanager — this binary IS a provider, and speaks
// nothing but the socket protocol WLKit's RemoteProvider already knows.
//
// Usage: `provider-bridge [socket-path]`, or set WL_PROVIDER_BRIDGE_SOCKET.
// With neither, listens at the same default RemoteProvider connects to.

let socketPath = CommandLine.arguments.dropFirst().first ?? ProviderBridgePaths.defaultSocketPath()

let directory = (socketPath as NSString).deletingLastPathComponent
try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

let server = ProviderBridgeServer(provider: HerdrProvider(), socketPath: socketPath)

do {
    try server.start()
    FileHandle.standardError.write(Data("provider-bridge: listening at \(socketPath)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("provider-bridge: could not listen at \(socketPath): \(error)\n".utf8))
    exit(1)
}

// A signal handler alone cannot safely unlink the socket file on some
// platforms, but `stop()` tries anyway on a clean exit — best effort, since
// `start()` already unlinks a stale file on the next launch regardless.
signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

RunLoop.main.run()
