import DispatchCore
import Foundation

public enum RuntimePhase: String, Codable, Equatable, Sendable {
    case disabled
    case starting
    case connecting
    case operational
    case degraded
    case stopping
}

public enum RuntimeIssue: Equatable, Sendable {
    case configuration(String)
    case device(String)
    case action(ActionID, String)
    case presentation(String)
}

public struct RuntimeSnapshot: Equatable, Sendable {
    public let phase: RuntimePhase
    public let issue: RuntimeIssue?
    public let processedEventCount: UInt64
    public let configurationVersion: Int?

    public init(
        phase: RuntimePhase,
        issue: RuntimeIssue? = nil,
        processedEventCount: UInt64 = 0,
        configurationVersion: Int? = nil
    ) {
        self.phase = phase
        self.issue = issue
        self.processedEventCount = processedEventCount
        self.configurationVersion = configurationVersion
    }

    public static let disabled = RuntimeSnapshot(phase: .disabled)
}
