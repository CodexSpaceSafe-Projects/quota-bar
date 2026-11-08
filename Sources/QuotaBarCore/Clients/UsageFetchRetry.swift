import Foundation

/// One initial attempt followed by at most five retries after 1, 2, 4, 8 and 16 seconds.
public enum UsageFetchRetry {
    public static func run<Value: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        shouldRetry: (Error) -> Bool = { _ in true },
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        operation: () async throws -> Value
    ) async throws -> Value {
        var retries = 0
        while true {
            try Task.checkCancellation()
            do {
                let value = try await operation()
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                guard !(error is CancellationError), retries < 5, shouldRetry(error) else { throw error }
                try await sleep(.seconds(1 << retries))
                retries += 1
            }
        }
    }
}
