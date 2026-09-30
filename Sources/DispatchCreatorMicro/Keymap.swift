import DispatchCore
import Foundation

public struct CreatorMicroKeymapPlan: Sendable, Equatable {
    public let backup: Data
    public let desired: Data

    public init(backup: Data, desired: Data) {
        self.backup = backup
        self.desired = desired
    }

    public func verifies(readBack: Data) -> Bool {
        guard
            let expected = try? JSONDecoder().decode(JSONValue.self, from: desired),
            let actual = try? JSONDecoder().decode(JSONValue.self, from: readBack)
        else { return false }
        return expected == actual
    }
}

public enum CreatorMicroKeymapState: Sendable, Equatable {
    case ready
    case changed
}

/// Plans the smallest edit that makes the active profile's first layer emit
/// `KV_OAI_AGnn` codes. Every other value in the document is preserved.
///
/// Observed `keymap.json` shape (firmware 0.6.2):
/// `activeProfileId`, `profiles[].id`, `profiles[].layers[].layout` with
/// `keymap` rows of widths `[2, 4, 4, 3]`, `encoders` as `[clockwise,
/// counterclockwise, press]`, and `joystick.sectors` of `{k, a1, a2}` whose
/// angles are turns clockwise from the right.
public enum CreatorMicroKeymapPlanner {
    public static let keyCodes = (0...12).map { String(format: "KV_OAI_AG%02d", $0) }
    public static let dialCodes = ["KV_OAI_AG13", "KV_OAI_AG14"]
    public static let joystickCodes = (15...18).map { String(format: "KV_OAI_AG%02d", $0) }

    private static let sectorCenterTolerance = 0.01

    public static func plan(original: Data) throws -> CreatorMicroKeymapPlan {
        guard var root = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw CreatorMicroError.invalidKeymap("Root is not an object")
        }
        let activeProfile = max(0, root["activeProfileId"] as? Int ?? 0)
        guard
            var profiles = root["profiles"] as? [[String: Any]],
            let profileIndex = profiles.firstIndex(where: { $0["id"] as? Int == activeProfile })
        else {
            throw CreatorMicroError.invalidKeymap("Active profile \(activeProfile) does not exist")
        }
        var profile = profiles[profileIndex]
        guard var layers = profile["layers"] as? [[String: Any]], !layers.isEmpty,
              var layout = layers[0]["layout"] as? [String: Any] else {
            throw CreatorMicroError.invalidKeymap("Active profile has no first-layer layout")
        }

        layout["keymap"] = try plannedKeyRows(layout["keymap"])
        layout["encoders"] = try plannedEncoders(layout["encoders"])
        layout["joystick"] = try plannedJoystick(layout["joystick"])

        layers[0]["layout"] = layout
        profile["layers"] = layers
        profiles[profileIndex] = profile
        root["profiles"] = profiles
        let desired: Data
        do {
            desired = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw CreatorMicroError.invalidKeymap(error.localizedDescription)
        }
        return CreatorMicroKeymapPlan(backup: original, desired: desired)
    }

    /// A partially edited Dispatch layer must never replace the user's backup.
    public static func containsDispatchCodes(_ data: Data) throws -> Bool {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profiles"] as? [[String: Any]],
              let profile = profiles.first(where: { $0["id"] as? Int == max(0, root["activeProfileId"] as? Int ?? 0) }),
              let layers = profile["layers"] as? [[String: Any]],
              let layout = layers.first?["layout"] else {
            throw CreatorMicroError.invalidKeymap("Active profile has no first-layer layout")
        }
        func containsCode(_ value: Any) -> Bool {
            if let string = value as? String { return string.hasPrefix("KV_OAI_AG") }
            if let array = value as? [Any] { return array.contains(where: containsCode) }
            if let object = value as? [String: Any] { return object.values.contains(where: containsCode) }
            return false
        }
        return containsCode(layout)
    }

    private static func plannedKeyRows(_ value: Any?) throws -> [[Any]] {
        guard var rows = value as? [[Any]], rows.map(\.count) == CreatorMicroGeometry.rowWidths else {
            throw CreatorMicroError.invalidKeymap("First-layer keymap rows are not \(CreatorMicroGeometry.rowWidths)")
        }
        var codes = keyCodes.makeIterator()
        for row in rows.indices {
            for column in rows[row].indices {
                rows[row][column] = codes.next()!
            }
        }
        return rows
    }

    private static func plannedEncoders(_ value: Any?) throws -> [[Any]] {
        guard var encoders = value as? [[Any]], let first = encoders.first, first.count >= dialCodes.count else {
            throw CreatorMicroError.invalidKeymap("First layer has no dial encoder")
        }
        encoders[0][0] = dialCodes[0]
        encoders[0][1] = dialCodes[1]
        return encoders
    }

    private static func plannedJoystick(_ value: Any?) throws -> [String: Any] {
        guard var joystick = value as? [String: Any], var sectors = joystick["sectors"] as? [[String: Any]] else {
            throw CreatorMicroError.invalidKeymap("First layer has no joystick sectors")
        }
        for (code, center) in zip(joystickCodes, CreatorMicroGeometry.joystickSectorCenters) {
            guard let index = sectors.firstIndex(where: { sectorCenter($0).map { isNear($0, center) } == true }) else {
                throw CreatorMicroError.invalidKeymap("First layer has no joystick sector centered at \(center) turns")
            }
            sectors[index]["k"] = code
        }
        joystick["sectors"] = sectors
        return joystick
    }

    /// Sector bounds may wrap across zero, for example from 0.9375 to 0.0625.
    private static func sectorCenter(_ sector: [String: Any]) -> Double? {
        guard let start = (sector["a1"] as? NSNumber)?.doubleValue,
              let end = (sector["a2"] as? NSNumber)?.doubleValue else { return nil }
        let span = end >= start ? end - start : end + 1 - start
        return (start + span / 2).truncatingRemainder(dividingBy: 1)
    }

    private static func isNear(_ angle: Double, _ target: Double) -> Bool {
        let distance = abs(angle - target).truncatingRemainder(dividingBy: 1)
        return min(distance, 1 - distance) <= sectorCenterTolerance
    }
}

public protocol CreatorMicroKeymapStorage: Sendable {
    func readKeymap() async throws -> Data
    func readBackup() async throws -> Data
    func writeBackup(_ data: Data) async throws
    func writeKeymap(_ data: Data) async throws
    func restoreKeymap(_ data: Data) async throws
}

public enum CreatorMicroKeymapProvisioner {
    public static func state(using storage: any CreatorMicroKeymapStorage) async throws -> CreatorMicroKeymapState {
        let current = try await storage.readKeymap()
        return try CreatorMicroKeymapPlanner.plan(original: current).verifies(readBack: current) ? .ready : .changed
    }

    public static func provision(using storage: any CreatorMicroKeymapStorage) async throws {
        let original = try await storage.readKeymap()
        let plan = try CreatorMicroKeymapPlanner.plan(original: original)
        guard !plan.verifies(readBack: original) else { return }
        if try !CreatorMicroKeymapPlanner.containsDispatchCodes(original) {
            try await storage.writeBackup(plan.backup)
            let saved = try await storage.readBackup()
            guard saved == plan.backup else { throw CreatorMicroError.verificationFailed }
        } else {
            // A partial Dispatch layout is not a safe backup. Require an
            // existing original before changing the keymap further.
            let saved = try await storage.readBackup()
            guard try !CreatorMicroKeymapPlanner.containsDispatchCodes(saved) else {
                throw CreatorMicroError.invalidKeymap("The saved backup contains Dispatch codes")
            }
        }
        try await storage.writeKeymap(plan.desired)
        let readBack = try await storage.readKeymap()
        guard plan.verifies(readBack: readBack) else { throw CreatorMicroError.verificationFailed }
    }

    public static func restore(using storage: any CreatorMicroKeymapStorage) async throws {
        let backup = try await storage.readBackup()
        guard try !CreatorMicroKeymapPlanner.containsDispatchCodes(backup) else {
            throw CreatorMicroError.invalidKeymap("The saved backup contains Dispatch codes")
        }
        try await storage.restoreKeymap(backup)
        let readBack = try await storage.readKeymap()
        guard CreatorMicroKeymapPlan(backup: backup, desired: backup).verifies(readBack: readBack) else {
            throw CreatorMicroError.verificationFailed
        }
    }
}

/// Device-backed keymap storage. Writes are refused until the original has
/// been backed up (or an existing backup has been observed via `fs.list`).
public actor CreatorMicroRPCKeymapStorage: CreatorMicroKeymapStorage {
    public static let keymapPath = "keymap.json"
    public static let backupPath = "keymap.dispatch-backup.json"

    private let session: CreatorMicroRPCSession
    private var backupEstablished = false

    public init(session: CreatorMicroRPCSession) {
        self.session = session
    }

    public func readKeymap() async throws -> Data {
        try await readFile(path: Self.keymapPath)
    }

    public func readBackup() async throws -> Data {
        let listing = try await listFiles()
        guard listing?.contains(string: Self.backupPath) == true else {
            throw CreatorMicroError.invalidKeymap("No Dispatch backup exists on the pad")
        }
        let backup = try await readFile(path: Self.backupPath)
        backupEstablished = true
        return backup
    }

    private func readFile(path: String) async throws -> Data {
        let response = try await session.call(
            method: "fs.read",
            parameters: .object(["file": .string(path)])
        )
        guard
            let dataString = response?.objectValue?["data"]?.stringValue,
            let data = dataString.data(using: .utf8)
        else {
            throw CreatorMicroError.invalidKeymap("fs.read returned no string data")
        }
        return data
    }

    /// The device's file listing, returned without interpretation.
    public func listFiles() async throws -> JSONValue? {
        try await session.call(
            method: "fs.list",
            parameters: .object(["checksum": .boolean(false), "rec": .boolean(true)])
        )
    }

    public func writeBackup(_ data: Data) async throws {
        try await writeFile(path: Self.backupPath, data: data)
        backupEstablished = true
    }

    public func restoreKeymap(_ data: Data) async throws {
        try await writeKeymap(data)
    }

    public func writeKeymap(_ data: Data) async throws {
        guard backupEstablished else {
            throw CreatorMicroError.invalidKeymap("Refusing to write before backup")
        }
        try await writeFile(path: Self.keymapPath, data: data)
    }

    /// Like `fs.read`, `fs.write` names its file with `file`; `data` carries
    /// the contents as a string (observed on firmware 0.6.2).
    private func writeFile(path: String, data: Data) async throws {
        guard let contents = String(data: data, encoding: .utf8) else {
            throw CreatorMicroError.invalidUTF8
        }
        _ = try await session.call(
            method: "fs.write",
            parameters: .object(["file": .string(path), "data": .string(contents)])
        )
    }
}

private extension JSONValue {
    func contains(string searched: String) -> Bool {
        switch self {
        case let .string(value): return value == searched
        case let .array(values): return values.contains { $0.contains(string: searched) }
        case let .object(values): return values.values.contains { $0.contains(string: searched) }
        default: return false
        }
    }
}
