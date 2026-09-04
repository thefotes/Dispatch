import Foundation

/// The wide key is two physical switches under one keycap (matrix positions
/// 10 and 11, `Pad.voiceKeyIDs`), both bound to `KV_OAI_AG*` so either half
/// lights and either half reports a press — `docs/hacking.md` notes the
/// stock firmware leaves position 11 as `KC_NONE`, unbound, which is likely
/// exactly to avoid this: with both bound, a single physical press can
/// report as two separate key-down notifications, milliseconds apart, and
/// `BridgeController.handleKeyPress` has no way to tell that apart from two
/// real presses — whatever is bound to the key fires twice. For a toggle
/// (the default right-command tap, or a config-bound shortcut like
/// OpenSuperWhisper's ctrl+t) that means it turns on and immediately back
/// off, and the human sees nothing happen.
enum WideKeyDebounce {
    /// True when two notifications are close enough together to be the wide
    /// key's two switches reporting one physical press, not two separate
    /// ones. 150ms is generous for two switches under one keycap (which
    /// report within single-digit milliseconds of each other) while well
    /// under the fastest plausible deliberate double-press.
    static func isSamePress(_ a: DispatchTime, _ b: DispatchTime, thresholdMs: UInt64 = 150) -> Bool {
        let delta = a.uptimeNanoseconds > b.uptimeNanoseconds
            ? a.uptimeNanoseconds - b.uptimeNanoseconds
            : b.uptimeNanoseconds - a.uptimeNanoseconds
        return delta < thresholdMs * 1_000_000
    }
}
