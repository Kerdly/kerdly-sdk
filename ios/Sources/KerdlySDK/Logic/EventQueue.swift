import Foundation

/// The persistent queue's in-memory model: events in `seq` order, at most 1,000 events
/// or 1 MB. When it is over either bound the oldest **custom** event is dropped; reserved `$` events
/// are never dropped (so the queue may exceed the bounds when it holds only reserved events).
struct EventQueue: Equatable, Sendable {
    static let defaultMaxEvents = 1_000
    static let defaultMaxBytes = 1_048_576

    let maxEvents: Int
    let maxBytes: Int
    private(set) var events: [QueuedEvent]
    private(set) var totalBytes: Int

    init(events: [QueuedEvent] = [], maxEvents: Int = EventQueue.defaultMaxEvents,
         maxBytes: Int = EventQueue.defaultMaxBytes) {
        self.maxEvents = maxEvents
        self.maxBytes = maxBytes
        self.events = events.sorted { $0.seq < $1.seq }
        self.totalBytes = events.reduce(0) { $0 + $1.size }
    }

    var count: Int { events.count }
    var isEmpty: Bool { events.isEmpty }

    func contains(id: String) -> Bool {
        events.contains { $0.id == id }
    }

    /// Appends (or inserts by `seq`, for a replayed event) and enforces the bounds.
    /// - Returns: the custom events dropped to make room (possibly `event` itself).
    @discardableResult
    mutating func append(_ event: QueuedEvent) -> [QueuedEvent] {
        if let last = events.last, last.seq > event.seq {
            let index = events.firstIndex { $0.seq > event.seq } ?? events.endIndex
            events.insert(event, at: index)
        } else {
            events.append(event)
        }
        totalBytes += event.size
        return enforceBounds()
    }

    /// Removes every event whose id is in `ids`. Returns how many were removed.
    @discardableResult
    mutating func remove(ids: Set<String>) -> Int {
        guard !ids.isEmpty else { return 0 }
        let before = events.count
        events.removeAll { event in
            if ids.contains(event.id) {
                totalBytes -= event.size
                return true
            }
            return false
        }
        return before - events.count
    }

    /// The next batch: up to `maxEvents` events in queue order whose encoded size, plus
    /// `overheadBytes` for the envelope, stays within `maxBytes`. Always at least one event when the
    /// queue is not empty (an oversized one is the server's to refuse with 413).
    func nextBatch(maxEvents: Int, maxBytes: Int, overheadBytes: Int) -> [QueuedEvent] {
        var batch: [QueuedEvent] = []
        var bytes = overheadBytes
        for event in events {
            if batch.count >= max(1, maxEvents) { break }
            let added = event.size + 1
            if !batch.isEmpty && bytes + added > maxBytes { break }
            batch.append(event)
            bytes += added
        }
        return batch
    }

    private mutating func enforceBounds() -> [QueuedEvent] {
        var dropped: [QueuedEvent] = []
        while events.count > maxEvents || totalBytes > maxBytes {
            guard let index = events.firstIndex(where: { !$0.isReserved }) else { break }
            let removed = events.remove(at: index)
            totalBytes -= removed.size
            dropped.append(removed)
        }
        return dropped
    }
}
