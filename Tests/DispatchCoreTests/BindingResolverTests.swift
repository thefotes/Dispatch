import Foundation
import XCTest
@testable import DispatchCore

final class BindingResolverTests: XCTestCase {
    private let source = DeviceIdentity(rawValue: "test-pad")

    func testResolverReturnsOrderedMacro() throws {
        let catalog = try testCatalog()
        let configuration = DispatchConfiguration(bindings: [
            BindingDefinition(
                event: EventPattern(control: .key(9), gesture: .pressed),
                actions: [
                    ConfiguredAction(id: "herdr.focus", arguments: ["slot": .integer(2)]),
                    ConfiguredAction(id: "herdr.closeFocusedPane")
                ]
            )
        ])
        let resolver = BindingResolver(
            bindings: try CompiledBindings.compile(configuration, catalog: catalog)
        )

        let actions = resolver.resolve(event(control: .key(9), gesture: .pressed))

        XCTAssertEqual(actions.map(\.id.rawValue), ["herdr.focus", "herdr.closeFocusedPane"])
        XCTAssertEqual(actions.first?.arguments, ["slot": .integer(2)])
    }

    func testResolverReturnsNothingForUnboundEvent() throws {
        let configuration = DispatchConfiguration(bindings: [
            BindingDefinition(
                event: EventPattern(control: .key(1), gesture: .pressed),
                actions: [ConfiguredAction(id: "herdr.closeFocusedPane")]
            )
        ])
        let resolver = BindingResolver(
            bindings: try CompiledBindings.compile(configuration, catalog: testCatalog())
        )

        XCTAssertTrue(resolver.resolve(event(control: .key(2), gesture: .pressed)).isEmpty)
        XCTAssertTrue(resolver.resolve(event(control: .key(1), gesture: .released)).isEmpty)
    }

    func testDirectionalPatternsMatchSignedRotationAndMovement() throws {
        let bindings = [
            BindingDefinition(
                event: EventPattern(control: .dial, gesture: .rotated(direction: .clockwise)),
                actions: [ConfiguredAction(id: "herdr.closeFocusedPane")]
            ),
            BindingDefinition(
                event: EventPattern(control: .joystick, gesture: .moved(direction: .left)),
                actions: [ConfiguredAction(id: "herdr.closeFocusedPane")]
            )
        ]
        let resolver = BindingResolver(bindings: try CompiledBindings.compile(
            DispatchConfiguration(bindings: bindings),
            catalog: testCatalog()
        ))

        XCTAssertEqual(
            resolver.resolve(event(control: .dial, gesture: .rotated(steps: 2))).count,
            1
        )
        XCTAssertTrue(
            resolver.resolve(event(control: .dial, gesture: .rotated(steps: -1))).isEmpty
        )
        XCTAssertEqual(
            resolver.resolve(
                event(control: .joystick, gesture: .moved(direction: .left, magnitude: 0.2))
            ).count,
            1
        )
    }

    func testCompilerRejectsDuplicateAndOverlappingBindings() throws {
        let exact = BindingDefinition(
            event: EventPattern(control: .dial, gesture: .rotated(direction: .clockwise)),
            actions: [ConfiguredAction(id: "herdr.closeFocusedPane")]
        )
        let broad = BindingDefinition(
            event: EventPattern(control: .dial, gesture: .rotated(direction: nil)),
            actions: [ConfiguredAction(id: "herdr.closeFocusedPane")]
        )

        XCTAssertThrowsError(try CompiledBindings.compile(
            DispatchConfiguration(bindings: [exact, exact]),
            catalog: testCatalog()
        )) {
            XCTAssertEqual($0 as? ConfigurationError, .ambiguousBindings(first: 0, second: 1))
        }
        XCTAssertThrowsError(try CompiledBindings.compile(
            DispatchConfiguration(bindings: [exact, broad]),
            catalog: testCatalog()
        )) {
            XCTAssertEqual($0 as? ConfigurationError, .ambiguousBindings(first: 0, second: 1))
        }
    }

    func testCompilerRejectsUnsupportedVersionActionAndEmptyMacro() throws {
        XCTAssertThrowsError(try CompiledBindings.compile(
            DispatchConfiguration(version: 99, bindings: []),
            catalog: testCatalog()
        )) {
            XCTAssertEqual($0 as? ConfigurationError, .unsupportedVersion(99))
        }

        let unknown = BindingDefinition(
            event: EventPattern(control: .key(1), gesture: .pressed),
            actions: [ConfiguredAction(id: "unknown.action")]
        )
        XCTAssertThrowsError(try CompiledBindings.compile(
            DispatchConfiguration(bindings: [unknown]),
            catalog: testCatalog()
        )) {
            XCTAssertEqual(
                $0 as? ConfigurationError,
                .unsupportedAction(binding: 0, action: 0, id: "unknown.action")
            )
        }

        let empty = BindingDefinition(
            event: EventPattern(control: .key(1), gesture: .pressed),
            actions: []
        )
        XCTAssertThrowsError(try CompiledBindings.compile(
            DispatchConfiguration(bindings: [empty]),
            catalog: testCatalog()
        )) {
            XCTAssertEqual($0 as? ConfigurationError, .emptyMacro(binding: 0))
        }
    }

    func testCompilerReportsArgumentLocation() throws {
        let binding = BindingDefinition(
            event: EventPattern(control: .key(3), gesture: .pressed),
            actions: [ConfiguredAction(id: "herdr.focus", arguments: ["slot": .string("three")])]
        )

        XCTAssertThrowsError(try CompiledBindings.compile(
            DispatchConfiguration(bindings: [binding]),
            catalog: testCatalog()
        )) {
            XCTAssertEqual(
                $0 as? ConfigurationError,
                .invalidArgumentType(binding: 0, action: 0, name: "slot", expected: .integer)
            )
        }
    }

    private func event(control: LogicalControl, gesture: Gesture) -> DispatchEvent {
        DispatchEvent(source: source, control: control, gesture: gesture, timestamp: Date())
    }

    private func testCatalog() throws -> ActionCatalog {
        try ActionCatalog(definitions: [
            ActionDefinition(
                id: "herdr.focus",
                title: "Focus",
                summary: "Focus a Herdr slot",
                arguments: [
                    ActionArgumentDefinition(name: "slot", type: .integer, summary: "Slot")
                ]
            ),
            ActionDefinition(
                id: "herdr.closeFocusedPane",
                title: "Close",
                summary: "Close the focused Herdr pane"
            )
        ])
    }
}
