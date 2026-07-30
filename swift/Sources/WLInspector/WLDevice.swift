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
final class WLDevice {

    static let vendorID = 0x303A
    static let reportID: UInt8 = 0x06
    static let channelDebug: UInt8 = 1
    static let channelRPC: UInt8 = 2
    static let maxChunk = 61
    static let reportSize = 64

    struct Info {
        var product: String
        var productID: Int
        var transport: String
        var serial: String
    }

    enum Failure: LocalizedError {
        case notFound
        case openFailed(IOReturn)
        case notConnected
        case writeFailed(IOReturn)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No Work Louder device on the HID bus. If it is a Bluetooth pad it may have gone to sleep — press a key to wake it."
            case .openFailed(let r):
                if r == kIOReturnNotPrivileged || UInt32(bitPattern: r) == 0xE00002C1 {
                    return "Open refused (0xE00002C1). Grant Input Monitoring to the process running this app, under System Settings → Privacy & Security → Input Monitoring."
                }
                return String(format: "IOHIDDeviceOpen failed (0x%08X)", UInt32(bitPattern: r))
            case .notConnected:
                return "Not connected."
            case .writeFailed(let r):
                return String(format: "IOHIDDeviceSetReport failed (0x%08X)", UInt32(bitPattern: r))
            case .timeout(let m):
                return "Timed out waiting for \(m)."
            }
        }
    }

    // Callbacks, always delivered on the main queue.
    var onTX: ((String, Any?, Int) -> Void)?          // method, params, id
    var onResponse: ((Int, Any?, String?) -> Void)?   // id, result, errorMessage
    var onNotification: ((String, Any?) -> Void)?     // method, params
    var onDeviceLog: ((String) -> Void)?
    var onDisconnect: ((String) -> Void)?

    private(set) var info: Info?
    private var device: IOHIDDevice?
    private var inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
    private var rpcAccumulator = ""
    private var debugAccumulator = ""
    private var pending: [Int: (Any?, String?) -> Void] = [:]
    private var nextID = 1

    var isConnected: Bool { device != nil }

    deinit { inputBuffer.deallocate() }

    // MARK: - Connect

    func connect() throws {
        disconnect(reason: nil)

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match on vendor only: over Bluetooth the pad presents a single
        // IOHIDDevice whose *primary* usage is keyboard, with the vendor
        // collection alongside it in DeviceUsagePairs.
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: WLDevice.vendorID] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let dev = set.first else {
            throw Failure.notFound
        }

        let result = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw Failure.openFailed(result) }

        device = dev
        info = Info(
            product: string(dev, kIOHIDProductKey) ?? "Work Louder device",
            productID: number(dev, kIOHIDProductIDKey) ?? 0,
            transport: string(dev, kIOHIDTransportKey) ?? "?",
            serial: string(dev, kIOHIDSerialNumberKey) ?? ""
        )

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, inputBuffer, WLDevice.reportSize, { ctx, _, _, _, _, report, length in
            guard let ctx, length > 0 else { return }
            let me = Unmanaged<WLDevice>.fromOpaque(ctx).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
            DispatchQueue.main.async { me.handleReport(bytes) }
        }, context)

        IOHIDDeviceRegisterRemovalCallback(dev, { ctx, _, _ in
            guard let ctx else { return }
            let me = Unmanaged<WLDevice>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.disconnect(reason: "device removed") }
        }, context)

        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    func disconnect(reason: String?) {
        guard let dev = device else { return }
        IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        device = nil
        info = nil
        rpcAccumulator = ""
        debugAccumulator = ""
        for (_, done) in pending { done(nil, "disconnected") }
        pending.removeAll()
        if let reason { onDisconnect?(reason) }
    }

    // MARK: - Send

    @discardableResult
    func call(_ method: String, params: Any?, completion: ((Any?, String?) -> Void)? = nil) -> Int? {
        guard let dev = device else {
            completion?(nil, Failure.notConnected.errorDescription)
            return nil
        }

        // Firmware only accepts call ids below 1000.
        let id = nextID
        nextID = nextID % 998 + 1

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
                completion?(nil, Failure.writeFailed(rc).errorDescription)
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

    private func handleReport(_ bytes: [UInt8]) {
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
            } else if let method = decoded["method"] as? String {
                // Device-pushed notification: v.oai.hid, v.oai.rad.
                onNotification?(method, decoded["params"])
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
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
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
}
