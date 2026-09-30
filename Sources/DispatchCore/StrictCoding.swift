import Foundation

struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension Decoder {
    func rejectUnknownKeys(_ allowedKeys: Set<String>) throws {
        let container = try container(keyedBy: AnyCodingKey.self)
        if let unknown = container.allKeys.map(\.stringValue).first(where: { !allowedKeys.contains($0) }) {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: codingPath,
                    debugDescription: "Unknown field \"\(unknown)\"."
                )
            )
        }
    }
}
