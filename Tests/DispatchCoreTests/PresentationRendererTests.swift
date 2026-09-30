import XCTest
@testable import DispatchCore

final class PresentationRendererTests: XCTestCase {
    private let off = ControlAppearance(color: .black, brightness: 0)
    private let red = ControlAppearance(color: RGBColor(red: 255, green: 0, blue: 0))
    private let green = ControlAppearance(color: RGBColor(red: 0, green: 255, blue: 0))
    private let blue = ControlAppearance(color: RGBColor(red: 0, green: 0, blue: 255))

    func testRendererUsesBaseWhenNoRulesMatch() {
        let base = PadPresentation(controls: [.key(1): red], ambient: off)
        let configuration = PresentationConfiguration(
            base: base,
            rules: [PresentationRule(stateKey: "provider", equals: "ready", ambient: green)]
        )

        let result = PresentationRenderer().render(
            state: PresentationState(values: ["provider": "offline"]),
            configuration: configuration
        )

        XCTAssertEqual(result, base)
    }

    func testRendererAppliesAllMatchingRulesInDeclarationOrder() {
        let configuration = PresentationConfiguration(
            base: PadPresentation(controls: [.key(1): off], ambient: off),
            rules: [
                PresentationRule(
                    stateKey: "provider",
                    equals: "ready",
                    controls: [.key(1): red, .key(2): green],
                    ambient: red
                ),
                PresentationRule(
                    stateKey: "focus",
                    equals: "active",
                    controls: [.key(1): blue],
                    ambient: blue
                )
            ]
        )
        let state = PresentationState(values: ["provider": "ready", "focus": "active"])

        let first = PresentationRenderer().render(state: state, configuration: configuration)
        let second = PresentationRenderer().render(state: state, configuration: configuration)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.controls[.key(1)], blue)
        XCTAssertEqual(first.controls[.key(2)], green)
        XCTAssertEqual(first.ambient, blue)
    }

    func testPresentationRoundTripsThroughJSON() throws {
        let presentation = PadPresentation(
            controls: [.key(1): red, .dial: blue],
            ambient: green
        )

        let decoded = try JSONDecoder().decode(
            PadPresentation.self,
            from: JSONEncoder().encode(presentation)
        )

        XCTAssertEqual(decoded, presentation)
    }
}
