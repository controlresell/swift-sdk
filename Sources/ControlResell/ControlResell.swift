import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// A missing or unusable configuration of the client.
public enum ControlResellConfigurationError: Error, Sendable, LocalizedError {
    case missingAPIKey

    public var errorDescription: String? {
        "No API key: pass one or set the \(ControlResell.apiKeyEnvironmentVariable) environment variable."
    }
}

/// The client of the ControlResell public API: one per API key, safe to share between tasks.
///
/// ```swift
/// let controlResell = try ControlResell(apiKey: "cr_live_...") // or set CONTROLRESELL_API_KEY
/// let me = try await controlResell.call { try await $0.getMe().ok.body.json }
/// for try await item in controlResell.allItems(sold: false) { print(item.name) }
/// ```
///
/// The operations are those of the generated ``Client`` (`controlResell.api`); ``call(_:)`` throws a ``ControlResellError`` instead of
/// the `ClientError` the generated client wraps it in.
public struct ControlResell: Sendable {
    public static let version = "1.0.0"
    public static let apiKeyEnvironmentVariable = "CONTROLRESELL_API_KEY"
    public static let defaultBaseURL = URL(string: "https://api.controlresell.com")!
    static var userAgent: String { "controlresell-swift/\(version)" }

    /// The generated client, with the middleware installed.
    public let api: Client

    /// - Parameters:
    ///   - apiKey: The key (`cr_live_...`); when nil, the `CONTROLRESELL_API_KEY` environment variable.
    ///   - baseURL: Another environment (staging, a test double).
    ///   - retry: How a call is retried.
    ///   - transport: What sends the requests; `URLSession.shared` by default.
    public init(
        apiKey: String? = nil,
        baseURL: URL = ControlResell.defaultBaseURL,
        retry: RetryPolicy = RetryPolicy(),
        transport: any ClientTransport = URLSessionTransport()
    ) throws {
        try self.init(apiKey: apiKey, baseURL: baseURL, middleware: nil, retry: retry, transport: transport)
    }

    init(
        apiKey: String?,
        baseURL: URL,
        middleware: ControlResellMiddleware?,
        retry: RetryPolicy,
        transport: any ClientTransport
    ) throws {
        let key = apiKey ?? ProcessInfo.processInfo.environment[Self.apiKeyEnvironmentVariable]
        guard let key, !key.isEmpty else { throw ControlResellConfigurationError.missingAPIKey }
        api = Client(
            serverURL: baseURL,
            transport: transport,
            middlewares: [middleware ?? ControlResellMiddleware(apiKey: key, retry: retry)]
        )
    }

    /// Runs an operation of the generated client; whatever fails is a ``ControlResellError`` (an API error or a connection error).
    public func call<T: Sendable>(_ operation: @Sendable (Client) async throws -> T) async throws -> T {
        do {
            return try await operation(api)
        } catch {
            throw ControlResellError.unwrapping(error)
        }
    }
}
