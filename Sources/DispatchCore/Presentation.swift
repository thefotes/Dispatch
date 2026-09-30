import Foundation

/// A stable, serializable device color value. UI-framework colors stay at the
/// composition edge because they can be dynamic and color-space dependent.
public struct RGBColor: Codable, Equatable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = RGBColor(red: 0, green: 0, blue: 0)

    private enum CodingKeys: String, CodingKey {
        case red
        case green
        case blue
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(["red", "green", "blue"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        red = try container.decode(UInt8.self, forKey: .red)
        green = try container.decode(UInt8.self, forKey: .green)
        blue = try container.decode(UInt8.self, forKey: .blue)
    }
}

public enum PresentationEffect: String, Codable, Equatable, Sendable {
    case off
    case solid
    case snake
    case rainbow
    case breath
    case gradient
    case shallowBreath
}

public struct ControlAppearance: Codable, Equatable, Sendable {
    public let color: RGBColor
    public let brightness: Double
    public let effect: PresentationEffect
    public let speed: Double

    public init(
        color: RGBColor,
        brightness: Double = 1,
        effect: PresentationEffect = .solid,
        speed: Double = 0
    ) {
        self.color = color
        self.brightness = brightness
        self.effect = effect
        self.speed = speed
    }

    private enum CodingKeys: String, CodingKey {
        case color
        case brightness
        case effect
        case speed
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(["color", "brightness", "effect", "speed"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decode(RGBColor.self, forKey: .color)
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 1
        effect = try container.decodeIfPresent(PresentationEffect.self, forKey: .effect) ?? .solid
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 0
        guard brightness.isFinite, (0...1).contains(brightness) else {
            throw DecodingError.dataCorruptedError(
                forKey: .brightness,
                in: container,
                debugDescription: "Brightness must be a finite value from zero through one."
            )
        }
        guard speed.isFinite, (0...1).contains(speed) else {
            throw DecodingError.dataCorruptedError(
                forKey: .speed,
                in: container,
                debugDescription: "Effect speed must be a finite value from zero through one."
            )
        }
    }
}

/// A configured, fixed appearance for one control.
public struct ControlLight: Codable, Equatable, Sendable {
    public let control: LogicalControl
    public let appearance: ControlAppearance

    public init(control: LogicalControl, appearance: ControlAppearance) {
        self.control = control
        self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey {
        case control
        case appearance
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(["control", "appearance"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        control = try container.decode(LogicalControl.self, forKey: .control)
        appearance = try container.decode(ControlAppearance.self, forKey: .appearance)
    }
}

/// A complete, device-independent desired appearance for a pad.
public struct PadPresentation: Codable, Equatable, Sendable {
    public let controls: [LogicalControl: ControlAppearance]
    public let ambient: ControlAppearance?

    public init(
        controls: [LogicalControl: ControlAppearance] = [:],
        ambient: ControlAppearance? = nil
    ) {
        self.controls = controls
        self.ambient = ambient
    }
}

public struct PresentationState: Codable, Equatable, Sendable {
    public let values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }
}

public struct PresentationRule: Codable, Equatable, Sendable {
    public let stateKey: String
    public let equals: String
    public let controls: [LogicalControl: ControlAppearance]
    public let ambient: ControlAppearance?

    public init(
        stateKey: String,
        equals: String,
        controls: [LogicalControl: ControlAppearance] = [:],
        ambient: ControlAppearance? = nil
    ) {
        self.stateKey = stateKey
        self.equals = equals
        self.controls = controls
        self.ambient = ambient
    }
}

public struct PresentationConfiguration: Codable, Equatable, Sendable {
    public let base: PadPresentation
    public let rules: [PresentationRule]

    public init(base: PadPresentation = PadPresentation(), rules: [PresentationRule] = []) {
        self.base = base
        self.rules = rules
    }
}

/// Provider status names remain opaque to Core while their visual treatment is configurable.
public struct StatusPalette: Codable, Equatable, Sendable {
    public let appearances: [String: ControlAppearance]
    public let ambientPriority: [String]

    public init(
        appearances: [String: ControlAppearance],
        ambientPriority: [String]
    ) {
        self.appearances = appearances
        self.ambientPriority = ambientPriority
    }

    private enum CodingKeys: String, CodingKey {
        case appearances
        case ambientPriority
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(["appearances", "ambientPriority"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearances = try container.decode([String: ControlAppearance].self, forKey: .appearances)
        ambientPriority = try container.decode([String].self, forKey: .ambientPriority)
    }
}

/// Deterministically applies matching rules in declaration order.
public struct PresentationRenderer: Sendable {
    public init() {}

    public func render(
        state: PresentationState,
        configuration: PresentationConfiguration
    ) -> PadPresentation {
        var controls = configuration.base.controls
        var ambient = configuration.base.ambient
        for rule in configuration.rules where state.values[rule.stateKey] == rule.equals {
            controls.merge(rule.controls) { _, replacement in replacement }
            if let replacement = rule.ambient {
                ambient = replacement
            }
        }
        return PadPresentation(controls: controls, ambient: ambient)
    }
}
