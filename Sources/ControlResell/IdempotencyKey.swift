import Foundation

/// Chooses the `Idempotency-Key` of the `POST` calls made inside ``with(_:operation:)``. Without it the SDK generates a UUID v4 for
/// each call; either way the key is the same on every retry of the call.
///
/// ```swift
/// try await IdempotencyKey.with("import-2026-10-26-item-42") {
///     try await controlResell.call { try await $0.publishItem(...).ok }
/// }
/// ```
public enum IdempotencyKey {
    @TaskLocal static var current: String?

    public static func with<T>(_ key: String, operation: () async throws -> T) async rethrows -> T {
        try await $current.withValue(key, operation: operation)
    }
}
