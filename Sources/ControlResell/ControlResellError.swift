import Foundation
import OpenAPIRuntime

/// An error of a call to the ControlResell API: an answer of the API read from its envelope
/// `{"error": {code, message, params, requestId}}`, or a connection error.
///
/// ``kind`` tells which one: one case per status (400, 401, 402, 403, 404, 409, 422, 429, 5xx), and ``Kind/connection``.
public struct ControlResellError: Error, Sendable, LocalizedError, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// 400: the request is malformed.
        case badRequest
        /// 401: no credential, or an unknown, revoked or expired one.
        case authentication
        /// 402: the seller's plan does not include this.
        case paymentRequired
        /// 403: the API key does not grant the scope the route requires.
        case permissionDenied
        /// 404: no such resource for this seller.
        case notFound
        /// 409: an `Idempotency-Key` used with another request, or still in flight.
        case conflict
        /// 422: the request is well formed but refused.
        case unprocessableEntity
        /// 429: the rate limit of the API key is reached (see ``ControlResellError/retryAfter``).
        case rateLimited
        /// 5xx: an error of the API; retry later.
        case server
        /// Any other status.
        case other
        /// The API could not be reached (network, DNS, TLS), after the retries.
        case connection
    }

    public let kind: Kind
    /// The HTTP status; nil for a connection error.
    public let status: Int?
    /// The error's code (`item_not_found`, `rate_limited`...): an open string, match the ones you handle.
    public let code: String
    public let message: String
    /// The error's parameters.
    public let params: [String: String]
    /// The identifier to give the support.
    public let requestId: String?
    /// The `Retry-After` the API answered, in seconds, when it did (a 429).
    public let retryAfter: TimeInterval?
    /// The error that made the call fail, for a connection error.
    public let underlyingError: (any Error)?

    public init(
        kind: Kind,
        status: Int? = nil,
        code: String,
        message: String,
        params: [String: String] = [:],
        requestId: String? = nil,
        retryAfter: TimeInterval? = nil,
        underlyingError: (any Error)? = nil
    ) {
        self.kind = kind
        self.status = status
        self.code = code
        self.message = message
        self.params = params
        self.requestId = requestId
        self.retryAfter = retryAfter
        self.underlyingError = underlyingError
    }

    public var errorDescription: String? { description }

    public var description: String {
        var text = "ControlResell \(status.map(String.init) ?? "connection") \(code): \(message)"
        if let requestId { text += " (request \(requestId))" }
        return text
    }

    /// The error of an answer whose status is not a success, its body being the API's envelope (or anything else).
    static func response(status: Int, body: Data?, retryAfter: TimeInterval?) -> ControlResellError {
        let envelope = Envelope(body)
        let kind: Kind
        switch status {
        case 400: kind = .badRequest
        case 401: kind = .authentication
        case 402: kind = .paymentRequired
        case 403: kind = .permissionDenied
        case 404: kind = .notFound
        case 409: kind = .conflict
        case 422: kind = .unprocessableEntity
        case 429: kind = .rateLimited
        case 500...: kind = .server
        default: kind = .other
        }
        return ControlResellError(
            kind: kind,
            status: status,
            code: envelope.code ?? "http_\(status)",
            message: envelope.message ?? "HTTP \(status)",
            params: envelope.params,
            requestId: envelope.requestId,
            retryAfter: kind == .rateLimited ? retryAfter : nil
        )
    }

    static func connection(_ error: any Error) -> ControlResellError {
        ControlResellError(
            kind: .connection,
            code: "connection_error",
            message: "Could not reach the ControlResell API: \(error.localizedDescription)",
            underlyingError: error
        )
    }

    /// The ``ControlResellError`` behind an error thrown by the generated client, which wraps what the middleware throws in a `ClientError`.
    public static func unwrapping(_ error: any Error) -> any Error {
        if let error = error as? ControlResellError { return error }
        if let clientError = error as? ClientError, let inner = clientError.underlyingError as? ControlResellError { return inner }
        return error
    }

    /// The error a `ClientError` wraps, at any depth.
    static func rootCause(_ error: any Error) -> any Error {
        var current = error
        while let clientError = current as? ClientError { current = clientError.underlyingError }
        return current
    }

    /// The parts of the API's error envelope.
    struct Envelope {
        var code: String?
        var message: String?
        var params: [String: String] = [:]
        var requestId: String?

        init(_ body: Data?) {
            guard let body, !body.isEmpty,
                  let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let error = root["error"] as? [String: Any]
            else { return }
            code = error["code"] as? String
            message = error["message"] as? String
            requestId = error["requestId"] as? String
            if let map = error["params"] as? [String: Any] {
                for (name, value) in map { params[name] = (value as? String) ?? String(describing: value) }
            }
        }
    }
}
