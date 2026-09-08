import Foundation
import IOKit
import IOKit.hid

/// Raw-HID JSON-RPC transport for Work Louder devices.
///
/// Framing, on 64-byte reports carried by the vendor collection
/// (usage page 0xFF00 / usage 1):
///
///     byte 0      report id, always 0x06
///     byte 1      channel: 1 = firmware debug log, 2 = JSON-RPC
///     byte 2      payload length in this report, max 61
///     bytes 3..   UTF-8 fragment of the JSON message
///
/// Messages are split across as many reports as needed and reassembled by
/// scanning for balanced top-level braces.
///
/// The device must be opened **non-exclusively**. Its vendor collection shares
/// an IOHIDDevice with a keyboard collection, and macOS refuses to let anything
/// seize a keyboard — a seizing open fails with 0xE00002C1, which looks exactly
/// like a missing Input Monitoring grant and is not.
public final class WLDevice {

    public static let vendorID = 0x303A
    public static let reportID: UInt8 = 0x06
    public static let channelDebug: UInt8 = 1
    public static let channelRPC: UInt8 = 2
    public static let maxChunk = 61
    public static let reportSize = 64

    public struct Info {
        public var product: String
        public var productID: Int
        public var transport: String
        public var serial: String
        public var usagePage: Int
        public var interfaceCount: Int
        /// The IORegistry entry id of the interface this session opened —
        /// stable for as long as the device is on the bus, and what
        /// `connect(excluding:)` names when a caller wants the *next*
        /// interface instead of this one.
        public var registryID: UInt64 = 0
    }

    public static let vendorUsagePage = 0xFF00
    public static let vendorUsage = 0x01

    public enum Failure: LocalizedError {
        case notFound
        case noVendorCollection
        case allCandidatesRejected
        case openFailed(IOReturn)
        case notConnected
        case writeFailed(IOReturn)
        case timeout(String)
        case rpc(String, String)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "No Work Louder device on the HID bus. If it is a Bluetooth pad it may have gone to sleep — press a key to wake it."
            case .noVendorCollection:
                return "Found the device, but not its vendor collection (usage page 0xFF00). Nothing to talk to."
            case .allCandidatesRejected:
                return "Every interface the pad offers opened, and none of them answered. The session is wedged rather than missing."
            case .openFailed(let r):
                if r == kIOReturnNotPrivileged || UInt32(bitPattern: r) == 0xE00002C1 {
                    return "Open refused (0xE00002C1). Grant Input Monitoring to the process running this app, under System Settings → Privacy & Security → Input Monitoring."
                }
                return String(format: "IOHIDDeviceOpen failed (0x%08X)", UInt32(bitPattern: r))
            case .notConnected:
                return "Not connected."
            case .writeFailed(let r):
                let code = UInt32(bitPattern: r)
                let name: String
                switch code {
                case 0xE00002CD: name = " — kIOReturnNotOpen, the device handle is no longer open"
                case 0xE00002C0: name = " — kIOReturnNoDevice"
                case 0xE00002C5: name = " — kIOReturnExclusiveAccess"
                case 0xE00002C1: name = " — kIOReturnNotPrivileged"
                case 0xE00002C7: name = " — kIOReturnUnsupported, wrong report id or interface"
                default: name = ""
                }
                return String(format: "IOHIDDeviceSetReport failed (0x%08X)", code) + name
            case .timeout(let m):
                return "Timed out waiting for \(m)."
            case .rpc(let method, let message):
                return "\(method): \(message)"
            }
        }
    }

    // Callbacks, always delivered on the main queue.
    public var onTX: ((String, Any?, Int) -> Void)?          // method, params, id
    public var onResponse: ((Int, Any?, String?) -> Void)?   // id, result, errorMessage
    public var onNotification: ((String, Any?) -> Void)?     // method, params
    public var onDeviceLog: ((String) -> Void)?
    public var onWriteError: ((String, String) -> Void)?
    /// Every input report, before framing. Reports that do not match the
    /// channel framing are otherwise dropped, which hides any other traffic
    /// the device emits - key presses included.
    public var onRawReport: ((UInt32, [UInt8]) -> Void)?
    public var onDisconnect: ((String) -> Void)?

    public private(set) var info: Info?
    /// When set, every call is answered by this instead of by the HID bus, and
    /// nothing touches IOKit. See `PadEmulator`.
    public let emulator: PadEmulator?
    private var emulatedConnected = false
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
    private var rpcAccumulator = ""
    private var debugAccumulator = ""
    private var pending: [Int: (Any?, String?) -> Void] = [:]
    private var nextID = 1

    public var isConnected: Bool { device != nil || emulatedConnected }

    public init(emulator: PadEmulator? = nil) { self.emulator = emulator }

    deinit { inputBuffer.deallocate() }

    // MARK: - Choosing an interface

    /// One matched IOHIDDevice, reduced to the properties the choice actually
    /// turns on — so the ordering rule below can be exercised without a HID
    /// bus under it.
    struct Candidate: Equatable {
        var registryID: UInt64
        var primaryUsagePage: Int
        /// Every usage page in `DeviceUsagePairs`, primary included.
        var usagePages: [Int]
        /// `kIOHIDTransportKey` — "USB", "Bluetooth", "Bluetooth Low Energy".
        var transport: String

        /// Whether this interface carries the vendor collection at all. An
        /// interface without it is not a candidate: report id 6 writes to it
        /// are silently dropped.
        var hasVendorCollection: Bool {
            primaryUsagePage == WLDevice.vendorUsagePage
                || usagePages.contains(WLDevice.vendorUsagePage)
        }

        var isVendorPrimary: Bool { primaryUsagePage == WLDevice.vendorUsagePage }
    }

    /// USB first, unknown transports next, Bluetooth last.
    ///
    /// Both transports advertise the same vendor collection, so both open
    /// happily — but a pad that is on the wire is on the wire for a reason,
    /// and the BLE node is the one that comes back after a sleep with a
    /// session that accepts writes and does nothing with them. Given the
    /// choice, take the cable.
    static func transportRank(_ transport: String) -> Int {
        let name = transport.lowercased()
        if name.contains("usb") { return 0 }
        if name.contains("bluetooth") || name.contains("ble") { return 2 }
        return 1
    }

    /// Match on vendor plus the vendor usage pair. Vendor alone opens every
    /// Espressif-vendor HID device on the bus — other ESP32 gadgets, second
    /// pads — and each extra non-exclusive open on a keyboard collection
    /// raises the odds of HID contention. Over Bluetooth the pad presents a
    /// single IOHIDDevice whose *primary* usage is keyboard, with the vendor
    /// collection alongside it in DeviceUsagePairs, so the pair still matches
    /// it.
    static let matching: CFDictionary = [
        kIOHIDVendorIDKey: WLDevice.vendorID,
        kIOHIDDeviceUsagePairsKey: [
            [kIOHIDDeviceUsagePageKey: WLDevice.vendorUsagePage,
             kIOHIDDeviceUsageKey: WLDevice.vendorUsage]
        ]
    ] as CFDictionary

    /// Every interface the pad is currently offering, best first — the list
    /// `connect` works through. Opens nothing, so it is safe to ask while
    /// something else holds the device: this is the diagnostic view, for a
    /// test or an inspector that wants to say which interface it got and what
    /// the alternatives were.
    func availableInterfaces() throws -> [Candidate] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, WLDevice.matching)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard openResult == kIOReturnSuccess else { throw Failure.openFailed(openResult) }
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
            throw Failure.notFound
        }
        return WLDevice.orderedCandidates(set.map(describe))
    }

    /// The order interfaces are tried in, best first.
    ///
    /// Transport decides first (see `transportRank`), then the shape of the
    /// interface: a *vendor-primary* one is the better match, because a
    /// firmware that splits the vendor collection onto its own interface
    /// would put it there — today's firmware puts all four collections on one
    /// keyboard-primary interface, so this clause never fires over USB. The
    /// registry id is the last word purely so the order is deterministic:
    /// `IOHIDManagerCopyDevices` hands back a `Set`, and picking its first
    /// element made "which pad did we open" a coin flip whenever the pad was
    /// on both transports at once.
    static func orderedCandidates(_ candidates: [Candidate]) -> [Candidate] {
        candidates
            .filter(\.hasVendorCollection)
            .sorted { lhs, rhs in
                let (left, right) = (transportRank(lhs.transport), transportRank(rhs.transport))
                if left != right { return left < right }
                if lhs.isVendorPrimary != rhs.isVendorPrimary { return lhs.isVendorPrimary }
                return lhs.registryID < rhs.registryID
            }
    }

    // MARK: - Connect

    /// Opens the pad, preferring the interface most likely to answer.
    ///
    /// `excluding` names registry ids already tried and found silent, so a
    /// caller that opened an interface and got nothing back can come straight
    /// here for the next one. That is not a theoretical case: an open only
    /// proves macOS handed over the interface, and a dead Bluetooth session
    /// opens exactly as readily as a live USB one — see
    /// `BridgeController.openDevice`, which does the proving.
    public func connect(excluding rejected: Set<UInt64> = []) throws {
        disconnect(reason: nil)

        if let emulator {
            emulatedConnected = true
            info = Info(
                product: "Creator Micro 2 (emulated)",
                productID: 0x8297,
                transport: "emulated",
                serial: "EMULATOR",
                usagePage: WLDevice.vendorUsagePage,
                interfaceCount: 1
            )
            emulator.onNotify = { [weak self] method, params in
                guard let self else { return }
                DispatchQueue.main.async { self.onNotification?(method, params) }
            }
            return
        }

        // Must be held for the lifetime of the connection: releasing the
        // manager tears down the devices it opened, and every later SetReport
        // then fails with kIOReturnNotOpen.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, WLDevice.matching)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            // Close and drop the manager before throwing: an open manager held
            // here leaks, and every reopen retry (every 3 s) would add another.
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
            throw Failure.openFailed(openResult)
        }

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
            throw Failure.notFound
        }
        // Match on the vendor collection, never on the primary usage.
        //
        // macOS makes one IOHIDDevice per HID *interface*, not per top-level
        // collection, and this pad puts all four of its collections (boot
        // keyboard, two consumer, and the vendor channel we want) on a single
        // interface. So on each transport it enumerates as exactly ONE
        // IOHIDDevice whose PrimaryUsagePage is 1 (keyboard) — the vendor pair
        // 0xFF00/1 appears only in DeviceUsagePairs. Verified 2026-09-05 over
        // USB: one IOUSBHostInterface, bInterfaceNumber 0, and report id 6
        // writes to that keyboard-primary device succeed.
        //
        // Do not "simplify" this to the first vendor-id match: on a firmware
        // that splits the collections across interfaces, that lands on the
        // keyboard and every report id 6 write is silently dropped.
        var devices: [UInt64: IOHIDDevice] = [:]
        var candidates: [Candidate] = []
        for dev in set {
            let candidate = describe(dev)
            candidates.append(candidate)
            devices[candidate.registryID] = dev
        }
        let ordered = WLDevice.orderedCandidates(candidates)
        guard !ordered.isEmpty else { throw Failure.noVendorCollection }
        let remaining = ordered.filter { !rejected.contains($0.registryID) }
        guard !remaining.isEmpty else { throw Failure.allCandidatesRejected }

        // Try them in order rather than betting everything on the first: an
        // interface can be open elsewhere (the vendor's own Input app, a
        // second copy of this one), and the next one down is often fine.
        var lastFailure: IOReturn?
        for candidate in remaining {
            guard let dev = devices[candidate.registryID] else { continue }
            let result = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else {
                lastFailure = result
                continue
            }
            adopt(dev, candidate: candidate, interfaceCount: set.count)
            return
        }
        throw Failure.openFailed(lastFailure ?? kIOReturnNoDevice)
    }

    /// Takes ownership of a freshly opened interface: records what it is, and
    /// starts listening on it.
    private func adopt(_ dev: IOHIDDevice, candidate: Candidate, interfaceCount: Int) {
        device = dev
        info = Info(
            product: string(dev, kIOHIDProductKey) ?? "Work Louder device",
            productID: number(dev, kIOHIDProductIDKey) ?? 0,
            transport: candidate.transport.isEmpty ? "?" : candidate.transport,
            serial: string(dev, kIOHIDSerialNumberKey) ?? "",
            usagePage: candidate.primaryUsagePage,
            interfaceCount: interfaceCount,
            registryID: candidate.registryID
        )

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, inputBuffer, WLDevice.reportSize, { ctx, _, _, _, reportID, report, length in
            guard let ctx, length > 0 else { return }
            let me = Unmanaged<WLDevice>.fromOpaque(ctx).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
            DispatchQueue.main.async { me.handleReport(bytes, reportID: reportID) }
        }, context)

        IOHIDDeviceRegisterRemovalCallback(dev, { ctx, _, _ in
            guard let ctx else { return }
            let me = Unmanaged<WLDevice>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.disconnect(reason: "device removed") }
        }, context)

        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    public func disconnect(reason: String?) {
        if emulator != nil {
            guard emulatedConnected else { return }
            emulatedConnected = false
            emulator?.onNotify = nil
            info = nil
            for (_, done) in pending { done(nil, "disconnected") }
            pending.removeAll()
            if let reason { onDisconnect?(reason) }
            return
        }
        // Device first, then manager — the manager must outlive the device it
        // opened. When device is nil (a connect() that threw after opening
        // the manager) this still closes the manager, so the 3 s reopen retry
        // does not accumulate one open manager per attempt.
        if let dev = device {
            IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            device = nil
        }
        if let mgr = manager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            manager = nil
        }
        info = nil
        rpcAccumulator = ""
        debugAccumulator = ""
        for (_, done) in pending { done(nil, "disconnected") }
        pending.removeAll()
        if let reason { onDisconnect?(reason) }
    }

    // MARK: - Send

    @discardableResult
    public func call(_ method: String, params: Any?, completion: ((Any?, String?) -> Void)? = nil) -> Int? {
        guard emulatedConnected || device != nil else {
            completion?(nil, Failure.notConnected.errorDescription)
            return nil
        }

        // Firmware only accepts call ids below 1000.
        let id = nextID
        nextID = nextID % 998 + 1

        if let emulator {
            onTX?(method, params, id)
            // Answer on the next turn of the run loop rather than inline: a
            // real call is never synchronous, and callers that assume it is
            // would work here and deadlock on hardware.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let (result, error) = emulator.handle(method, params: params)
                self.onResponse?(id, result, error)
                completion?(result, error)
            }
            return id
        }

        guard let dev = device else {
            completion?(nil, Failure.notConnected.errorDescription)
            return nil
        }

        var message: [String: Any] = ["method": method, "id": id]
        message["params"] = params ?? NSNull()

        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else {
            completion?(nil, "could not encode params")
            return nil
        }

        let payload = [UInt8](data)
        var offset = 0
        while offset < payload.count {
            let n = min(WLDevice.maxChunk, payload.count - offset)
            var report = [UInt8](repeating: 0, count: WLDevice.reportSize)
            report[0] = WLDevice.reportID
            report[1] = WLDevice.channelRPC
            report[2] = UInt8(n)
            report.replaceSubrange(3..<(3 + n), with: payload[offset..<(offset + n)])

            let rc = report.withUnsafeBufferPointer { buf in
                IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(WLDevice.reportID), buf.baseAddress!, buf.count)
            }
            guard rc == kIOReturnSuccess else {
                // Surface the failure rather than dropping it: a silent write
                // error is indistinguishable from a device that ignores you.
                let message = Failure.writeFailed(rc).errorDescription ?? "write failed"
                onWriteError?(method, message)
                completion?(nil, message)
                return nil
            }
            offset += n
        }

        onTX?(method, params, id)

        if let completion {
            pending[id] = completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
                waiting(nil, Failure.timeout(method).errorDescription)
            }
        }
        return id
    }

    // MARK: - Receive

    private func handleReport(_ bytes: [UInt8], reportID: UInt32) {
        onRawReport?(reportID, bytes)
        // The input callback delivers the report id out-of-band, so the
        // payload normally starts at index 0 — but be tolerant of stacks that
        // include it, and try the shifted alignment too.
        if !parse(bytes, at: 0) { _ = parse(bytes, at: 1) }
    }

    private func parse(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard bytes.count > offset + 2 else { return false }
        let channel = bytes[offset]
        let length = Int(bytes[offset + 1])
        guard channel == WLDevice.channelRPC || channel == WLDevice.channelDebug else { return false }
        guard length > 0, length <= WLDevice.maxChunk, bytes.count >= offset + 2 + length else { return false }

        let slice = Array(bytes[(offset + 2)..<(offset + 2 + length)])
        guard let text = String(bytes: slice, encoding: .utf8) else { return false }

        if channel == WLDevice.channelDebug {
            debugAccumulator += text
            while let idx = debugAccumulator.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let line = String(debugAccumulator[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                debugAccumulator = String(debugAccumulator[debugAccumulator.index(after: idx)...])
                if !line.isEmpty { onDeviceLog?(line) }
            }
            if debugAccumulator.count > 4096 { debugAccumulator = "" }
            return true
        }

        rpcAccumulator += text
        drainRPC()
        if rpcAccumulator.count > 8192 { rpcAccumulator = "" }
        return true
    }

    /// Pulls complete top-level JSON objects out of the accumulator.
    private func drainRPC() {
        while let object = nextJSONObject() {
            guard
                let data = object.data(using: .utf8),
                let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let id = decoded["id"] as? Int {
                let error = (decoded["error"] as? [String: Any])?["message"] as? String
                let result = decoded["result"]
                onResponse?(id, result, error)
                if let waiting = pending.removeValue(forKey: id) { waiting(result, error) }
            } else if let method = (decoded["m"] as? String) ?? (decoded["method"] as? String) {
                // Device-pushed notification. Note the envelope is abbreviated
                // here - {"m": method, "p": params} - while responses use the
                // full "method". Matching only on "method" drops every one.
                let params = decoded["m"] != nil ? decoded["p"] : decoded["params"]
                onNotification?(method, params)
            }
        }
    }

    private func nextJSONObject() -> String? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var index = rpcAccumulator.startIndex

        while index < rpcAccumulator.endIndex {
            let ch = rpcAccumulator[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if ch == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let s = start {
                        let end = rpcAccumulator.index(after: index)
                        let object = String(rpcAccumulator[s..<end])
                        rpcAccumulator = String(rpcAccumulator[end...])
                        return object
                    }
                }
            }
            index = rpcAccumulator.index(after: index)
        }
        return nil
    }

    // MARK: - Properties

    private func string(_ dev: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(dev, key as CFString) as? String
    }

    private func number(_ dev: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(dev, key as CFString) as? Int
    }

    private func primaryUsagePage(_ dev: IOHIDDevice) -> Int? {
        number(dev, kIOHIDPrimaryUsagePageKey)
    }

    /// Reads an IOHIDDevice down to the fields the selection rule reads.
    private func describe(_ dev: IOHIDDevice) -> Candidate {
        let pairs = IOHIDDeviceGetProperty(dev, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]]
        return Candidate(
            registryID: registryID(dev) ?? 0,
            primaryUsagePage: primaryUsagePage(dev) ?? 0,
            usagePages: pairs?.compactMap { $0[kIOHIDDeviceUsagePageKey] as? Int } ?? [],
            transport: string(dev, kIOHIDTransportKey) ?? ""
        )
    }

    /// The IORegistry entry id behind an IOHIDDevice — unique on the bus and
    /// stable while the device is on it, which the serial number is not: the
    /// pad reports the same serial on USB and Bluetooth at once.
    private func registryID(_ dev: IOHIDDevice) -> UInt64? {
        let service = IOHIDDeviceGetService(dev)
        guard service != 0 else { return nil }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { return nil }
        return id
    }
}
