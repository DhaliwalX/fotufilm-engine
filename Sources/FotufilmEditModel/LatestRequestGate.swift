/// Monotonic request tokens for work where only the newest result may be accepted.
///
/// Cancellation can take effect only at safe boundaries inside a renderer. The token is the
/// second line of defence: even if an older operation reaches its return point, it cannot publish
/// after a newer request has been issued.
public struct LatestRequestGate: Sendable {
    private var current: UInt64 = 0

    public init() {}

    /// Issues a token and invalidates every token issued before it.
    @discardableResult
    public mutating func issue() -> UInt64 {
        current &+= 1
        return current
    }

    /// Whether a result carrying `token` still belongs to the newest request.
    public func accepts(_ token: UInt64) -> Bool {
        token == current
    }

    /// Invalidates outstanding work without issuing a usable replacement token.
    public mutating func invalidate() {
        current &+= 1
    }
}
