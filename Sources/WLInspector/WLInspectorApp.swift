import SwiftUI
import AppKit
import WLKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from `swift run` gives an unbundled process, which defaults to
        // an accessory activation policy and never comes to the front.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WLInspectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Work Louder Inspector") {
            ContentView()
                .environmentObject(model)
                .onAppear { model.connect() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Device") {
                Button("Reconnect") { model.connect() }.keyboardShortcut("r")
                Button("Refresh status") { model.refreshStatus() }.keyboardShortcut("i")
                Divider()
                Button("All lights off") { model.allOff() }.keyboardShortcut("0")
                Button("Walk keys 0→12") { model.runWalk() }
                Divider()
                Button("Clear log") { model.clearLog() }.keyboardShortcut("k")
            }
        }
    }
}
