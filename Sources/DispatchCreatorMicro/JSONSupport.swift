import DispatchCore

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case let .integer(value): return value
        case let .number(value) where value.rounded() == value: return Int(exactly: value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .integer(value): return Double(value)
        case let .number(value): return value
        default: return nil
        }
    }
}
