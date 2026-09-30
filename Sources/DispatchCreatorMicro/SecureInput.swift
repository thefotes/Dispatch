import Darwin
import Foundation
import IOKit

/// While any other process holds Secure Input, the kernel refuses reports to
/// and from keyboard-class HID devices for unprivileged clients, and the pad's
/// vendor collection shares its interface with a keyboard collection. The
/// kernel reads the owner from the console session in the I/O Registry, so
/// Dispatch reads the same record to explain a refused write.
enum SecureInput {
    /// The application holding Secure Input, or `.stale` when the recorded
    /// owner has already exited. Nil when no other process holds it.
    static func owner() -> CreatorMicroError.SecureInputOwner? {
        guard let pid = ownerProcessID(inConsoleSessions: consoleSessions()), pid != getpid() else { return nil }
        guard let name = applicationName(processID: pid) else { return .stale }
        return .application(name)
    }

    /// Picks the owner from the `IOConsoleUsers` value: the process recorded
    /// on the session that is on the console, if any.
    static func ownerProcessID(inConsoleSessions sessions: Any?) -> pid_t? {
        guard let sessions = sessions as? [[String: Any]] else { return nil }
        let console = sessions.first { $0["kCGSSessionOnConsoleKey"] as? Bool == true }
        return (console?["kCGSSessionSecureInputPID"] as? NSNumber).map { pid_t($0.int32Value) }
    }

    private static func consoleSessions() -> Any? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(
            root,
            "IOConsoleUsers" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    /// Names the owner by its app bundle when it has one, since that is the
    /// name the user sees; nil when the process no longer exists.
    private static func applicationName(processID: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let components = URL(fileURLWithPath: String(cString: buffer)).pathComponents
        if let bundle = components.first(where: { $0.hasSuffix(".app") }) {
            return String(bundle.dropLast(".app".count))
        }
        return components.last
    }
}
