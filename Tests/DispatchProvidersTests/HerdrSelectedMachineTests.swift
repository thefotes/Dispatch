import DispatchCore
import DispatchProviders
import Foundation
import XCTest

final class HerdrSelectedMachineTests: XCTestCase {
    private let studio = HerdrSavedMachine(id: "profile-1", label: "Studio", target: "studio", session: "default")

    func testSelectionIsLocalWithoutAClientSelectionFile() throws {
        let selection = HerdrClientSelection(directory: try stateDirectory(selected: nil, writeSelection: false))

        XCTAssertNil(try selection.selectedMachine())
    }

    func testSelectionNamesTheSavedMachineHerdrShows() throws {
        let selection = HerdrClientSelection(directory: try stateDirectory(selected: .string("profile-1")))

        XCTAssertEqual(try selection.selectedMachine(), studio)
        let local = HerdrClientSelection(directory: try stateDirectory(selected: .null))
        XCTAssertNil(try local.selectedMachine())
    }

    func testAnUnreadableSelectionFailsInsteadOfGuessingLocal() throws {
        let directory = try stateDirectory(selected: nil, writeSelection: false)
        try Data(#"{"version":1,"selected_pro"#.utf8)
            .write(to: directory.appendingPathComponent("endpoint-selection.json"))

        XCTAssertThrowsError(try HerdrClientSelection(directory: directory).selectedMachine()) { error in
            XCTAssertEqual(
                error as? HerdrIntegrationError,
                .unavailableState("Could not read which machine Herdr shows.")
            )
        }
    }

    func testUnreadableSavedMachinesFailInPlainLanguage() throws {
        let directory = try stateDirectory(selected: .string("profile-1"))
        try Data(#"{"version":1,"ss"#.utf8).write(to: directory.appendingPathComponent("endpoints.json"))

        XCTAssertThrowsError(try HerdrClientSelection(directory: directory).selectedMachine()) { error in
            XCTAssertEqual(
                error as? HerdrIntegrationError,
                .unavailableState("Could not read the machines saved in Herdr.")
            )
        }
    }

    func testRequestsGoToTheServerOfTheMachineHerdrShows() async throws {
        let localPath = "/tmp/dispatch-local-\(UUID().uuidString.prefix(8)).sock"
        let remotePath = "/tmp/dispatch-remote-\(UUID().uuidString.prefix(8)).sock"
        let localServer = try server(path: localPath, name: "local")
        let remoteServer = try server(path: remotePath, name: "remote")
        defer {
            localServer.stop()
            remoteServer.stop()
        }
        let directory = try stateDirectory(selected: .null)
        let tunnels = FixedTunnels(path: remotePath)
        let connection = HerdrSelectedMachineConnection(
            local: HerdrUnixSocketClient(configuration: .init(socketPath: localPath, timeout: .seconds(1))),
            selection: HerdrClientSelection(directory: directory),
            tunnels: tunnels
        )

        let fromLocal = try await connection.request(["method": .string("session.snapshot")])
        try select(.string("profile-1"), in: directory)
        let fromRemote = try await connection.request(["method": .string("session.snapshot")])

        XCTAssertEqual(fromLocal["result"], .string("local"))
        XCTAssertEqual(fromRemote["result"], .string("remote"))
        let opened = await tunnels.opened
        XCTAssertEqual(opened, [studio])
    }

    private func server(path: String, name: String) throws -> OneShotUnixServer {
        do {
            return try OneShotUnixServer(path: path) { ["id": $0["id"] ?? .null, "result": .string(name)] }
        } catch let error as POSIXError where error.code == .EPERM {
            throw XCTSkip("The test host sandbox does not permit binding a Unix-domain socket.")
        }
    }

    private func stateDirectory(selected: JSONValue?, writeSelection: Bool = true) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-herdr-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let endpoints: JSONValue = .object([
            "version": .integer(1),
            "ssh": .array([.object([
                "id": .string("profile-1"),
                "label": .string("Studio"),
                "target": .string("studio"),
                "session": .string("default"),
                "enabled": .boolean(true)
            ])])
        ])
        try JSONEncoder().encode(endpoints).write(to: directory.appendingPathComponent("endpoints.json"))
        if writeSelection, let selected {
            try select(selected, in: directory)
        }
        return directory
    }

    private func select(_ profile: JSONValue, in directory: URL) throws {
        let selection: JSONValue = .object(["version": .integer(1), "selected_profile": profile])
        try JSONEncoder().encode(selection).write(to: directory.appendingPathComponent("endpoint-selection.json"))
    }
}

private actor FixedTunnels: HerdrTunnelOpening {
    private let path: String
    private(set) var opened: [HerdrSavedMachine] = []

    init(path: String) {
        self.path = path
    }

    func socketPath(for machine: HerdrSavedMachine) -> String {
        opened.append(machine)
        return path
    }
}
