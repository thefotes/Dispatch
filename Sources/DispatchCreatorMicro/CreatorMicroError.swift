import Foundation
import IOKit

public enum CreatorMicroError: Error, Equatable, Sendable {
    case invalidReportLength(Int)
    case invalidReportIdentifier(UInt8)
    case invalidPayloadLength(Int)
    case invalidUTF8
    case messageTooLarge
    case invalidJSON(String)
    case malformedEnvelope(String)
    case requestIdentifiersExhausted
    case disconnected
    case alreadyConnected
    case timeout
    case remoteError(code: Int?, message: String)
    case unsupportedNotification(String)
    case invalidKeymap(String)
    case verificationFailed
    case ioKit(Int32)
    case liveHardwareUnavailable(String)
    case secureInputHeld(SecureInputOwner)

    public enum SecureInputOwner: Equatable, Sendable {
        case application(String)
        /// The recorded owner has exited without releasing Secure Input.
        case stale
    }
}

extension CreatorMicroError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .invalidReportLength(length): "The pad sent a \(length)-byte report."
        case let .invalidReportIdentifier(identifier): "The pad sent an unknown report ID \(identifier)."
        case let .invalidPayloadLength(length): "The pad sent a payload with an invalid length of \(length)."
        case .invalidUTF8: "The pad sent text that is not valid UTF-8."
        case .messageTooLarge: "The pad sent a message larger than 64 KiB."
        case let .invalidJSON(message): "The pad sent invalid JSON: \(message)"
        case let .malformedEnvelope(message): "The pad sent a malformed message: \(message)"
        case .requestIdentifiersExhausted: "Dispatch ran out of request identifiers for the pad."
        case .disconnected: "The pad disconnected."
        case .alreadyConnected: "The pad is already connected."
        case .timeout: "The pad did not answer in time."
        case let .remoteError(code?, message): "The pad rejected the request: \(message) (\(code))"
        case let .remoteError(nil, message): "The pad rejected the request: \(message)"
        case let .unsupportedNotification(method): "The pad sent an unsupported notification: \(method)"
        case let .invalidKeymap(message): "The keymap is invalid: \(message)"
        case .verificationFailed: "The keymap read back from the pad did not match what was written."
        case let .ioKit(code): Self.describe(ioKitCode: code)
        case let .liveHardwareUnavailable(message): message
        case let .secureInputHeld(.application(name)):
            "\(name) has Secure Input turned on, which blocks the pad. Leave any password field in \(name), "
                + "turn off its Secure Keyboard Entry, or lock and unlock the screen."
        case .secureInputHeld(.stale):
            "Secure Input is stuck on, which blocks the pad. Lock and unlock the screen to reset it."
        }
    }

    private static func describe(ioKitCode code: Int32) -> String {
        switch code {
        case kIOReturnNotPermitted:
            "Input Monitoring is off for Dispatch. Turn it on in System Settings > "
                + "Privacy & Security > Input Monitoring."
        case kIOReturnNoDevice: "The pad is not plugged in."
        default: "IOKit error 0x\(String(UInt32(bitPattern: code), radix: 16, uppercase: true))."
        }
    }
}
