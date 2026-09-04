/// A memo table that forgets: past `limit` entries the least recently used one goes, so a cache
/// keyed on continuous parameters — a custom film's curve under a slider, an aged roll at every
/// year of a drag — holds a working set rather than every value the session ever asked for.
///
/// Not thread-safe on its own; every table in the engine already sits behind its own lock, and
/// this stays inside it.
public struct BoundedCache<Key: Hashable, Value> {
    public let limit: Int
    private var values: [Key: Value] = [:]
    /// Keys from least to most recently used.
    private var recency: [Key] = []

    public init(limit: Int) {
        precondition(limit > 0, "a cache that holds nothing is a cache of nothing")
        self.limit = limit
    }

    public var count: Int { values.count }

    /// Every value held, in no particular order.
    public var allValues: Dictionary<Key, Value>.Values { values.values }

    /// The value for `key`, and a note that it was wanted just now.
    public mutating func value(for key: Key) -> Value? {
        guard let found = values[key] else { return nil }
        touch(key)
        return found
    }

    /// Keeps `value` under `key`, letting the least recently used entry go when the table is full.
    public mutating func insert(_ value: Value, for key: Key) {
        if values.updateValue(value, forKey: key) != nil {
            touch(key)
            return
        }
        recency.append(key)
        while values.count > limit, let oldest = recency.first {
            recency.removeFirst()
            values[oldest] = nil
        }
    }

    public mutating func removeAll() {
        values.removeAll()
        recency.removeAll()
    }

    private mutating func touch(_ key: Key) {
        guard let place = recency.lastIndex(of: key), place != recency.count - 1 else { return }
        recency.remove(at: place)
        recency.append(key)
    }
}
