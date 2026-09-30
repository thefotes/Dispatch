import DispatchCore
import DispatchCreatorMicro
import Foundation

@main
struct DispatchProbe {
    static func main() async {
        let command = CommandLine.arguments.dropFirst().first ?? "help"
        guard command != "help", command != "--help", command != "-h" else {
            printUsage()
            return
        }
        if command == "fs-write-test" || command == "rpc" {
            do {
                if command == "rpc" {
                    try await runRPC()
                } else {
                    try await runFsWriteTest()
                }
            } catch {
                FileHandle.standardError.write(Data("dispatch-probe: \(error)\n".utf8))
                Foundation.exit(EXIT_FAILURE)
            }
            return
        }

        let transport = IOHIDCreatorMicroTransport()
        let driver = CreatorMicroDriver(
            transport: transport,
            identity: DeviceIdentity(rawValue: "creator-micro-2")
        )

        do {
            try await driver.connect()
            defer { Task { await driver.disconnect() } }

            try await run(command, on: driver)
        } catch {
            FileHandle.standardError.write(Data("dispatch-probe: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    // The probe deliberately keeps the supported command list in one switch.
    private static func run(_ command: String, on driver: CreatorMicroDriver) async throws {
        switch command {
        case "version":
            try printJSON(await driver.firmwareVersion())
        case "status":
            try printJSON(await driver.deviceStatus())
        case "fs-list":
            try printJSON(await driver.listFiles())
        case "keymap-read":
            let data = try await driver.readKeymap()
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        case "keymap-prepare":
            guard CommandLine.arguments.dropFirst(2).contains("--write") else {
                throw ProbeError.writeFlagRequired
            }
            try await driver.prepareKeymap()
            print("Keymap is prepared and verified; an original backup was preserved.")
        case "keymap-restore":
            guard CommandLine.arguments.dropFirst(2).contains("--write") else {
                throw ProbeError.writeFlagRequired
            }
            try await driver.restoreKeymap()
            print("The original keymap was restored and verified. The backup remains on the pad.")
        case "watch":
            try await watch(driver)
        case "light-test":
            let presentation = PadPresentation(
                controls: [
                    .key(0): ControlAppearance(
                        color: RGBColor(red: 0, green: 120, blue: 255)
                    )
                ]
            )
            try await driver.apply(presentation)
            try await Task.sleep(for: .seconds(1))
            try await driver.clearLighting()
        case "lights-off":
            try await driver.clearLighting()
        default:
            throw ProbeError.unknownCommand(command)
        }
    }

    /// Prints one line per event with the gap since the previous one, so a
    /// single physical press that arrives as several events stands out.
    private static func watch(_ driver: CreatorMicroDriver) async throws {
        let events = driver.events()
        await driver.setInputEnabled(true)
        print("Watching the pad. Press controls; Ctrl+C to stop.")
        fflush(stdout)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        var previous: Date?
        for await event in events {
            let gap = previous.map { String(format: "+%.0f ms", event.timestamp.timeIntervalSince($0) * 1000) } ?? ""
            print("\(formatter.string(from: event.timestamp))  \(event.control) \(event.gesture)  \(gap)")
            fflush(stdout)
            previous = event.timestamp
        }
        print("The pad event stream ended.")
    }

    static let scratchFile = "dispatch-probe-test.json"
    static let scratchContents = #"{"ok":true}"#

    /// Sends `fs.write` on a raw session, bypassing keymap storage, to a new
    /// scratch file, then reads it back. It never names `keymap.json`.
    private static func runFsWriteTest() async throws {
        guard CommandLine.arguments.dropFirst(2).contains("--write") else {
            throw ProbeError.writeFlagRequired
        }
        let session = CreatorMicroRPCSession(transport: IOHIDCreatorMicroTransport())
        try await session.connect()
        defer { Task { await session.disconnect() } }

        let writeParameters = JSONValue.object([
            "file": .string(scratchFile),
            "data": .string(scratchContents)
        ])
        print("fs.write request params:")
        try printJSON(writeParameters)
        do {
            let response = try await session.call(method: "fs.write", parameters: writeParameters, timeout: .seconds(5))
            print("fs.write response:")
            try printJSON(response)
        } catch {
            print("fs.write failed: \(error)")
            throw error
        }

        let readParameters = JSONValue.object(["file": .string(scratchFile)])
        do {
            let response = try await session.call(method: "fs.read", parameters: readParameters)
            print("fs.read response:")
            try printJSON(response)
            var readBack: String?
            if case let .object(object)? = response, case let .string(data)? = object["data"] { readBack = data }
            print(readBack == scratchContents ? "ROUND-TRIP OK" : "ROUND-TRIP MISMATCH: expected \(scratchContents)")
        } catch {
            print("fs.read failed: \(error)")
            throw error
        }
    }

    /// Method name fragments that suggest a call changes the pad's files,
    /// settings, or firmware. Such calls need `--write`.
    static let changingFragments = ["write", "delete", "remove", "format", "reset", "update", "ota",
                                    "reboot", "flash", "erase", "save", "set"]

    /// Sends one call on a raw session and prints its response, for exploring
    /// the firmware. `--hold N` keeps the session open N seconds afterwards,
    /// so a lighting change can be watched before the probe disconnects.
    private static func runRPC() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst(2))
        let allowChanges = arguments.contains("--write")
        arguments.removeAll { $0 == "--write" }
        var hold = 0.0
        if let index = arguments.firstIndex(of: "--hold") {
            guard index + 1 < arguments.count, let seconds = Double(arguments[index + 1]) else {
                throw ProbeError.invalidArguments("--hold needs a number of seconds")
            }
            hold = seconds
            arguments.removeSubrange(index...index + 1)
        }
        guard let method = arguments.first, arguments.count <= 2 else {
            throw ProbeError.invalidArguments("usage: rpc <method> [params-json] [--hold seconds] [--write]")
        }
        let lowered = method.lowercased()
        if !allowChanges, changingFragments.contains(where: lowered.contains) {
            throw ProbeError.writeFlagRequired
        }
        let parameters = try arguments.dropFirst().first.map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
        let session = CreatorMicroRPCSession(transport: IOHIDCreatorMicroTransport())
        try await session.connect()
        defer { Task { await session.disconnect() } }
        do {
            let response = try await session.call(method: method, parameters: parameters, timeout: .seconds(5))
            print("\(method) response:")
            try printJSON(response)
        } catch {
            print("\(method) failed: \(error)")
        }
        if hold > 0 {
            try await Task.sleep(for: .seconds(hold))
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func printUsage() {
        print(
            """
            Usage: dispatch-probe <command>

              version      Print the pad firmware version
              status       Print device status
              fs-list      Print the device file listing
              keymap-read  Print the current keymap without changing it
              fs-write-test --write
                           Write and read back \(scratchFile); never keymap.json
              keymap-prepare --write
                           Back up, prepare, and verify the active keymap
              keymap-restore --write
                           Restore and verify the on-device Dispatch backup
              watch        Print each decoded event with the gap since the last one
              light-test   Light one key briefly, then clear the pad
              lights-off   Clear per-key and zone lighting
              rpc <method> [params-json] [--hold seconds] [--write]
                           Send one raw call and print the response; methods
                           that look like they change the pad need --write
            """
        )
    }
}

private enum ProbeError: Error {
    case unknownCommand(String)
    case writeFlagRequired
    case invalidArguments(String)
}
