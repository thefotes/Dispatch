import DispatchCore
import Foundation

public protocol ConfigurationLoading: Sendable {
    func load() async throws -> DispatchConfiguration
}

public struct FileConfigurationLoader: ConfigurationLoading, Sendable {
    public let url: URL
    public let fallback: DispatchConfiguration
    public let writeFallbackWhenMissing: Bool

    public init(
        url: URL = Self.defaultURL,
        fallback: DispatchConfiguration = DispatchConfiguration(bindings: []),
        writeFallbackWhenMissing: Bool = true
    ) {
        self.url = url
        self.fallback = fallback
        self.writeFallbackWhenMissing = writeFallbackWhenMissing
    }

    public func load() async throws -> DispatchConfiguration {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(DispatchConfiguration.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            if writeFallbackWhenMissing {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                var data = try encoder.encode(fallback)
                data.append(0x0A)
                try data.write(to: url, options: .atomic)
            }
            return fallback
        }
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("dispatch", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }
}
public struct StaticConfigurationLoader: ConfigurationLoading, Sendable {
    public let configuration: DispatchConfiguration

    public init(_ configuration: DispatchConfiguration) {
        self.configuration = configuration
    }

    public func load() async throws -> DispatchConfiguration {
        configuration
    }
}
