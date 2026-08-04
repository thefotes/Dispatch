import AppKit
import SwiftUI
import WLKit

/// The menu-bar icon.
///
/// Menu-bar images are drawn as templates (flattened to monochrome) unless the
/// NSImage says otherwise, so a coloured status needs `isTemplate = false` and
/// an explicitly drawn dot. Neutral states stay templated so they follow the
/// menu bar's own light/dark appearance.
enum MenuBarIcon {

    enum State: Equatable {
        case off
        case permissionDenied
        case deviceMissing
        case idle            // running, no agents
        case allIdle
        case working
        case blocked

        /// Derived from the bridge, in the order that matters: problems first,
        /// then attention, then activity.
        @MainActor
        static func from(_ bridge: BridgeController) -> State {
            guard bridge.isRunning else { return .off }
            if bridge.permissionDenied { return .permissionDenied }
            if !bridge.deviceConnected { return .deviceMissing }
            guard let state = bridge.aggregateState else { return .idle }
            switch state {
            case "blocked": return .blocked
            case "working": return .working
            default: return .allIdle
            }
        }

        var symbolName: String {
            switch self {
            case .off: return "keyboard"
            case .permissionDenied, .deviceMissing: return "keyboard.badge.exclamationmark"
            case .idle: return "keyboard"
            case .allIdle, .working, .blocked: return "keyboard.fill"
            }
        }

        /// nil keeps the icon templated, so it matches the menu bar.
        var dot: NSColor? {
            switch self {
            case .off, .idle: return nil
            case .permissionDenied: return .systemRed
            case .deviceMissing: return .systemGray
            case .allIdle: return NSColor(srgbRed: 0, green: 0.78, blue: 0.33, alpha: 1)
            case .working: return NSColor(srgbRed: 1, green: 0.63, blue: 0, alpha: 1)
            case .blocked: return NSColor(srgbRed: 1, green: 0.18, blue: 0.18, alpha: 1)
            }
        }

        var help: String {
            switch self {
            case .off: return "Micro Manager is off"
            case .permissionDenied: return "Input Monitoring permission is needed"
            case .deviceMissing: return "Pad not found"
            case .idle: return "Running — no agents"
            case .allIdle: return "All agents idle"
            case .working: return "An agent is working"
            case .blocked: return "An agent needs you"
            }
        }
    }

    static func image(for state: State) -> NSImage {
        let symbolSize = NSSize(width: 18, height: 18)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let symbol = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: state.help)?
            .withSymbolConfiguration(config)
            ?? NSImage(size: symbolSize)

        guard let dot = state.dot else {
            symbol.isTemplate = true
            return symbol
        }

        // Compose symbol + status dot into one non-template image.
        let canvas = NSSize(width: symbolSize.width, height: symbolSize.height)
        let composed = NSImage(size: canvas)
        composed.lockFocus()

        NSColor.labelColor.set()
        let symbolRect = NSRect(
            x: (canvas.width - symbol.size.width) / 2,
            y: (canvas.height - symbol.size.height) / 2 + 1,
            width: symbol.size.width,
            height: symbol.size.height
        )
        symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)

        let diameter: CGFloat = 5
        let dotRect = NSRect(
            x: canvas.width - diameter - 0.5,
            y: 0,
            width: diameter,
            height: diameter
        )
        dot.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        composed.unlockFocus()
        composed.isTemplate = false
        return composed
    }
}
