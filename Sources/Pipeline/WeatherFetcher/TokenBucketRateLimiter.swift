import Foundation

/// Token bucket rate limiter for smoothing API request rates.
/// Refills tokens at a steady rate (tokensPerSecond) up to a maximum burst size.
/// Callers `await consume()` which sleeps only when the bucket is empty.
actor TokenBucketRateLimiter {
    private var tokens: Double
    private let maxTokens: Double
    private let refillRate: Double // tokens per second
    private var lastRefill: ContinuousClock.Instant

    /// - Parameters:
    ///   - tokensPerSecond: Steady-state throughput (e.g. 8 for 8 req/s)
    ///   - burst: Maximum tokens that can accumulate (allows short bursts)
    init(tokensPerSecond: Double, burst: Int) {
        self.refillRate = tokensPerSecond
        self.maxTokens = Double(burst)
        self.tokens = Double(burst) // start full
        self.lastRefill = .now
    }

    /// Wait until a token is available, then consume it.
    func consume() async {
        refill()

        if tokens >= 1.0 {
            tokens -= 1.0
            return
        }

        // Calculate how long until 1 token is available
        let deficit = 1.0 - tokens
        let waitSeconds = deficit / refillRate
        let waitMs = Int(waitSeconds * 1000) + 1 // +1ms to avoid rounding issues

        try? await Task.sleep(for: .milliseconds(waitMs))
        refill()
        tokens = max(0, tokens - 1.0)
    }

    private func refill() {
        let now = ContinuousClock.now
        let elapsed = now - lastRefill
        let secondsElapsed = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let newTokens = secondsElapsed * refillRate
        tokens = min(maxTokens, tokens + newTokens)
        lastRefill = now
    }
}
