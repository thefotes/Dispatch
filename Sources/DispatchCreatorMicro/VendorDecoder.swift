import DispatchCore
import Foundation

/// Decodes vendor notifications into Dispatch events. The decoder is stateful:
/// the wide key's two switches are reported as one control, pressed while
/// either switch is held, and key switch chatter is filtered out.
public struct CreatorMicroVendorDecoder: Sendable {
    /// A key press this soon after the same key's release is switch chatter,
    /// not a new press. On 2026-09-29 the pad reported a release and a new
    /// press 5–7 ms apart in the middle of one physical press, while the
    /// fastest deliberate taps came 29 ms after the previous release.
    public static let chatterWindow: TimeInterval = 0.015

    public let source: DeviceIdentity
    private var heldWideSwitches: Set<Int> = []
    private var lastRelease: [Int: Date] = [:]
    /// Keys whose current press was chatter, so its release is dropped too.
    private var chatteringKeys: Set<Int> = []

    public init(source: DeviceIdentity) {
        self.source = source
    }

    public mutating func decode(
        _ message: CreatorMicroRPCMessage,
        timestamp: Date = Date()
    ) throws -> DispatchEvent? {
        guard case let .notification(method, parameters) = message else { return nil }
        switch method {
        case "v.oai.hid":
            return try decodeHID(parameters, timestamp: timestamp)
        default:
            return nil
        }
    }

    private mutating func decodeHID(_ parameters: JSONValue?, timestamp: Date) throws -> DispatchEvent? {
        guard let object = parameters?.objectValue else {
            throw CreatorMicroError.malformedEnvelope("v.oai.hid parameters are not an object")
        }
        guard let agentCode = agentCode(in: object), (0...18).contains(agentCode) else {
            throw CreatorMicroError.malformedEnvelope("v.oai.hid has no valid AG code")
        }
        let isPressed = try pressState(object["act"])
        let control: LogicalControl
        let gesture: Gesture
        switch agentCode {
        case CreatorMicroGeometry.wideKeySwitches:
            guard let wideGesture = wideKeyGesture(switch: agentCode, isPressed: isPressed) else { return nil }
            let key = CreatorMicroGeometry.wideKeySwitches.lowerBound
            guard filterChatter(key: key, isPressed: wideGesture == .pressed, timestamp: timestamp) else { return nil }
            control = .key(key)
            gesture = wideGesture
        case 0...12:
            guard filterChatter(key: agentCode, isPressed: isPressed, timestamp: timestamp) else { return nil }
            control = .key(agentCode)
            gesture = isPressed ? .pressed : .released
        case 13, 14:
            // Each detent reports a press and a release; the release is not a second step.
            guard isPressed else { return nil }
            control = .dial
            gesture = .rotated(steps: agentCode == 13 ? 1 : -1)
        case 15...18:
            // A push reports a press and its return reports a release; only the push moves.
            guard isPressed else { return nil }
            control = .joystick
            gesture = .moved(direction: CreatorMicroGeometry.joystickDirections[agentCode - 15], magnitude: 1)
        default:
            throw CreatorMicroError.malformedEnvelope("Unsupported AG code")
        }
        return DispatchEvent(source: source, control: control, gesture: gesture, timestamp: timestamp)
    }

    /// Returns whether a key transition is real. A press inside the chatter
    /// window is dropped, and so is the release that ends it, leaving the
    /// earlier release as the one Dispatch saw.
    private mutating func filterChatter(key: Int, isPressed: Bool, timestamp: Date) -> Bool {
        if isPressed {
            if let released = lastRelease[key], timestamp.timeIntervalSince(released) < Self.chatterWindow {
                chatteringKeys.insert(key)
                let gap = Int((timestamp.timeIntervalSince(released) * 1000).rounded())
                Log.logger.notice("""
                    Ignored key \(key, privacy: .public) chatter \(gap, privacy: .public) ms after its release.
                    """)
                return false
            }
            return true
        }
        lastRelease[key] = timestamp
        return chatteringKeys.remove(key) == nil
    }

    private mutating func wideKeyGesture(switch agentCode: Int, isPressed: Bool) -> Gesture? {
        let wasHeld = !heldWideSwitches.isEmpty
        if isPressed {
            heldWideSwitches.insert(agentCode)
        } else {
            heldWideSwitches.remove(agentCode)
        }
        let isHeld = !heldWideSwitches.isEmpty
        guard wasHeld != isHeld else { return nil }
        return isHeld ? .pressed : .released
    }

    /// `k` names the control as `AGnn`, for example `{"k":"AG00","act":1}`
    /// (observed 2026-09-24, firmware 0.6.2).
    private func agentCode(in object: [String: JSONValue]) -> Int? {
        guard let code = object["k"]?.stringValue, code.hasPrefix("AG") else { return nil }
        return Int(code.dropFirst(2))
    }

    private func pressState(_ value: JSONValue?) throws -> Bool {
        // `act` is 1 on press and 0 on release (observed 2026-09-24).
        switch value?.intValue {
        case 1: return true
        case 0: return false
        default: throw CreatorMicroError.malformedEnvelope("Unknown v.oai.hid act value")
        }
    }
}
