import DispatchCore
import Foundation

public actor RecordingActionSink {
    private var invocations: [ActionInvocation] = []

    public init() {}

    public func record(_ invocation: ActionInvocation) {
        invocations.append(invocation)
    }

    public func recordedInvocations() -> [ActionInvocation] {
        invocations
    }

    nonisolated public func registration(
        definition: ActionDefinition,
        isAvailable: @escaping ActionRegistration.Availability = { true }
    ) -> ActionRegistration {
        ActionRegistration(definition: definition, isAvailable: isAvailable) { [weak self] invocation in
            await self?.record(invocation)
        }
    }
}
