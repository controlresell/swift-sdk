import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import ControlResell

/// What the stub saw of a request.
struct Seen: Sendable {
    var method: HTTPRequest.Method
    var path: String
    var headers: [String: String]
    var body: String

    func header(_ name: String) -> String? { headers[name.lowercased()] }
    var query: String { path.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? "" }
}

/// A `ClientTransport` that answers from a function and records every request.
final class StubTransport: ClientTransport, @unchecked Sendable {
    typealias Answer = @Sendable (Seen) throws -> (HTTPResponse, HTTPBody?)
    private let lock = NSLock()
    private var seen: [Seen] = []
    private let answer: Answer

    init(_ answer: @escaping Answer) { self.answer = answer }

    var requests: [Seen] { lock.withLock { seen } }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        var headers: [String: String] = [:]
        for field in request.headerFields { headers[field.name.canonicalName] = field.value }
        var text = ""
        if let body { text = String(decoding: try await Data(collecting: body, upTo: 1_000_000), as: UTF8.self) }
        let entry = Seen(method: request.method, path: request.path ?? "", headers: headers, body: text)
        lock.withLock { seen.append(entry) }
        return try answer(entry)
    }
}

/// Records the delays the middleware asks to wait, without waiting.
final class Delays: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    var all: [TimeInterval] { lock.withLock { values } }
    func record(_ seconds: TimeInterval) { lock.withLock { values.append(seconds) } }
}

func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> (HTTPResponse, HTTPBody?) {
    var response = HTTPResponse(status: .init(code: status))
    response.headerFields[.contentType] = "application/json"
    for (name, value) in headers { response.headerFields[HTTPField.Name(name)!] = value }
    return (response, HTTPBody(text))
}

func apiError(_ code: String, status: Int, headers: [String: String] = [:]) -> (HTTPResponse, HTTPBody?) {
    json("{\"error\":{\"code\":\"\(code)\",\"message\":\"m\",\"params\":{\"field\":\"name\"},\"requestId\":\"req-1\"}}", status: status, headers: headers)
}

let testKey = "cr_test_secret"

func makeClient(maxRetries: Int = 2, _ answer: @escaping StubTransport.Answer) throws -> (ControlResell, StubTransport, Delays) {
    let transport = StubTransport(answer)
    let delays = Delays()
    let retry = RetryPolicy(maxRetries: maxRetries, baseDelay: 0.01, maxDelay: 5)
    let middleware = ControlResellMiddleware(apiKey: testKey, retry: retry, sleep: { delays.record($0) })
    let client = try ControlResell(apiKey: testKey, baseURL: URL(string: "https://api.test")!, middleware: middleware, retry: retry, transport: transport)
    return (client, transport, delays)
}

func itemJSON(_ id: Int, sex: String = "WOMEN") -> String {
    """
    {"id":\(id),"name":"Jacket","sku":null,"description":null,"photos":[],"categoryId":null,"brandId":null,"sizeId":null,\
    "colorIds":[],"state":null,"sex":"\(sex)","labels":[],"sold":false,"materialIds":[],"enumValues":[],"attributes":[],\
    "customFields":[],"estimatedPrice":{"amount":"12.50","currency":"EUR"},"purchasePrice":null,"purchaseDate":null,\
    "sellingPrice":null,"sellingDate":null,"createdAt":"2026-10-20T10:00:00Z","updatedAt":"2026-10-20T10:00:00Z","unknownField":1}
    """
}

func itemPageJSON(next: String?, _ ids: Int...) -> String {
    "{\"data\":[\(ids.map { itemJSON($0) }.joined(separator: ","))],\"nextCursor\":\(next.map { "\"\($0)\"" } ?? "null")}"
}

let meJSON = "{\"id\":1,\"username\":\"seller\",\"currency\":\"EUR\"}"
let emptyAccounts = "{\"data\":[],\"nextCursor\":null}"
