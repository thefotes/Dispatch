import DispatchProviders

/// Guidance shown under Herdr's connection status in the menu bar panel.
public enum HerdrPanelMessage {
    public static func message(for state: HerdrState, socketExists: Bool) -> String? {
        switch state.availability {
        case .disconnected where !socketExists:
            "Herdr isn't running. Start Herdr in your terminal. "
                + "If you don't use Herdr, see the README's \"Is this for you?\" section."
        case .disconnected:
            "Herdr's socket is present, but Dispatch can't connect or understand its response. "
                + "Check that Herdr 0.9.1 or later is running (protocol 22)."
        case .connecting:
            "Connecting to Herdr…"
        case .available:
            nil
        }
    }
}
