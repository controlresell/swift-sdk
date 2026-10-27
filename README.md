# ControlResell Swift SDK

Swift client for the [ControlResell](https://controlresell.com) public API (Swift 6, macOS 13+, iOS 16+, tvOS 16+, watchOS 9+, visionOS 1+; the CI also builds on Linux).

## Install

From the 1.0.0 release (a git tag of this repository), in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/controlresell/swift-sdk", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "ControlResell", package: "swift-sdk")]),
]
```

## Use

```swift
import ControlResell

let controlResell = try ControlResell(apiKey: "cr_live_...") // or set CONTROLRESELL_API_KEY and pass nothing

let me = try await controlResell.call { try await $0.getMe().ok.body.json }
for try await item in controlResell.allItems(sold: false) { print(item.name) }
for try await order in controlResell.allOrders(bucket: "to_send") { print(order.id) } // needs the orders:read scope

// Writes (API key with `items:write` / `conversations:write`).
let item = try await controlResell.call { try await $0.createItem(.init(body: .json(.init(name: "Jacket")))).created.body.json }
_ = try await controlResell.call { try await $0.publishItem(.init(path: .init(id: item.id), body: .json(.init(accountIds: [accountId])))).ok }

// Webhooks (`webhooks:read` / `webhooks:write`); allWebhookEvents catches up the last 7 days.
for try await event in controlResell.allWebhookEvents(type: "item.sold") { print(event._type) }
```

The operations are those of the client generated from the OpenAPI document (`controlResell.api`, named by `operationId`:
`listItems`, `getItem`, `createItem`...), and each answer is an enum: `.ok`, `.created`... read the one you expect, any other status
has already been thrown as an error. `call` runs an operation and throws a `ControlResellError` (the generated client would wrap it
in a `ClientError`). `ControlResell(baseURL:)` points to another environment, `ControlResell(transport:)` chooses what sends the
requests (`URLSessionTransport()` by default). The client is a value type, safe to share between tasks: create one per API key.

To build your own `Client`, add `ControlResellMiddleware(apiKey:)` to its middlewares: it carries everything below.

## Retries

Two retries by default (`RetryPolicy(maxRetries:baseDelay:maxDelay:)`), with an exponential delay and some jitter. A `429` waits for
`Retry-After`. A `502`, `503`, `504` and a network error are retried; a `500` never is. A `409` with the code
`idempotency_in_progress` is retried after a delay; any other `409` is thrown. `POST /webhook-endpoints/{id}/test` sends a real
event: only a `429` is retried.

## Idempotency

Every `POST` carries an `Idempotency-Key` (a UUID v4 the SDK generates), **the same on every retry of the call**, so a retried write
is never applied twice. To choose the key:

```swift
try await IdempotencyKey.with("import-2026-10-26-item-42") {
    _ = try await controlResell.call { try await $0.publishItem(...).ok }
}
```

## Pagination

`all<Things>(...)` iterates a list page after page as an `AsyncThrowingStream` (items, accounts, conversations and their messages,
orders, customers, favorites, webhook deliveries and events), with the same filters on each page. The cursor is opaque. For a page at
a time call `listItems(.init(query: .init(limit: 50, cursor: cursor)))` and read `data` and `nextCursor`; for any other list,
`paginate { cursor in (items, nextCursor) }`.

## Errors

`ControlResellError` has a `kind` (`.badRequest` 400, `.authentication` 401, `.paymentRequired` 402, `.permissionDenied` 403,
`.notFound` 404, `.conflict` 409, `.unprocessableEntity` 422, `.rateLimited` 429 with `retryAfter`, `.server` 5xx, `.other`,
`.connection` when the API could not be reached after the retries), and `status`, `code` (an open string: match the codes you
handle), `message`, `params`, `requestId` (give it to the support). The key never appears in a message.

```swift
do { _ = try await controlResell.call { try await $0.getItem(.init(path: .init(id: 42))).ok } }
catch let error as ControlResellError where error.kind == .notFound { print(error.requestId ?? "") }
```

An amount is `Money { amount, currency }`, `amount` being the decimal **string** of the API (`"12.50"`): parse it with `Decimal(string:)`.
A field or a value the API adds later is tolerated.

## Generated code

`Sources/ControlResell/Generated` is generated from the OpenAPI document of the API by
[apple/swift-openapi-generator](https://github.com/apple/swift-openapi-generator) (version pinned in `scripts/generate.sh`, options in
`openapi-generator-config.yaml`) and committed, so it reads in git; `.spec-sha256` is the hash of the document it comes from. The rest
of `Sources` is written by hand.

```sh
scripts/generate.sh   # from https://api.controlresell.com/api/public/openapi.json, or: scripts/generate.sh path/to/openapi.json
swift test
```

Licensed under the Apache License 2.0.
