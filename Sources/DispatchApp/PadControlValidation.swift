import DispatchCore
import DispatchCreatorMicro

/// Rejects bindings and lights for keys the Creator Micro does not have.
/// The core configuration names controls without knowing the pad, so a
/// binding on a missing key would otherwise load and never run.
enum PadControlValidation {
    static func validate(_ configuration: DispatchConfiguration) throws {
        let keys = CreatorMicroGeometry.keys
        for (index, binding) in configuration.bindings.enumerated() {
            if case let .key(key) = binding.event.control, !keys.contains(key) {
                throw AppConfigurationError(
                    path: "bindings[\(index)].when.control.index",
                    reason: "The pad has no key \(key). \(describe(keys)) The wide key is key 10."
                )
            }
        }
        let litKeys = CreatorMicroGeometry.litKeys
        for (index, light) in (configuration.lights ?? []).enumerated() {
            guard case let .key(key) = light.control, litKeys.contains(key) else {
                throw AppConfigurationError(
                    path: "lights[\(index)].control",
                    reason: "The pad cannot light \(light.control). \(describe(litKeys, lit: true))"
                )
            }
        }
    }

    /// "Its keys are 0–10 and 12." for a list of key indexes.
    private static func describe(_ keys: [Int], lit: Bool = false) -> String {
        var ranges: [ClosedRange<Int>] = []
        for key in keys.sorted() {
            if let last = ranges.last, last.upperBound + 1 == key {
                ranges[ranges.count - 1] = last.lowerBound...key
            } else {
                ranges.append(key...key)
            }
        }
        let parts = ranges.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        return lit ? "Only keys \(list) have lights." : "Its keys are \(list)."
    }
}
