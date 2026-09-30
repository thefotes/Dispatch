import DispatchCreatorMicro
import Foundation
import PropertyBased
import Testing

/// Randomized checks of HID message reassembly. A failure prints the seed;
/// add `.fixedSeed("…")` to the `@Test` to replay it (see CONTRIBUTING.md).
@Suite struct JSONMessageAssemblerPropertyTests {
    @Test func reassemblesMessagesSplitAtAnyBoundary() async {
        await propertyCheck(input: Self.messages, Self.fragmentSizes) { messages, sizes in
            let stream = Array(messages.joined(separator: [0x20, 0x0A]))
            var assembler = JSONMessageAssembler()
            var assembled: [Data] = []
            for fragment in Self.split(stream, sizes: sizes) {
                assembled += try assembler.append(fragment)
            }
            #expect(assembled == messages.map { Data($0) })
        }
    }

    @Test func rejectsInvalidUTF8InsideAString() async {
        await propertyCheck(input: Self.text, Self.nonASCIIByte, Self.fragmentSizes) { text, byte, sizes in
            // A byte of 0x80 or above followed directly by the string's closing
            // quote is never valid UTF-8: it is either a lone continuation byte,
            // a lead byte without its continuation, or a byte UTF-8 never uses.
            var message = Self.encode(["k": text])
            message.insert(byte, at: message.count - 2)
            var assembler = JSONMessageAssembler()
            #expect(throws: CreatorMicroError.self) {
                for fragment in Self.split(message, sizes: sizes) {
                    _ = try assembler.append(fragment)
                }
            }
        }
    }

    @Test func rejectsInputThatDoesNotStartWithAnObject() async {
        let leading = Gen.uint8(in: 0...0xFF).filter { ![0x20, 0x09, 0x0A, 0x0D, 0x7B].contains($0) }
        await propertyCheck(input: leading, Self.text) { byte, text in
            var assembler = JSONMessageAssembler()
            #expect(throws: CreatorMicroError.self) {
                _ = try assembler.append([0x20, byte] + Array(text.utf8))
            }
        }
    }

    /// Characters that exercise multi-byte UTF-8 and JSON's structural and
    /// escape characters inside strings.
    private static let characters: [Character] = [
        "a", "Z", "0", " ", "é", "ß", "中", "🙂", "👩‍💻", "\"", "\\", "{", "}", "[", "]", ":", ",", "\n", "\t"
    ]

    private static let text = Gen<Character?>.element(of: characters)
        .compactMap { $0 }
        .string(of: 0...12)

    /// Encoded JSON objects, each with a nested object, as the pad sends them.
    private static let messages = zip(text, text)
        .map { first, second -> [UInt8] in
            Self.encode(["m": first, "p": ["value": second, "n": 1]])
        }
        .array(of: 1...4)

    /// PropertyBased 2.0.0 traps (index out of bounds) generating from
    /// `Gen.uint8(in: 0x80...0xFF)`, a range that starts above zero and ends
    /// at `UInt8.max`, so the byte comes from an `Int` range instead.
    private static let nonASCIIByte = Gen.int(in: 0x80...0xFF).map { UInt8($0) }

    private static let fragmentSizes = Gen.int(in: 1...CreatorMicroHIDReport.maximumPayloadCount).array(of: 1...8)

    private static func encode(_ object: [String: Any]) -> [UInt8] {
        // Serializing strings, numbers, and dictionaries of them cannot fail.
        // swiftlint:disable:next force_try
        Array(try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    /// Splits `bytes` into consecutive fragments, cycling through `sizes`.
    /// Shrinking may empty `sizes`; the bytes then arrive as one fragment.
    private static func split(_ bytes: [UInt8], sizes: [Int]) -> [[UInt8]] {
        guard !sizes.isEmpty else { return [bytes] }
        var fragments: [[UInt8]] = []
        var start = 0
        var index = 0
        while start < bytes.count {
            let end = min(start + sizes[index % sizes.count], bytes.count)
            fragments.append(Array(bytes[start..<end]))
            start = end
            index += 1
        }
        return fragments
    }
}
