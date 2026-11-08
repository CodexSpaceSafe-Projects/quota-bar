import Foundation

@main
enum UsageFetchRetryCheck {
    private enum Failure: Error, Equatable { case attempt(Int) }

    @MainActor
    static func main() async throws {
        var attempts = 0
        var delays: [Duration] = []

        let immediate = try await UsageFetchRetry.run(sleep: { delays.append($0) }) {
            attempts += 1
            return 42
        }
        precondition(immediate == 42 && attempts == 1 && delays.isEmpty)

        for succeedsOn in [3, 6] {
            attempts = 0
            delays = []
            let result = try await UsageFetchRetry.run(sleep: { delays.append($0) }) {
                attempts += 1
                if attempts < succeedsOn { throw Failure.attempt(attempts) }
                return attempts
            }
            precondition(result == succeedsOn && attempts == succeedsOn)
            precondition(delays == Array([1, 2, 4, 8, 16].prefix(succeedsOn - 1)).map { .seconds($0) })
        }

        attempts = 0
        delays = []
        do {
            try await UsageFetchRetry.run(sleep: { delays.append($0) }) {
                attempts += 1
                throw Failure.attempt(attempts)
            }
            preconditionFailure("A failed fetch must throw after five retries")
        } catch let error as Failure {
            precondition(error == .attempt(6))
        }
        precondition(attempts == 6 && delays == [1, 2, 4, 8, 16].map { .seconds($0) })

        attempts = 0
        delays = []
        do {
            try await UsageFetchRetry.run(shouldRetry: { _ in false }, sleep: { delays.append($0) }) {
                attempts += 1
                throw Failure.attempt(attempts)
            }
            preconditionFailure("A permanent error must be returned immediately")
        } catch let error as Failure {
            precondition(error == .attempt(1))
        }
        precondition(attempts == 1 && delays.isEmpty)

        attempts = 0
        do {
            try await UsageFetchRetry.run(sleep: { _ in preconditionFailure("Cancellation must not retry") }) {
                attempts += 1
                throw CancellationError()
            }
            preconditionFailure("Cancellation must propagate")
        } catch is CancellationError {}
        precondition(attempts == 1)

        attempts = 0
        let cancelledBeforeFetch = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await UsageFetchRetry.run {
                attempts += 1
            }
        }
        do {
            try await cancelledBeforeFetch.value
            preconditionFailure("An already cancelled task must not fetch")
        } catch is CancellationError {}
        precondition(attempts == 0)

        var sleepingFetch: Task<Void, Error>?
        await withCheckedContinuation { startedSleeping in
            sleepingFetch = Task { @MainActor in
                try await UsageFetchRetry.run(sleep: { delay in
                    startedSleeping.resume()
                    try await Task.sleep(for: delay)
                }) {
                    attempts += 1
                    throw Failure.attempt(attempts)
                }
            }
        }
        sleepingFetch!.cancel()
        do {
            try await sleepingFetch!.value
            preconditionFailure("Cancellation during backoff must stop the next attempt")
        } catch is CancellationError {}
        precondition(attempts == 1)

        print("Usage fetch retry success, five-retry limit, exponential delays, permanent errors and cancellation checks passed")
    }
}
