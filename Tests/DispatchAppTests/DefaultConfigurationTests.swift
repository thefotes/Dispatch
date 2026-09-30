@testable import DispatchApp
import DispatchCore
import DispatchMacOS
import DispatchProviders
import Foundation
import XCTest

final class DefaultConfigurationTests: XCTestCase {
    func testDefaultConfigurationCompilesAgainstInstalledActions() throws {
        let catalog = try ActionCatalog(
            definitions: HerdrActions.definitions + MacOSActions.definitions
        )

        XCTAssertNoThrow(try CompiledBindings.compile(DefaultConfiguration.value, catalog: catalog))
    }

    func testReadingOrderKeysResolveToOneBasedHerdrSlots() throws {
        let resolver = try makeResolver()

        for (offset, key) in [0, 1, 2, 3, 4, 5].enumerated() {
            let actions = resolver.resolve(event(control: .key(key), gesture: .pressed))
            XCTAssertEqual(actions.map(\.id), [HerdrActions.focusAgentSlot])
            XCTAssertEqual(actions.first?.arguments["slot"], .integer(offset + 1))
        }
    }

    func testDefaultDialJoystickAndWideKeyBindings() throws {
        let resolver = try makeResolver()

        XCTAssertEqual(
            resolver.resolve(event(control: .dial, gesture: .rotated(steps: 1))).first?.id,
            HerdrActions.cycleWorkspace
        )
        XCTAssertEqual(
            resolver.resolve(event(control: .joystick, gesture: .moved(direction: .left, magnitude: 1))).first?.id,
            HerdrActions.focusPaneDirection
        )
        let wideKeyAction = resolver.resolve(event(control: .key(10), gesture: .pressed)).first
        XCTAssertEqual(wideKeyAction?.id, MacOSActions.shortcut)
        XCTAssertEqual(wideKeyAction?.arguments["key"], .string("rightCommand"))
    }

    func testThirdRowCreatesWorkspaceSplitsCyclesAgentCommandAndClosesPane() throws {
        let resolver = try makeResolver()
        let actions = (6...9).map { resolver.resolve(event(control: .key($0), gesture: .pressed)).first }

        XCTAssertEqual(actions.map { $0?.id }, [
            HerdrActions.createWorkspace,
            HerdrActions.splitFocusedPane,
            HerdrActions.cycleText,
            HerdrActions.closeFocusedPane
        ])
        XCTAssertEqual(actions[1]?.arguments["direction"], .string("right"))
        XCTAssertEqual(
            actions[2]?.arguments["options"],
            .array([.string("claude"), .string("codex"), .string("opencode")])
        )
    }

    func testHerdrPresentationUsesReadingOrderAndWorstVisibleState() {
        let state = HerdrState(
            availability: .available,
            agents: [
                .init(paneID: "p1", name: "one", status: "idle", focused: false),
                .init(paneID: "p2", name: "two", status: "blocked", focused: true),
                .init(paneID: "p3", name: "three", status: "working", focused: false)
            ]
        )

        let presentation = HerdrPresentationRenderer().render(state)

        XCTAssertEqual(presentation.controls[.key(0)]?.brightness, 0.3)
        XCTAssertEqual(
            presentation.controls[.key(1)]?.color,
            RGBColor(red: 255, green: 45, blue: 65)
        )
        XCTAssertEqual(
            presentation.controls[.key(2)]?.color,
            RGBColor(red: 30, green: 145, blue: 255)
        )
        XCTAssertEqual(presentation.ambient, presentation.controls[.key(1)])
    }

    func testHerdrPresentationRetainsConfiguredSpecialControlsWithoutAgents() {
        let presentation = HerdrPresentationRenderer().render(.disconnected)

        XCTAssertNotNil(presentation.controls[.key(9)])
        XCTAssertNotNil(presentation.controls[.key(10)])
        XCTAssertNil(presentation.ambient)
    }

    func testHerdrPresentationUsesConfiguredStatusPalette() {
        let custom = ControlAppearance(
            color: RGBColor(red: 1, green: 2, blue: 3),
            brightness: 0.4
        )
        let palette = StatusPalette(
            appearances: ["working": custom, "unknown": custom],
            ambientPriority: ["working", "unknown"]
        )
        let state = HerdrState(
            availability: .available,
            agents: [.init(paneID: "p1", name: nil, status: "working", focused: true)]
        )

        let configuration = DispatchConfiguration(
            bindings: DefaultConfiguration.value.bindings,
            statusPalette: palette
        )

        let presentation = HerdrPresentationRenderer().render(state, configuration: configuration)

        XCTAssertEqual(presentation.controls[.key(0)], custom)
        XCTAssertEqual(presentation.ambient, custom)
    }

    private func makeResolver() throws -> BindingResolver {
        let catalog = try ActionCatalog(
            definitions: HerdrActions.definitions + MacOSActions.definitions
        )
        return BindingResolver(
            bindings: try CompiledBindings.compile(DefaultConfiguration.value, catalog: catalog)
        )
    }

    private func event(control: LogicalControl, gesture: Gesture) -> DispatchEvent {
        DispatchEvent(
            source: DeviceIdentity(rawValue: "test"),
            control: control,
            gesture: gesture,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }
}
