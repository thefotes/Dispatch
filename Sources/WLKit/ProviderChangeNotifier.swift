import Foundation

/// Thread-safe holder for `Provider.subscribe`'s callback — install it,
/// fire it, clear it on cancel. Every provider that supports `subscribe()`
/// needs exactly this bookkeeping, and none of it is specific to any one
/// provider's backend.
///
/// Composed into a provider rather than inherited from a base class:
/// `Provider` is a protocol, so any type can conform to it regardless of
/// what it already subclasses, and a Swift base class would give nothing to
/// a provider written in another language anyway — the six-method wire
/// contract is the only thing that has to be shared across languages, and
/// this is Swift-only convenience on top of it.
final class ProviderChangeNotifier: @unchecked Sendable {
    private let lock = NSLock()
    private var onChange: (@Sendable () -> Void)?

    /// Installs `onChange`. The returned token clears it on cancel, then
    /// runs `onTeardown` — the provider's own cleanup (stop streams, etc.),
    /// kept as a separate step so it only ever runs after the callback is
    /// already gone, never concurrently with a `notify()` still holding it.
    func subscribe(
        _ onChange: @escaping @Sendable () -> Void,
        onTeardown: @escaping () -> Void
    ) -> ProviderSubscription {
        lock.lock()
        self.onChange = onChange
        lock.unlock()
        return ProviderSubscription { [weak self] in
            self?.lock.lock()
            self?.onChange = nil
            self?.lock.unlock()
            onTeardown()
        }
    }

    /// Fires the installed callback, if there is one.
    func notify() {
        lock.lock()
        let callback = onChange
        lock.unlock()
        callback?()
    }
}
