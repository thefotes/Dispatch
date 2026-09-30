import DispatchCore
import Foundation

public actor CreatorMicroDriver: PadDevice {
    public private(set) var isConnected = false
    private let rpc: CreatorMicroRPCSession
    private let decoder: CreatorMicroVendorDecoder
    private var inputEnabled = false
    private let eventBroadcast = EventBroadcast<DispatchEvent>()
    private var notificationTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var lighting = CreatorMicroLightingReconciler()
    /// The latest lighting write; the next one waits for it.
    private var lightingWrite: Task<Void, any Error>?

    public init(
        transport: any CreatorMicroReportTransport,
        identity: DeviceIdentity
    ) {
        rpc = CreatorMicroRPCSession(transport: transport)
        decoder = CreatorMicroVendorDecoder(source: identity)
    }

    deinit {
        notificationTask?.cancel()
        eventBroadcast.finish()
    }

    nonisolated public func events() -> AsyncStream<DispatchEvent> {
        eventBroadcast.subscribe()
    }

    public func connect() async throws {
        connectionGeneration += 1
        let generation = connectionGeneration
        inputEnabled = false
        try await rpc.connect()
        // Subscribe after cancelling: cancelling the previous consumer ends
        // the stream it was iterating.
        notificationTask?.cancel()
        let notifications = await rpc.notifications()
        notificationTask = Task { [weak self, decoder] in
            var decoder = decoder
            for await notification in notifications {
                guard !Task.isCancelled else { return }
                do {
                    if let event = try decoder.decode(notification) {
                        await self?.publish(event)
                    } else if case let .notification(method, _) = notification, method != "v.oai.hid" {
                        Log.logger.error("Dropped unsupported notification method \(method, privacy: .private).")
                    }
                } catch {
                    Log.logger.error("Dropped undecodable input notification.")
                }
            }
            guard !Task.isCancelled else { return }
            await self?.transportLost(generation: generation)
        }
        isConnected = await rpc.isConnected
        if !isConnected { transportLost(generation: generation) }
    }

    public func disconnect() async {
        connectionGeneration += 1
        inputEnabled = false
        notificationTask?.cancel()
        notificationTask = nil
        await rpc.disconnect()
        isConnected = false
        eventBroadcast.finishCurrentSubscribers()
    }

    public func checkHealth() async throws {
        _ = try await deviceStatus()
    }

    public func apply(_ presentation: PadPresentation) async throws {
        try await serializeLighting { driver in
            try await driver.writeLighting(Self.lightingFrame(for: presentation))
        }
    }

    public func clearLighting() async throws {
        try await serializeLighting { driver in
            try await driver.writeClearedLighting()
        }
    }

    /// Runs one lighting write after every earlier one has finished. The
    /// actor alone does not serialize them, because a second write can start
    /// while the first awaits the pad. Overlapping writes interleave their
    /// HID reports, and the pad cannot read either. Each write also diffs
    /// against the last one applied, so it must see that write's outcome.
    /// Cancelling the caller cancels its write, as a direct RPC call would:
    /// stop() and device loss cancel the task writing lighting, and a write
    /// queued behind another does not start once cancelled.
    private func serializeLighting(
        _ write: @escaping @Sendable (isolated CreatorMicroDriver) async throws -> Void
    ) async throws {
        let previous = lightingWrite
        let current = Task {
            _ = await previous?.result
            try Task.checkCancellation()
            try await write(self)
        }
        lightingWrite = current
        try await withTaskCancellationHandler {
            try await current.value
        } onCancel: {
            current.cancel()
        }
    }

    private func writeLighting(_ desired: CreatorMicroLightingFrame) async throws {
        let update = lighting.prepare(desired)
        if let threadParameters = update.threadParameters {
            _ = try await rpc.call(method: "v.oai.thstatus", parameters: threadParameters)
        }
        if let zoneParameters = update.zoneParameters {
            _ = try await rpc.call(method: "v.oai.rgbcfg", parameters: zoneParameters)
        }
        lighting.recordSuccessfulApplication(desired)
    }

    private func writeClearedLighting() async throws {
        let update = CreatorMicroLightingEncoder.clearAll()
        if let parameters = update.threadParameters {
            _ = try await rpc.call(method: "v.oai.thstatus", parameters: parameters)
        }
        if let parameters = update.zoneParameters {
            _ = try await rpc.call(method: "v.oai.rgbcfg", parameters: parameters)
        }
        lighting.recordSuccessfulApplication(.cleared)
    }

    public func firmwareVersion() async throws -> JSONValue? {
        try await rpc.call(method: "sys.version")
    }

    public func deviceStatus() async throws -> JSONValue? {
        try await rpc.call(method: "device.status")
    }

    public func provisionKeymap(using storage: any CreatorMicroKeymapStorage) async throws {
        try await CreatorMicroKeymapProvisioner.provision(using: storage)
    }

    public func readKeymap() async throws -> Data {
        try await CreatorMicroRPCKeymapStorage(session: rpc).readKeymap()
    }

    public func listFiles() async throws -> JSONValue? {
        try await CreatorMicroRPCKeymapStorage(session: rpc).listFiles()
    }

    /// Provisioning always creates or preserves a backup and verifies a fresh
    /// device read before it returns success.
    public func provisionKeymap() async throws {
        try await CreatorMicroKeymapProvisioner.provision(
            using: CreatorMicroRPCKeymapStorage(session: rpc)
        )
    }

    public func keymapState() async throws -> CreatorMicroKeymapState {
        try await CreatorMicroKeymapProvisioner.state(using: CreatorMicroRPCKeymapStorage(session: rpc))
    }

    public func restoreKeymap() async throws {
        inputEnabled = false
        try await CreatorMicroKeymapProvisioner.restore(using: CreatorMicroRPCKeymapStorage(session: rpc))
    }

    public func setInputEnabled(_ enabled: Bool) {
        inputEnabled = enabled
    }

    public func prepareKeymap() async throws {
        try await provisionKeymap()
    }

    public static func lightingFrame(for presentation: PadPresentation) -> CreatorMicroLightingFrame {
        var threads: [Int: CreatorMicroLight] = [:]
        let wideKey = CreatorMicroGeometry.wideKeySwitches
        for (control, appearance) in presentation.controls {
            // The wide key's second switch is not a control of its own; key 10 lights both.
            guard case let .key(index) = control, CreatorMicroGeometry.lightThreads.contains(index),
                  index != wideKey.upperBound else {
                continue
            }
            let light = CreatorMicroLight(
                color: CreatorMicroColor(
                    red: appearance.color.red,
                    green: appearance.color.green,
                    blue: appearance.color.blue
                ),
                brightness: UInt8((appearance.brightness.clamped(to: 0...1) * 255).rounded()),
                effect: appearance.effect.creatorMicroEffect,
                speed: UInt8((appearance.speed.clamped(to: 0...1) * 255).rounded())
            )
            for thread in index == wideKey.lowerBound ? Array(wideKey) : [index] {
                threads[thread] = light
            }
        }
        let ambient = presentation.ambient.map {
            CreatorMicroLight(
                color: CreatorMicroColor(red: $0.color.red, green: $0.color.green, blue: $0.color.blue),
                brightness: UInt8(($0.brightness.clamped(to: 0...1) * 255).rounded()),
                effect: $0.effect.creatorMicroEffect,
                speed: UInt8(($0.speed.clamped(to: 0...1) * 255).rounded())
            )
        } ?? .off
        return CreatorMicroLightingFrame(threads: threads, keyZone: .off, ambientZone: ambient)
    }

    private func publish(_ event: DispatchEvent) {
        if inputEnabled { eventBroadcast.yield(event) }
    }

    private func transportLost(generation: Int) {
        guard generation == connectionGeneration else { return }
        isConnected = false
        inputEnabled = false
        eventBroadcast.finishCurrentSubscribers()
    }
}

private extension PresentationEffect {
    var creatorMicroEffect: CreatorMicroLightingEffect {
        switch self {
        case .off: .off
        case .solid: .solid
        case .snake: .snake
        case .rainbow: .rainbow
        case .breath: .breath
        case .gradient: .gradient
        case .shallowBreath: .shallowBreath
        }
    }
}

private extension Double {
    /// NaN clamps to the lower bound, so converting the result to an integer cannot trap.
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard !isNaN else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
