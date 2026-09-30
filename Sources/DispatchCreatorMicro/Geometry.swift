import DispatchCore
import Foundation

public struct CreatorMicroKeyPosition: Sendable, Hashable, Codable {
    public let matrixIndex: Int
    public let row: Int
    public let column: Int
    public let readingOrderIndex: Int
    public let isWide: Bool

    public init(matrixIndex: Int, row: Int, column: Int, readingOrderIndex: Int, isWide: Bool) {
        self.matrixIndex = matrixIndex
        self.row = row
        self.column = column
        self.readingOrderIndex = readingOrderIndex
        self.isWide = isWide
    }
}

public enum CreatorMicroGeometry {
    public static let rowWidths = [2, 4, 4, 3]
    public static let readingOrder = Array(0...12)
    public static let initialAgentSlots = Array(readingOrder.prefix(6))
    /// One wide keycap spans these two switches and their two lights. It is
    /// reported and lit as the single control `key(10)`.
    public static let wideKeySwitches = 10...11
    /// Per-key light threads, one per switch. Threads 0–11 light keys 0–9 and
    /// the wide key's halves; thread 12 and threads 13–19 lit nothing
    /// (observed 2026-09-24, firmware 0.6.2).
    public static let lightThreads = 0...12
    /// The key indexes Dispatch reports: every switch, except that the wide
    /// key's second switch is part of `key(10)`.
    public static let keys = readingOrder.filter { $0 != wideKeySwitches.upperBound }
    /// The keys with a light. Key 12's thread lit nothing.
    public static let litKeys = keys.filter { $0 != 12 }
    /// Directions for `AG15` through `AG18`. The firmware measures sector
    /// angles in turns, clockwise from the right, so `AG15` (0.25) is down.
    public static let joystickDirections: [Direction] = [.down, .left, .up, .right]
    public static let joystickSectorCenters: [Double] = [0.25, 0.5, 0.75, 0]

    public static let positions: [CreatorMicroKeyPosition] = {
        var positions: [CreatorMicroKeyPosition] = []
        var matrixIndex = 0
        for (row, width) in rowWidths.enumerated() {
            for column in 0..<width {
                positions.append(CreatorMicroKeyPosition(
                    matrixIndex: matrixIndex,
                    row: row,
                    column: column,
                    readingOrderIndex: readingOrder.firstIndex(of: matrixIndex)!,
                    isWide: wideKeySwitches.contains(matrixIndex)
                ))
                matrixIndex += 1
            }
        }
        return positions
    }()

    public static func position(forMatrixIndex index: Int) -> CreatorMicroKeyPosition? {
        positions.first { $0.matrixIndex == index }
    }
}
