@testable import DispatchApp
import DispatchCore
import DispatchMacOS
import DispatchProviders
import DispatchRuntime
import Foundation
import XCTest

final class ExampleConfigurationTests: XCTestCase {
    func testEveryExampleLoadsAndCompilesAgainstInstalledActions() async throws {
        let catalog = try ActionCatalog(
            definitions: HerdrActions.definitions + MacOSActions.definitions
        )
        let examples = try FileManager.default
            .contentsOfDirectory(at: examplesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        XCTAssertGreaterThanOrEqual(examples.count, 1)

        for example in examples {
            let loader = ValidatingConfigurationLoader(file: FileConfigurationLoader(
                url: example,
                writeFallbackWhenMissing: false
            ))
            let configuration = try await loader.load()
            _ = try CompiledBindings.compile(configuration, catalog: catalog)

            for binding in configuration.bindings {
                for action in binding.actions {
                    let invocation = try catalog.makeInvocation(
                        id: action.id,
                        arguments: action.arguments
                    )
                    XCTAssertNoThrow(
                        try decode(invocation),
                        "\(example.lastPathComponent): \(action.id.rawValue) does not decode"
                    )
                }
            }
        }
    }

    private func decode(_ invocation: ActionInvocation) throws {
        if invocation.id.rawValue.hasPrefix("herdr.") {
            _ = try HerdrActions.decode(invocation)
        } else {
            _ = try MacOSActions.decode(invocation)
        }
    }

    private var examplesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("examples", isDirectory: true)
    }
}
