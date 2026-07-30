import Foundation
import SwiftUI

struct LogEntry: Identifiable {
    enum Kind: String, CaseIterable {
        case tx = "TX"
        case rx = "RX"
        case notify = "NOTIFY"
        case device = "DEVICE"
        case info = "INFO"
        case error = "ERROR"

        var color: Color {
            switch self {
            case .tx: return .accentColor
            case .rx: return .secondary
            case .notify: return .purple
            case .device: return .teal
            case .info: return .secondary
            case .error: return .red
            }
        }
    }

    let id = UUID()
    let at = Date()
    let kind: Kind
    let title: String
    let detail: String
}

/// State for one key on the pad.
struct KeyState {
    var color: Color = .white
    var effect: OAI.Effect = .solid
    var brightness: Double = 1
    var speed: Double = 0.5
    var isLit: Bool = false
}

@MainActor
final class AppModel: ObservableObject {

    // Connection
    @Published private(set) var connected = false
    @Published private(set) var deviceName = "—"
    @Published private(set) var firmware = "—"
    @Published private(set) var battery = "—"
    @Published var lastError: String?

    // Pad
    @Published var keys: [KeyState] = Array(repeating: KeyState(), count: Pad.keyCount)
    @Published var selection: Set<Int> = [0, 1, 2, 3, 4, 5]

    // Editor
    @Published var editColor: Color = Color(packedRGB: 0xFFA000)
    @Published var editEffect: OAI.Effect = .solid
    @Published var editBrightness: Double = 1
    @Published var editSpeed: Double = 0.5

    // Ambient / keys zones
    @Published var ambientColor: Color = Color(packedRGB: 0x00C853)
    @Published var ambientEffect: OAI.Effect = .solid
    @Published var ambientBrightness: Double = 1
    @Published var ambientSpeed: Double = 0.5

    // Log
    @Published private(set) var entries: [LogEntry] = []
    @Published var visibleKinds: Set<LogEntry.Kind> = Set(LogEntry.Kind.allCases)
    @Published var autoScroll = true
    @Published var prettyPrint = false

    private let device = WLDevice()
    private let maxEntries = 2000

    init() {
        device.onTX = { [weak self] method, params, id in
            self?.log(.tx, "\(method)  #\(id)", self?.encode(params) ?? "")
        }
        device.onResponse = { [weak self] id, result, error in
            guard let self else { return }
            if let error {
                self.log(.error, "response #\(id)", error)
            } else {
                self.log(.rx, "response #\(id)", self.encode(result))
            }
        }
        device.onNotification = { [weak self] method, params in
            guard let self else { return }
            self.log(.notify, method, self.describeNotification(method, params))
        }
        device.onDeviceLog = { [weak self] line in
            self?.log(.device, "firmware log", line)
        }
        device.onDisconnect = { [weak self] reason in
            guard let self else { return }
            self.connected = false
            self.deviceName = "—"
            self.firmware = "—"
            self.battery = "—"
            self.log(.info, "disconnected", reason)
        }
    }

    var visibleEntries: [LogEntry] {
        entries.filter { visibleKinds.contains($0.kind) }
    }

    // MARK: - Connection

    func connect() {
        do {
            try device.connect()
            connected = true
            lastError = nil
            deviceName = device.info?.product ?? "—"
            let transport = device.info?.transport ?? "?"
            log(.info, "connected", "\(deviceName)  ·  \(transport)  ·  pid 0x\(String(device.info?.productID ?? 0, radix: 16, uppercase: true))")
            refreshStatus()
        } catch {
            connected = false
            lastError = error.localizedDescription
            log(.error, "connect failed", error.localizedDescription)
        }
    }

    func disconnect() {
        device.disconnect(reason: "closed by user")
        connected = false
    }

    func refreshStatus() {
        device.call("sys.version", params: nil) { [weak self] result, _ in
            guard let self, let dict = result as? [String: Any], let v = dict["version"] as? String else { return }
            self.firmware = v
        }
        device.call("device.status", params: nil) { [weak self] result, _ in
            guard let self, let dict = result as? [String: Any] else { return }
            if let pct = dict["battery"] as? Int {
                let charging = (dict["is_charging"] as? Bool) == true
                self.battery = "\(pct)%\(charging ? " ⚡" : "")"
            }
        }
    }

    // MARK: - Lighting

    /// Push the current editor values to every selected key.
    func applyToSelection() {
        guard !selection.isEmpty else {
            log(.info, "nothing to do", "no keys selected")
            return
        }
        let packed = editColor.packedRGB
        for index in selection where index < keys.count {
            keys[index] = KeyState(
                color: editColor,
                effect: editEffect,
                brightness: editBrightness,
                speed: editSpeed,
                isLit: editEffect != .off && editBrightness > 0
            )
        }
        let threads = selection.sorted().map {
            OAI.Thread(
                id: $0,
                color: packed,
                brightness: editBrightness,
                effect: editEffect,
                speed: editSpeed
            )
        }
        send(threads: threads)
    }

    /// Send the whole pad at once, so what you see is exactly what the device has.
    func applyWholePad() {
        let threads = (0..<Pad.keyCount).map { index -> OAI.Thread in
            let k = keys[index]
            return OAI.Thread(
                id: index,
                color: k.color.packedRGB,
                brightness: k.isLit ? k.brightness : 0,
                effect: k.isLit ? k.effect : .off,
                speed: k.speed
            )
        }
        send(threads: threads)
    }

    func clearSelection() {
        for index in selection where index < keys.count {
            keys[index].isLit = false
        }
        send(threads: selection.sorted().map { OAI.Thread(id: $0, brightness: 0, effect: .off) })
    }

    /// Thread state paints over zone state, so turning the pad off means
    /// clearing both — clearing the zones alone leaves the keys lit.
    func allOff() {
        for index in keys.indices { keys[index].isLit = false }
        let threads = (0...Pad.maxThreadID).map {
            OAI.Thread(id: $0, brightness: 0, effect: .off, syncKeys: false, syncAmbient: false)
        }
        send(threads: threads)
        device.call(OAI.methodRGBConfig, params: OAI.rgbConfigParams(keys: .dark, ambient: .dark))
    }

    func applyAmbient() {
        let zone = OAI.Zone(
            effect: ambientEffect,
            brightness: ambientBrightness,
            speed: ambientSpeed,
            magic: 1,
            color: ambientColor.packedRGB
        )
        // Leave the keys zone dark so it does not compete with per-key colours.
        device.call(OAI.methodRGBConfig, params: OAI.rgbConfigParams(keys: .dark, ambient: zone))
    }

    func applyKeysZone() {
        let zone = OAI.Zone(
            effect: editEffect,
            brightness: editBrightness,
            speed: editSpeed,
            magic: 1,
            color: editColor.packedRGB
        )
        device.call(OAI.methodRGBConfig, params: OAI.rgbConfigParams(keys: zone, ambient: .dark))
    }

    /// Walk one lit key across the pad — the test that proves id → key mapping.
    func runWalk() {
        Task { @MainActor in
            for index in 0..<Pad.keyCount {
                let threads = (0..<Pad.keyCount).map {
                    OAI.Thread(
                        id: $0,
                        color: $0 == index ? 0xFFFFFF : 0,
                        brightness: $0 == index ? 1 : 0,
                        effect: $0 == index ? .solid : .off
                    )
                }
                send(threads: threads)
                for i in keys.indices { keys[i].isLit = (i == index) }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            allOff()
        }
    }

    /// Send a raw JSON-RPC call typed by hand.
    func sendRaw(method: String, paramsJSON: String) {
        let trimmed = paramsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        var params: Any?
        if !trimmed.isEmpty {
            guard let data = trimmed.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                log(.error, "bad params", "params must be valid JSON (object, array, or literal)")
                return
            }
            params = decoded
        }
        device.call(method, params: params)
    }

    private func send(threads: [OAI.Thread]) {
        device.call(OAI.methodThreads, params: OAI.threadsParams(threads))
    }

    // MARK: - Log

    func clearLog() { entries.removeAll() }

    func copyLog() {
        let text = visibleEntries.map { entry in
            "\(Self.stamp.string(from: entry.at))  \(entry.kind.rawValue)  \(entry.title)  \(entry.detail)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func log(_ kind: LogEntry.Kind, _ title: String, _ detail: String) {
        entries.append(LogEntry(kind: kind, title: title, detail: detail))
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
    }

    private func encode(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if JSONSerialization.isValidJSONObject(value) {
            let options: JSONSerialization.WritingOptions = prettyPrint ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: options),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return String(describing: value)
    }

    /// The two notification channels carry abbreviated keys too.
    private func describeNotification(_ method: String, _ params: Any?) -> String {
        guard let dict = params as? [String: Any] else { return encode(params) }
        switch method {
        case OAI.notifyHID:
            let key = dict["k"].map { "\($0)" } ?? "?"
            let act = dict["act"].map { " act=\($0)" } ?? ""
            let agent = dict["ag"].map { " agent=\($0)" } ?? ""
            return "key=\(key)\(act)\(agent)   \(encode(params))"
        case OAI.notifyJoystick:
            let angle = dict["a"].map { "\($0)" } ?? "?"
            let distance = dict["d"].map { "\($0)" } ?? "?"
            return "angle=\(angle) distance=\(distance)   \(encode(params))"
        default:
            return encode(params)
        }
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
