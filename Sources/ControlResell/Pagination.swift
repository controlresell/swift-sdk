import Foundation

/// Iterates every item of a list, page after page: `fetchPage` reads one page from a cursor (nil for the first one) and must pass the
/// same filters each time. The cursor is opaque: it is only given back. Cancelling the iteration stops the reads.
public func paginate<Element: Sendable>(
    _ fetchPage: @escaping @Sendable (_ cursor: String?) async throws -> (items: [Element], nextCursor: String?)
) -> AsyncThrowingStream<Element, any Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                var cursor: String?
                repeat {
                    let page = try await fetchPage(cursor)
                    for item in page.items { continuation.yield(item) }
                    cursor = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
                    try Task.checkCancellation()
                } while cursor != nil
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// `all<Things>(...)`: every item of a list as an `AsyncThrowingStream`, with the filters of the matching `list<Things>` operation
/// (`limit` is the size of each page). For a page at a time, call the operation of ``ControlResell/api`` with `cursor`.
extension ControlResell {
    public func allAccounts(limit: Int32? = nil) -> AsyncThrowingStream<Components.Schemas.Account, any Error> {
        paginate { cursor in
            let page = try await call { try await $0.listAccounts(.init(query: .init(limit: limit, cursor: cursor))).ok.body.json }
            return (page.data, page.nextCursor)
        }
    }

    public func allItems(sold: Bool? = nil, accountId: String? = nil, limit: Int32? = nil) -> AsyncThrowingStream<Components.Schemas.Item, any Error> {
        paginate { cursor in
            let page = try await call {
                try await $0.listItems(.init(query: .init(limit: limit, cursor: cursor, sold: sold, accountId: accountId))).ok.body.json
            }
            return (page.data, page.nextCursor)
        }
    }

    public func allItemFavorites(itemId: Int64, from: Date? = nil, to: Date? = nil, limit: Int32? = nil) -> AsyncThrowingStream<Components.Schemas.Favorite, any Error> {
        paginate { cursor in
            let page = try await call {
                try await $0.listItemFavorites(.init(path: .init(id: itemId), query: .init(limit: limit, cursor: cursor, from: from, to: to))).ok.body.json
            }
            return (page.data, page.nextCursor)
        }
    }

    public func allFavorites(from: Date? = nil, to: Date? = nil, accountId: String? = nil, itemId: Int64? = nil, limit: Int32? = nil) -> AsyncThrowingStream<Components.Schemas.Favorite, any Error> {
        paginate { cursor in
            let page = try await call {
                try await $0.listFavorites(.init(query: .init(limit: limit, cursor: cursor, from: from, to: to, accountId: accountId, itemId: itemId))).ok.body.json
            }
            return (page.data, page.nextCursor)
        }
    }

    public func allConversations(
        unread: Bool? = nil, accountId: String? = nil, from: Date? = nil, to: Date? = nil,
        buyerId: String? = nil, itemId: Int64? = nil, offerStatus: String? = nil, limit: Int32? = nil
    ) -> AsyncThrowingStream<Components.Schemas.Conversation, any Error> {
        paginate { cursor in
            let page = try await call {
                try await $0.listConversations(.init(query: .init(
                    limit: limit, cursor: cursor, unread: unread, accountId: accountId, from: from, to: to,
                    buyerId: buyerId, itemId: itemId, offerStatus: offerStatus
                ))).ok.body.json
            }
            return (page.data, page.nextCursor)
        }
    }

    public func allConversationMessages(conversationId: String, from: Date? = nil, to: Date? = nil, limit: Int32? = nil) -> AsyncThrowingStream<Components.Schemas.Message, any Error> {
        paginate { cursor in
            let page = try await call {
                try await $0.listConversationMessages(.init(path: .init(id: conversationId), query: .init(limit: limit, cursor: cursor, from: from, to: to))).ok.body.json
            }
            return (page.data, page.nextCursor)
        }
    }

    public func allCustomers(from: Date? = nil, to: Date? = nil, accountId: String? = nil, limit: Int32? = nil) -> AsyncThrowingStream<Components.Schemas.Customer, any Error> {
        paginate { cursor in
            let page = try await call {
                try await $0.listCustomers(.init(query: .init(limit: limit, cursor: cursor, from: from, to: to, accountId: accountId))).ok.body.json
            }
            return (page.data, page.nextCursor)
        }
    }

    public func allOrders(
        bucket: String? = nil, platform: String? = nil, accountId: String? = nil, from: Date? = nil, to: Date? = nil, limit: Int32? = nil
    ) -> AsyncThrowingStream<Components.Schemas.Order, any Error> {
        paginate { cursor in
            let page = try await call {
                try await $0.listOrders(.init(query: .init(limit: limit, cursor: cursor, bucket: bucket, platform: platform, accountId: accountId, from: from, to: to))).ok.body.json
            }
            return (page.data, page.nextCursor)
        }
    }

    public func allWebhookDeliveries(endpointId: String, status: String? = nil, type: String? = nil, limit: Int32? = nil) -> AsyncThrowingStream<Components.Schemas.WebhookDelivery, any Error> {
        paginate { cursor in
            let page = try await call {
                try await $0.listWebhookDeliveries(.init(path: .init(id: endpointId), query: .init(status: status, _type: type, limit: limit, cursor: cursor))).ok.body.json
            }
            return (page.data, page.nextCursor)
        }
    }

    /// The events of the last 7 days (or since `since`), to catch up after an outage.
    public func allWebhookEvents(since: Date? = nil, type: String? = nil, limit: Int32? = nil) -> AsyncThrowingStream<Components.Schemas.WebhookEvent, any Error> {
        paginate { cursor in
            let page = try await call {
                try await $0.listWebhookEvents(.init(query: .init(since: since, _type: type, limit: limit, cursor: cursor))).ok.body.json
            }
            return (page.data, page.nextCursor)
        }
    }
}
