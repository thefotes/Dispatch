import Foundation

extension WLDevice {
    /// async/await over the completion-based `call`.
    ///
    /// Hops to the main queue first: `call` touches the pending-request table
    /// and schedules its timeout there, and input reports are delivered there
    /// too, so keeping every access on one queue is what makes the table safe
    /// without locking.
    public func callAsync(_ method: String, params: Any? = nil) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let finish: (Result<Any?, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            DispatchQueue.main.async {
                let sent = self.call(method, params: params) { result, error in
                    if let error {
                        finish(.failure(WLDevice.Failure.rpc(method, error)))
                    } else {
                        finish(.success(result))
                    }
                }
                if sent == nil {
                    // `call` refuses before sending when there is no device or
                    // the write fails; the completion already carried the
                    // reason, so this only covers the silent case.
                    finish(.failure(WLDevice.Failure.notConnected))
                }
            }
        }
    }
}
