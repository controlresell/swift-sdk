import Foundation
import HTTPTypes
import OpenAPIRuntime

/// How a call is retried.
public struct RetryPolicy: Sendable {
    /// Retries after the first attempt (2 by default); 0 turns them off.
    public var maxRetries: Int
    /// The first delay in seconds, doubled at each retry, with a random part; a `Retry-After` takes precedence.
    public var baseDelay: TimeInterval
    /// The longest delay between two attempts, in seconds.
    public var maxDelay: TimeInterval

    public init(maxRetries: Int = 2, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 30) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }
}

/// The middleware that makes a call to the ControlResell API: it sets the key, the `User-Agent` and the `Idempotency-Key` of a
/// `POST`, retries a failed call, and throws a ``ControlResellError`` for an answer that is not a success.
/// ``ControlResell`` installs it; install it yourself on a generated `Client` to choose the transport.
public struct ControlResellMiddleware: ClientMiddleware {
    static let idempotencyKeyName = HTTPField.Name("Idempotency-Key")!
    private static let idempotencyInProgress = "idempotency_in_progress"
    private static let maxBodyBytes = 16 * 1024 * 1024

    private let apiKey: String
    private let retry: RetryPolicy
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(apiKey: String, retry: RetryPolicy = RetryPolicy()) {
        self.init(apiKey: apiKey, retry: retry, sleep: { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        })
    }

    init(apiKey: String, retry: RetryPolicy, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.apiKey = apiKey
        self.retry = retry
        self.sleep = sleep
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(apiKey)"
        request.headerFields[.userAgent] = ControlResell.userAgent
        let isPost = request.method == .post
        // `POST /webhook-endpoints/{id}/test` sends a real event and ignores the key: a replay sends a second one.
        let webhookTest = isPost && Self.isWebhookTest(path: request.path ?? "")
        if isPost, request.headerFields[Self.idempotencyKeyName] == nil {
            // One key per call, kept on every retry.
            request.headerFields[Self.idempotencyKeyName] = IdempotencyKey.current ?? UUID().uuidString.lowercased()
        }
        // A body is read once; each attempt sends a new one.
        var bodyBytes: ArraySlice<UInt8>?
        if let body { bodyBytes = try await ArraySlice(collecting: body, upTo: Self.maxBodyBytes) }

        var attempt = 0
        while true {
            let response: HTTPResponse
            let responseBody: HTTPBody?
            do {
                (response, responseBody) = try await next(request, bodyBytes.map { HTTPBody($0) }, baseURL)
            } catch {
                // The generated client wraps what the transport throws in a `ClientError`: read the cause.
                let cause = ControlResellError.rootCause(error)
                if cause is CancellationError || (cause as? URLError)?.code == .cancelled || Task.isCancelled { throw error }
                // A request that may have reached the server is not replayed for the test event.
                if webhookTest || attempt >= retry.maxRetries { throw ControlResellError.connection(cause) }
                try await sleep(backoff(attempt))
                attempt += 1
                continue
            }

            if (200..<300).contains(response.status.code) { return (response, responseBody) }

            var data: Data?
            if let responseBody, let bytes = try? await ArraySlice(collecting: responseBody, upTo: Self.maxBodyBytes) { data = Data(bytes) }
            let retryAfter = Self.retryAfter(response)
            if attempt < retry.maxRetries, shouldRetry(status: response.status.code, body: data, webhookTest: webhookTest) {
                try await sleep(retryAfter.map { min($0, retry.maxDelay) } ?? backoff(attempt))
                attempt += 1
                continue
            }
            throw ControlResellError.response(status: response.status.code, body: data, retryAfter: retryAfter)
        }
    }

    /// A rate limit, a gateway or availability error; never a 500; a 409 only for a key still in flight.
    private func shouldRetry(status: Int, body: Data?, webhookTest: Bool) -> Bool {
        switch status {
        case 429: return true
        case 502, 503, 504: return !webhookTest
        case 409: return !webhookTest && ControlResellError.Envelope(body).code == Self.idempotencyInProgress
        default: return false
        }
    }

    private func backoff(_ attempt: Int) -> TimeInterval {
        let exponential = retry.baseDelay * pow(2, Double(attempt))
        let jitter = Double.random(in: 0...(retry.baseDelay / 2))
        return min(exponential + jitter, retry.maxDelay)
    }

    static func isWebhookTest(path: String) -> Bool {
        let path = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = path.split(separator: "/")
        guard let last = parts.last, last == "test", parts.count >= 3 else { return false }
        return parts[parts.count - 3] == "webhook-endpoints"
    }

    private static func retryAfter(_ response: HTTPResponse) -> TimeInterval? {
        guard let value = response.headerFields[.retryAfter]?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}
