import DispatchCore
import Foundation
import PropertyBased
import Testing

/// Randomized checks that binding compilation rejects exactly the binding sets
/// in which one event could trigger two bindings. A failure prints the seed;
/// add `.fixedSeed("…")` to the `@Test` to replay it (see CONTRIBUTING.md).
@Suite struct BindingCompilationPropertyTests {
    @Test func compilationRejectsExactlyTheAmbiguousBindingSets() async throws {
        let catalog = try Self.catalog()
        await propertyCheck(input: Self.pattern.array(of: 0...6)) { patterns in
            let ambiguous = Self.events.contains { event in
                patterns.filter { $0.matches(event) }.count > 1
            }
            #expect(Self.compiles(patterns, catalog: catalog) == !ambiguous)
        }
    }

    @Test func twoPatternsConflictSymmetricallyAndOnlyWhenAGestureMatchesBoth() async throws {
        let catalog = try Self.catalog()
        await propertyCheck(input: Self.gesturePattern, Self.gesturePattern) { first, second in
            let firstBinding = EventPattern(control: .dial, gesture: first)
            let secondBinding = EventPattern(control: .dial, gesture: second)
            let shared = Self.gestures.contains { first.matches($0) && second.matches($0) }
            #expect(Self.compiles([firstBinding, secondBinding], catalog: catalog) == !shared)
            #expect(Self.compiles([secondBinding, firstBinding], catalog: catalog) == !shared)
        }
    }

    private static let controls: [LogicalControl] = [.key(0), .key(1), .dial, .joystick]

    private static let gesturePatterns: [GesturePattern] = {
        let rotationDirections: [RotationDirection?] = [nil, .clockwise, .counterclockwise]
        let moveDirections: [Direction?] = [nil] + Direction.allCases
        let rotations = rotationDirections.map { GesturePattern.rotated(direction: $0) }
        let moves = moveDirections.map { GesturePattern.moved(direction: $0) }
        return [.pressed, .released] + rotations + moves
    }()

    /// Every gesture shape the patterns distinguish, including a zero-step
    /// rotation that no pattern matches.
    private static let gestures: [Gesture] = {
        let rotations: [Gesture] = [-3, -1, 0, 1, 3].map { .rotated(steps: $0) }
        let moves: [Gesture] = Direction.allCases.map { .moved(direction: $0, magnitude: 1) }
        return [.pressed, .released] + rotations + moves
    }()

    private static let events: [DispatchEvent] = controls.flatMap { control in
        gestures.map { gesture in
            DispatchEvent(
                source: DeviceIdentity(rawValue: "property-test"),
                control: control,
                gesture: gesture,
                timestamp: Date(timeIntervalSince1970: 0)
            )
        }
    }

    private static let gesturePattern = Gen<GesturePattern?>.element(of: gesturePatterns).compactMap { $0 }

    private static let pattern = Gen<EventPattern?>.element(
        of: controls.flatMap { control in gesturePatterns.map { EventPattern(control: control, gesture: $0) } }
    ).compactMap { $0 }

    private static func catalog() throws -> ActionCatalog {
        try ActionCatalog(definitions: [
            ActionDefinition(id: "test.noop", title: "No-op", summary: "Does nothing", arguments: [])
        ])
    }

    /// Compiles one binding per pattern. Only ambiguity can fail compilation
    /// here, because every binding uses a valid action.
    private static func compiles(_ patterns: [EventPattern], catalog: ActionCatalog) -> Bool {
        let configuration = DispatchConfiguration(bindings: patterns.map {
            BindingDefinition(event: $0, actions: [ConfiguredAction(id: "test.noop")])
        })
        do {
            _ = try CompiledBindings.compile(configuration, catalog: catalog)
            return true
        } catch ConfigurationError.ambiguousBindings {
            return false
        } catch {
            Issue.record("Unexpected compilation error: \(error)")
            return false
        }
    }
}
