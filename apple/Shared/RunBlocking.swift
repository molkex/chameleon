import Foundation

/// Bridges async/await operations to synchronous context.
/// Used by libbox Go callbacks (openTun, clearDNSCache, etc.) which must be synchronous.

func runBlocking<T>(_ block: @Sendable @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached {
        let value = await block()
        box.result0 = value
        semaphore.signal()
    }
    semaphore.wait()
    return box.result0
}

func runBlocking<T>(_ block: @Sendable @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached {
        do {
            let value = try await block()
            box.result = .success(value)
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.result.get()
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>!
    var result0: T!
}
