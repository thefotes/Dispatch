import Foundation

/// Where the standalone `provider-bridge` executable listens by default, and
/// where `RemoteProvider` looks when `config.json` says `"provider": true`
/// without an explicit path. One function, so the two sides can never
/// disagree.
public enum ProviderBridgePaths {
    public static func defaultSocketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["WL_PROVIDER_BRIDGE_SOCKET"], !explicit.isEmpty { return explicit }
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (base as NSString).appendingPathComponent("micromanager/provider-bridge.sock")
    }
}
