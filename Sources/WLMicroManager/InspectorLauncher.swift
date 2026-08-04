import AppKit

/// Opens the Inspector — the debug UI for watching pad traffic and driving the
/// lighting by hand.
///
/// It ships *inside* MicroManager.app, at `Contents/Library/Inspector.app`,
/// rather than as a second thing to install. That is not just tidiness: macOS
/// keys the Input Monitoring grant to a code signature, and a nested app signed
/// by the same identity as its host is one trust decision instead of two.
enum InspectorLauncher {

    static let bundleID = "cc.worklouder.inspector"

    /// Where the nested app sits, when there is one. A `swift run` build has no
    /// surrounding bundle, so this is nil during development — which is why the
    /// button reports rather than assumes.
    static var url: URL? {
        let nested = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/Inspector.app")
        return FileManager.default.fileExists(atPath: nested.path) ? nested : nil
    }

    static var isAvailable: Bool { url != nil }

    /// Brings the Inspector up, or forward if it is already running — a second
    /// copy would open a second HID connection and contend with the first.
    static func launch(onError: @escaping (String) -> Void) {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first {
            running.activate(options: [.activateAllWindows])
            return
        }

        guard let url else {
            onError("No Inspector in this build — it is added by scripts/bundle.sh.")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                onError("Could not open the Inspector: \(error.localizedDescription)")
            }
        }
    }
}
