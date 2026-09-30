import DispatchCore
import Foundation
import IOKit.hid

/// The useful substitution boundary below the vendor driver. Production owns
/// HID I/O; tests provide deterministic reports without touching the computer.
public protocol CreatorMicroReportTransport: Sendable {
    func connect() async throws
    func disconnect() async
    func send(report: [UInt8]) async throws
    func incomingReports() async -> AsyncStream<[UInt8]>
}

public actor IOHIDCreatorMicroTransport: CreatorMicroReportTransport {
    public static let vendorID = 0x303A
    public static let usagePage = 0xFF00
    public static let usage = 0x01

    /// The vendor collection shares its interface with the keyboard collection,
    /// which IOKit reports as the primary usage. Match any usage pair instead.
    public static let deviceMatching: [String: Int] = [
        kIOHIDVendorIDKey: vendorID,
        kIOHIDDeviceUsagePageKey: usagePage,
        kIOHIDDeviceUsageKey: usage
    ]

    private var stream: AsyncStream<[UInt8]>
    private var continuation: AsyncStream<[UInt8]>.Continuation
    private let bridge: IOHIDBridge

    public init() {
        (stream, continuation) = AsyncStream.makeStream()
        bridge = IOHIDBridge()
    }

    public func connect() async throws {
        // Opening the vendor interface needs the process-wide Input Monitoring
        // grant; without it IOHIDDeviceOpen fails with 0xE00002E2. Ask here so
        // the prompt appears even before the panel ever shows a button.
        _ = await IOHIDInputMonitoringPermissionRequester().requestIfNeeded()
        (stream, continuation) = AsyncStream.makeStream()
        try bridge.connect(continuation: continuation)
    }

    public func disconnect() async {
        bridge.disconnect()
        continuation.finish()
    }

    public func send(report: [UInt8]) async throws {
        guard report.count == CreatorMicroHIDReport.byteCount else {
            throw CreatorMicroError.invalidReportLength(report.count)
        }
        try bridge.send(report: report)
    }

    public func incomingReports() async -> AsyncStream<[UInt8]> { stream }
}

/// Callback ownership is concentrated here; the public actor serializes the
/// lifecycle and writes. IOHID delivers input on this bridge's private queue.
private final class IOHIDBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dispatch.creator-micro.hid")
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputBuffer = [UInt8](repeating: 0, count: CreatorMicroHIDReport.byteCount)
    private var continuation: AsyncStream<[UInt8]>.Continuation?

    func connect(continuation: AsyncStream<[UInt8]>.Continuation) throws {
        try queue.sync {
            guard manager == nil else { throw CreatorMicroError.alreadyConnected }
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(
                manager,
                IOHIDCreatorMicroTransport.deviceMatching as CFDictionary
            )
            let managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            guard managerResult == kIOReturnSuccess else {
                throw CreatorMicroError.ioKit(managerResult)
            }
            guard
                let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
                let device = devices.first
            else {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                throw CreatorMicroError.ioKit(kIOReturnNoDevice)
            }
            let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openResult == kIOReturnSuccess else {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                throw CreatorMicroError.ioKit(openResult)
            }

            self.manager = manager
            self.device = device
            self.continuation = continuation
            Log.logger.info("Connected to the pad over HID.")
            IOHIDDeviceSetDispatchQueue(device, queue)
            inputBuffer.withUnsafeMutableBytes { rawBuffer in
            IOHIDDeviceRegisterInputReportCallback(
                    device,
                    rawBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    rawBuffer.count,
                    Self.inputCallback,
                    Unmanaged.passUnretained(self).toOpaque()
                )
            }
            IOHIDDeviceRegisterRemovalCallback(
                device,
                Self.removalCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
            IOHIDDeviceActivate(device)
        }
    }

    func disconnect() {
        queue.sync {
            guard let device else { return }
            Log.logger.info("Disconnecting from the pad.")
            IOHIDDeviceCancel(device)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
            self.device = nil
            manager = nil
            continuation = nil
        }
    }

    func send(report: [UInt8]) throws {
        try queue.sync {
            guard let device else { throw CreatorMicroError.disconnected }
        let result = report.withUnsafeBytes { buffer in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(CreatorMicroHIDReport.reportIdentifier),
                buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                buffer.count
            )
        }
        guard result == kIOReturnSuccess else {
            let reason = String(cString: mach_error_string(result))
            Log.logger.error("Writing a report failed: \(reason, privacy: .public).")
            // A missing Input Monitoring grant produces the same code, so blame
            // Secure Input only while the grant is present.
            if result == kIOReturnNotPermitted,
               IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
               let owner = SecureInput.owner() {
                throw CreatorMicroError.secureInputHeld(owner)
            }
            throw CreatorMicroError.ioKit(result)
        }
        }
    }

    private static let inputCallback: IOHIDReportCallback = { context, result, _, _, _, report, reportLength in
        guard result == kIOReturnSuccess, let context else { return }
        let bridge = Unmanaged<IOHIDBridge>.fromOpaque(context).takeUnretainedValue()
        bridge.continuation?.yield(Array(UnsafeBufferPointer(start: report, count: reportLength)))
    }

    private static let removalCallback: IOHIDCallback = { context, _, _ in
        guard let context else { return }
        let bridge = Unmanaged<IOHIDBridge>.fromOpaque(context).takeUnretainedValue()
        bridge.handleRemoval()
    }

    private func handleRemoval() {
        Log.logger.info("The pad was removed.")
        continuation?.finish()
        continuation = nil
        device = nil
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        manager = nil
    }
}

public actor CreatorMicroRPCSession {
    public private(set) var isConnected = false
    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<JSONValue?, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private let transport: any CreatorMicroReportTransport
    private var allocator = RequestIDAllocator()
    private var assembler = JSONMessageAssembler()
    private var pending: [Int: Pending] = [:]
    private var reportTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private let notificationBroadcast = EventBroadcast<CreatorMicroRPCMessage>()

    public init(transport: any CreatorMicroReportTransport) {
        self.transport = transport
    }

    deinit {
        reportTask?.cancel()
        notificationBroadcast.finish()
    }

    /// Returns a new, independent subscription; see `EventBroadcast`.
    public func notifications() -> AsyncStream<CreatorMicroRPCMessage> {
        notificationBroadcast.subscribe()
    }

    public func connect() async throws {
        connectionGeneration += 1
        let generation = connectionGeneration
        try await transport.connect()
        isConnected = true
        Log.logger.info("The pad RPC session opened.")
        let reports = await transport.incomingReports()
        reportTask?.cancel()
        reportTask = Task { [weak self] in
            for await report in reports {
                guard !Task.isCancelled else { return }
                await self?.receiveFromTransport(report: report, generation: generation)
            }
            guard !Task.isCancelled else { return }
            await self?.transportEnded(generation: generation)
        }
    }

    public func disconnect() async {
        connectionGeneration += 1
        reportTask?.cancel()
        reportTask = nil
        await transport.disconnect()
        isConnected = false
        assembler.reset()
        Log.logger.info("The pad RPC session closed.")
        failAll(with: CreatorMicroError.disconnected)
        notificationBroadcast.finishCurrentSubscribers()
    }

    public func call(
        method: String,
        parameters: JSONValue? = nil,
        timeout: Duration = .seconds(2)
    ) async throws -> JSONValue? {
        guard isConnected else { throw CreatorMicroError.disconnected }
        let id = try allocator.allocate()
        let call = CreatorMicroRPCCall(id: id, method: method, parameters: parameters)
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(call)
        } catch {
            allocator.release(id)
            throw CreatorMicroError.invalidJSON(error.localizedDescription)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.timeOut(id: id)
                }
                pending[id] = Pending(
                    method: method,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task { [weak self] in
                    do {
                        for report in try CreatorMicroHIDReport.fragment(encoded) {
                            try await self?.transport.send(report: report.bytes)
                        }
                    } catch {
                        await self?.fail(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.fail(id: id, error: CancellationError()) }
        }
    }

    /// Public for deterministic transports and diagnostics. Invalid reports are
    /// dropped without poisoning the session; callers can continue feeding it.
    public func receive(report bytes: [UInt8]) {
        let report: CreatorMicroHIDReport
        do {
            report = try CreatorMicroHIDReport(bytes: bytes)
        } catch {
            Log.logger.error("Dropped malformed HID report envelope.")
            return
        }
        guard report.channel == 2 else { return }

        // Process one byte at a time so an invalid byte cannot discard a
        // valid object later in the same HID report.
        var loggedOversize = false
        var loggedInvalidUTF8 = false
        var loggedFraming = false
        for byte in report.payload {
            do {
                for data in try assembler.append([byte]) {
                    do {
                        route(try CreatorMicroRPCMessage.decode(data))
                    } catch {
                        Log.logger.error("Dropped undecodable RPC envelope.")
                    }
                }
            } catch CreatorMicroError.messageTooLarge {
                if !loggedOversize {
                    Log.logger.error("Dropped oversized RPC message.")
                    loggedOversize = true
                }
            } catch CreatorMicroError.invalidUTF8 {
                if !loggedInvalidUTF8 {
                    Log.logger.error("Dropped RPC message with invalid UTF-8.")
                    loggedInvalidUTF8 = true
                }
            } catch {
                if !loggedFraming {
                    Log.logger.error("Dropped malformed RPC message framing.")
                    loggedFraming = true
                }
            }
        }
    }

    private func receiveFromTransport(report: [UInt8], generation: Int) {
        guard generation == connectionGeneration, isConnected else { return }
        receive(report: report)
    }

    private func route(_ message: CreatorMicroRPCMessage) {
        switch message {
        case let .response(id, result, remoteError):
            guard let request = pending.removeValue(forKey: id) else { return }
            allocator.release(id)
            request.timeoutTask.cancel()
            if let remoteError {
                let code = remoteError.code.map(String.init) ?? "unknown"
                Log.logger.error(
                    "RPC \(request.method, privacy: .public) failed remotely, code \(code, privacy: .public)."
                )
                Log.logger.error("Remote message: \(remoteError.message, privacy: .private).")
                request.continuation.resume(throwing: CreatorMicroError.remoteError(
                    code: remoteError.code,
                    message: remoteError.message
                ))
            } else {
                request.continuation.resume(returning: result)
            }
        case .notification:
            notificationBroadcast.yield(message)
        }
    }

    private func timeOut(id: Int) {
        let method = pending[id]?.method
        if let method {
            Log.logger.error("RPC \(method, privacy: .public) timed out without a vendor answer.")
        } else {
            Log.logger.error("RPC request \(id, privacy: .public) timed out without a vendor answer.")
        }
        fail(id: id, error: CreatorMicroError.timeout)
    }

    private func fail(id: Int, error: any Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        allocator.release(id)
        if !(error is CancellationError), (error as? CreatorMicroError) != .timeout {
            Log.logger.error(
                "RPC \(request.method, privacy: .public) failed: \(String(describing: error), privacy: .public)."
            )
        }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
    }

    private func transportEnded(generation: Int) {
        guard generation == connectionGeneration, isConnected else { return }
        isConnected = false
        assembler.reset()
        Log.logger.error("The pad transport ended unexpectedly.")
        failAll(with: CreatorMicroError.disconnected)
        notificationBroadcast.finishCurrentSubscribers()
    }

    private func failAll(with error: any Error) {
        let requests = pending
        pending.removeAll()
        for (id, request) in requests {
            allocator.release(id)
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}
