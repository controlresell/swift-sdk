import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ControlResell

@Suite(.serialized)
struct ControlResellTests {
    @Test func aCallSendsTheKeyAndTheUserAgentToTheBaseURL() async throws {
        let (client, transport, _) = try makeClient { _ in json(meJSON) }
        let me = try await client.call { try await $0.getMe().ok.body.json }
        #expect(me.username == "seller")
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.path == "/api/public/v1/me")
        #expect(request.header("Authorization") == "Bearer \(testKey)")
        #expect(request.header("User-Agent") == "controlresell-swift/1.0.0")
        #expect(request.header("Idempotency-Key") == nil)
    }

    @Test func publishPriceDropAndRepublishCarryScheduledAt() async throws {
        let receipt = "{\"itemId\":7,\"action\":\"publish\",\"accountIds\":[\"3f2c1c0e-5b7a-4a3e-9d1e-0a1b2c3d4e5f\"],\"scheduledAt\":\"2026-11-01T09:30:00Z\"}"
        let (client, transport, _) = try makeClient { _ in json(receipt, status: 202) }
        let at = Date(timeIntervalSince1970: 1_793_525_400) // 2026-11-01T09:30:00Z
        let account = "3f2c1c0e-5b7a-4a3e-9d1e-0a1b2c3d4e5f"

        let published = try await client.call {
            try await $0.publishItem(.init(path: .init(id: 7), body: .json(.init(accountIds: [account], scheduledAt: at)))).accepted.body.json
        }
        _ = try await client.call {
            try await $0.dropItemPrice(.init(path: .init(id: 7), body: .json(.init(_type: "percent", value: "10", scheduledAt: at)))).accepted
        }
        _ = try await client.call {
            try await $0.republishItem(.init(path: .init(id: 7), body: .json(.init(scheduledAt: at)))).accepted
        }

        #expect(published.scheduledAt == at)
        #expect(transport.requests.count == 3)
        for request in transport.requests {
            let body = try #require(JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any])
            let sent = try #require(body["scheduledAt"] as? String)
            #expect(ISO8601DateFormatter().date(from: sent) == at)
        }
    }

    @Test func theKeyComesFromTheEnvironmentWhenNoneIsGivenAndIsRequired() throws {
        let previous = ProcessInfo.processInfo.environment["CONTROLRESELL_API_KEY"]
        defer { if let previous { setenv("CONTROLRESELL_API_KEY", previous, 1) } else { unsetenv("CONTROLRESELL_API_KEY") } }
        unsetenv("CONTROLRESELL_API_KEY")
        #expect(throws: ControlResellConfigurationError.self) { try ControlResell(transport: StubTransport { _ in json(meJSON) }) }
        setenv("CONTROLRESELL_API_KEY", "cr_env", 1)
        _ = try ControlResell(transport: StubTransport { _ in json(meJSON) })
    }

    @Test func anErrorIsTypedByItsStatusWithItsCodeParamsAndRequestId() async throws {
        let (client, transport, _) = try makeClient { _ in apiError("item_not_found", status: 404) }
        do {
            _ = try await client.call { try await $0.getItem(.init(path: .init(id: 1))).ok.body.json }
            Issue.record("expected an error")
        } catch let error as ControlResellError {
            #expect(error.kind == .notFound)
            #expect(error.status == 404)
            #expect(error.code == "item_not_found")
            #expect(error.requestId == "req-1")
            #expect(error.params["field"] == "name")
            #expect(!String(describing: error).contains(testKey))
            #expect(!error.localizedDescription.contains(testKey))
        }
        #expect(transport.requests.count == 1)
    }

    @Test func theGeneratedClientWrapsTheErrorInAClientErrorThatUnwrappingReads() async throws {
        let (client, _, _) = try makeClient { _ in apiError("item_not_found", status: 404) }
        do {
            _ = try await client.api.getItem(.init(path: .init(id: 1)))
            Issue.record("expected an error")
        } catch {
            #expect(error is ClientError)
            let unwrapped = try #require(ControlResellError.unwrapping(error) as? ControlResellError)
            #expect(unwrapped.kind == .notFound)
        }
    }

    @Test(arguments: [
        (400, ControlResellError.Kind.badRequest), (401, .authentication), (402, .paymentRequired), (403, .permissionDenied),
        (409, .conflict), (422, .unprocessableEntity), (500, .server), (418, .other),
    ])
    func eachStatusHasItsKindAndAnUnknownCodeIsKept(status: Int, kind: ControlResellError.Kind) async throws {
        let (client, _, _) = try makeClient { _ in apiError("a_code_from_the_future", status: status) }
        do {
            _ = try await client.call { try await $0.getMe().ok }
            Issue.record("expected an error")
        } catch let error as ControlResellError {
            #expect(error.kind == kind)
            #expect(error.code == "a_code_from_the_future")
        }
    }

    @Test func anErrorWithoutTheEnvelopeIsStillTyped() async throws {
        let (client, _, _) = try makeClient { _ in json("<html>forbidden</html>", status: 403) }
        do {
            _ = try await client.call { try await $0.getMe().ok }
            Issue.record("expected an error")
        } catch let error as ControlResellError {
            #expect(error.kind == .permissionDenied)
            #expect(error.code == "http_403")
            #expect(error.requestId == nil)
        }
    }

    @Test func aRateLimitIsRetriedAfterRetryAfterThenSucceeds() async throws {
        let calls = Counter()
        let (client, _, delays) = try makeClient { _ in
            calls.next() == 1 ? apiError("rate_limited", status: 429, headers: ["Retry-After": "2"]) : json(emptyAccounts)
        }
        _ = try await client.call { try await $0.listAccounts(.init()).ok }
        #expect(calls.value == 2)
        #expect(delays.all == [2])
    }

    @Test func aRateLimitAfterTheRetriesIsARateLimitedErrorWithItsRetryAfter() async throws {
        let calls = Counter()
        let (client, _, _) = try makeClient { _ in _ = calls.next(); return apiError("rate_limited", status: 429, headers: ["Retry-After": "3"]) }
        do {
            _ = try await client.call { try await $0.listAccounts(.init()).ok }
            Issue.record("expected an error")
        } catch let error as ControlResellError {
            #expect(error.kind == .rateLimited)
            #expect(error.retryAfter == 3)
        }
        #expect(calls.value == 3) // the first attempt and two retries
    }

    @Test func withoutRetryAfterTheDelayGrowsExponentiallyWithSomeJitter() async throws {
        let (client, _, delays) = try makeClient { _ in apiError("unavailable", status: 503) }
        _ = try? await client.call { try await $0.getMe().ok }
        let all = delays.all
        #expect(all.count == 2)
        #expect((0.01...0.015).contains(all[0]))
        #expect((0.02...0.025).contains(all[1]))
    }

    @Test(arguments: [502, 503, 504])
    func aGatewayOrAvailabilityErrorIsRetried(status: Int) async throws {
        let calls = Counter()
        let (client, _, _) = try makeClient { _ in calls.next() == 1 ? apiError("x", status: status) : json(meJSON) }
        _ = try await client.call { try await $0.getMe().ok }
        #expect(calls.value == 2)
    }

    @Test func aPostKeepsTheSameGeneratedIdempotencyKeyAndBodyAcrossRetries() async throws {
        let calls = Counter()
        let (client, transport, _) = try makeClient { _ in calls.next() < 3 ? apiError("unavailable", status: 503) : json(itemJSON(7), status: 201) }
        let item = try await client.call { try await $0.createItem(.init(body: .json(.init(name: "Jacket")))).created.body.json }
        #expect(item.id == 7)
        let requests = transport.requests
        #expect(requests.count == 3)
        let key = try #require(requests[0].header("Idempotency-Key"))
        #expect(requests.allSatisfy { $0.header("Idempotency-Key") == key })
        let uuid = try #require(UUID(uuidString: key))
        #expect(uuid.uuidString.dropFirst(14).first == "4") // UUID v4
        #expect(requests.allSatisfy { $0.body == requests[0].body })
        #expect(requests[0].body.contains("Jacket"))
    }

    @Test func twoCallsGetTwoDifferentKeys() async throws {
        let (client, transport, _) = try makeClient { _ in json(itemJSON(7), status: 201) }
        for name in ["a", "b"] { _ = try await client.call { try await $0.createItem(.init(body: .json(.init(name: name)))).created } }
        let keys = transport.requests.compactMap { $0.header("Idempotency-Key") }
        #expect(keys.count == 2 && keys[0] != keys[1])
    }

    @Test func theKeyChosenByTheCallerIsUsedOnEveryAttempt() async throws {
        let calls = Counter()
        let (client, transport, _) = try makeClient { _ in calls.next() < 2 ? apiError("unavailable", status: 502) : json(itemJSON(7), status: 201) }
        try await IdempotencyKey.with("import-42") {
            _ = try await client.call { try await $0.createItem(.init(body: .json(.init(name: "a")))).created }
        }
        #expect(transport.requests.allSatisfy { $0.header("Idempotency-Key") == "import-42" })
        _ = try await client.call { try await $0.createItem(.init(body: .json(.init(name: "b")))).created }
        #expect(transport.requests.last?.header("Idempotency-Key") != "import-42")
    }

    @Test func a500IsNeverRetried() async throws {
        let (client, transport, _) = try makeClient { _ in apiError("internal_error", status: 500) }
        for _ in 0..<2 {
            do {
                _ = try await client.call { try await $0.createItem(.init(body: .json(.init(name: "a")))).created }
                Issue.record("expected an error")
            } catch let error as ControlResellError { #expect(error.kind == .server) }
        }
        #expect(transport.requests.count == 2)
    }

    @Test func a409IdempotencyInProgressIsRetriedButAnother409IsNot() async throws {
        let calls = Counter()
        let (client, _, delays) = try makeClient { _ in calls.next() == 1 ? apiError("idempotency_in_progress", status: 409) : json(itemJSON(7), status: 201) }
        _ = try await client.call { try await $0.createItem(.init(body: .json(.init(name: "a")))).created }
        #expect(calls.value == 2)
        #expect(delays.all.count == 1)

        let others = Counter()
        let (other, _, _) = try makeClient { _ in _ = others.next(); return apiError("idempotency_key_reused", status: 409) }
        do {
            _ = try await other.call { try await $0.createItem(.init(body: .json(.init(name: "a")))).created }
            Issue.record("expected an error")
        } catch let error as ControlResellError {
            #expect(error.kind == .conflict)
            #expect(error.code == "idempotency_key_reused")
        }
        #expect(others.value == 1)
    }

    @Test func theWebhookTestIsOnlyRetriedOnA429() async throws {
        let id = "7a5ae2bb-6c64-4f2c-8a6c-3d3a5e3fb9f1"
        let calls = Counter()
        let (client, _, _) = try makeClient { _ in _ = calls.next(); return apiError("unavailable", status: 503) }
        _ = try? await client.call { try await $0.testWebhookEndpoint(.init(path: .init(id: id))).ok }
        #expect(calls.value == 1)

        let limited = Counter()
        let (second, _, _) = try makeClient { _ in limited.next() == 1 ? apiError("rate_limited", status: 429, headers: ["Retry-After": "0"]) : json("{}") }
        _ = try? await second.call { try await $0.testWebhookEndpoint(.init(path: .init(id: id))).ok }
        #expect(limited.value == 2)

        let network = Counter()
        let (third, _, _) = try makeClient { _ in _ = network.next(); throw URLError(.networkConnectionLost) }
        do {
            _ = try await third.call { try await $0.testWebhookEndpoint(.init(path: .init(id: id))).ok }
            Issue.record("expected an error")
        } catch let error as ControlResellError { #expect(error.kind == .connection) }
        #expect(network.value == 1)
    }

    @Test func aNetworkErrorIsRetriedThenBecomesAConnectionErrorWithoutTheKey() async throws {
        let calls = Counter()
        let (client, _, _) = try makeClient { _ in _ = calls.next(); throw URLError(.cannotConnectToHost) }
        do {
            _ = try await client.call { try await $0.getMe().ok }
            Issue.record("expected an error")
        } catch let error as ControlResellError {
            #expect(error.kind == .connection)
            #expect(error.status == nil)
            #expect(error.underlyingError is URLError)
            #expect(!String(describing: error).contains(testKey))
        }
        #expect(calls.value == 3)

        let again = Counter()
        let (recovered, _, _) = try makeClient { _ in
            if again.next() == 1 { throw URLError(.networkConnectionLost) }
            return json(meJSON)
        }
        let me = try await recovered.call { try await $0.getMe().ok.body.json }
        #expect(me.username == "seller")
    }

    @Test func retriesCanBeTurnedOff() async throws {
        let (client, transport, _) = try makeClient(maxRetries: 0) { _ in apiError("unavailable", status: 503) }
        _ = try? await client.call { try await $0.getMe().ok }
        #expect(transport.requests.count == 1)
    }

    @Test func anItemIsReadWithItsAmountAsADecimalStringAndUnknownValuesAreTolerated() async throws {
        let (client, _, _) = try makeClient { _ in json(itemJSON(42, sex: "A_SEX_ADDED_LATER")) }
        let item = try await client.call { try await $0.getItem(.init(path: .init(id: 42))).ok.body.json }
        #expect(item.id == 42)
        #expect(item.name == "Jacket")
        #expect(item.sku == nil)
        #expect(item.estimatedPrice?.amount == "12.50") // never a float
        #expect(item.estimatedPrice?.currency == "EUR")
        #expect(item.purchasePrice == nil)
        #expect(item.sex == "A_SEX_ADDED_LATER")
        #expect(item.createdAt == Date(timeIntervalSince1970: 1_792_490_400))
    }

    @Test func paginationFollowsTheCursorOverTwoPagesWithTheSameFilters() async throws {
        let (client, transport, _) = try makeClient { request in
            request.query.contains("cursor=c1") ? json(itemPageJSON(next: nil, 3)) : json(itemPageJSON(next: "c1", 1, 2))
        }
        var ids: [Int64] = []
        for try await item in client.allItems(sold: false, limit: 2) { ids.append(item.id) }
        #expect(ids == [1, 2, 3])
        let requests = transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.query.contains("sold=false") && $0.query.contains("limit=2") })
        #expect(!requests[0].query.contains("cursor"))
        #expect(requests[1].query.contains("cursor=c1"))
    }

    @Test func paginationThrowsTheTypedErrorOfAFailingPage() async throws {
        let (client, _, _) = try makeClient { request in
            request.query.contains("cursor=c1") ? apiError("item_not_found", status: 404) : json(itemPageJSON(next: "c1", 1))
        }
        var ids: [Int64] = []
        do {
            for try await item in client.allItems() { ids.append(item.id) }
            Issue.record("expected an error")
        } catch let error as ControlResellError { #expect(error.kind == .notFound) }
        #expect(ids == [1])
    }

    @Test func theGenericPaginateStopsWhenThereIsNoNextCursor() async throws {
        let asked = Box<[String?]>([])
        let stream = paginate { (cursor: String?) async throws -> (items: [Int], nextCursor: String?) in
            asked.mutate { $0.append(cursor) }
            return cursor == nil ? ([1], "n") : ([2], "")
        }
        var all: [Int] = []
        for try await value in stream { all.append(value) }
        #expect(all == [1, 2])
        #expect(asked.value == [nil, "n"])
    }

    @Test func theWebhookTestPathIsRecognised() {
        #expect(ControlResellMiddleware.isWebhookTest(path: "/api/public/v1/webhook-endpoints/abc/test"))
        #expect(!ControlResellMiddleware.isWebhookTest(path: "/api/public/v1/webhook-endpoints/abc/recover"))
        #expect(!ControlResellMiddleware.isWebhookTest(path: "/api/public/v1/items/42/publish"))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult func next() -> Int { lock.withLock { count += 1; return count } }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}
