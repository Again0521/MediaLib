import Foundation
import MediaLibCore

enum ServerRateLimitScope: String, CaseIterable, Sendable {
    case publicProbe
    case loginClient
    case loginIdentity
    case refreshClient
    case refreshCredential
    case unauthenticated
    case apiRead
    case artworkRead
    case mediaProbe
    case mediaStream
    case authenticatedMutation
}

struct ServerRateLimitPolicy: Equatable, Sendable {
    let capacity: Double
    let refillPerSecond: Double

    init(capacity: Int, refillPerSecond: Double) {
        precondition(capacity > 0 && refillPerSecond > 0)
        self.capacity = Double(capacity)
        self.refillPerSecond = refillPerSecond
    }
}

struct ServerRateLimitDecision: Equatable, Sendable {
    let isAllowed: Bool
    let retryAfterSeconds: Int

    static let allowed = Self(isAllowed: true, retryAfterSeconds: 0)
}

/// 进程内分级令牌桶。桶键在进入字典前使用进程级随机盐做 BLAKE2b-256，
/// 因此内存快照中不会出现用户名、客户端地址、会话或设备标识明文。
/// 条目带 TTL 和硬上限，攻击者不能用大量伪造身份让限速器自身无限增长。
final class ServerRequestRateLimiter: @unchecked Sendable {
    typealias Clock = @Sendable () -> TimeInterval

    static let productionPolicies: [ServerRateLimitScope: ServerRateLimitPolicy] = [
        .publicProbe: .init(capacity: 120, refillPerSecond: 2),
        .loginClient: .init(capacity: 12, refillPerSecond: 1.0 / 30.0),
        .loginIdentity: .init(capacity: 6, refillPerSecond: 1.0 / 60.0),
        .refreshClient: .init(capacity: 30, refillPerSecond: 0.5),
        .refreshCredential: .init(capacity: 8, refillPerSecond: 0.2),
        .unauthenticated: .init(capacity: 40, refillPerSecond: 1),
        .apiRead: .init(capacity: 180, refillPerSecond: 3),
        // 海报墙会在一次导航中并行读取数十张已授权图片。它们与结构化
        // API 读取分桶，避免正常切页耗尽页面/API 的交互预算，同时仍保留
        // 有界的按主体与按客户端保护。
        .artworkRead: .init(capacity: 120, refillPerSecond: 2),
        .mediaProbe: .init(capacity: 12, refillPerSecond: 0.1),
        .mediaStream: .init(capacity: 240, refillPerSecond: 4),
        .authenticatedMutation: .init(capacity: 30, refillPerSecond: 0.5)
    ]

    private struct BucketKey: Hashable {
        let scope: ServerRateLimitScope
        let digest: String
    }

    private struct Bucket {
        var tokens: Double
        var updatedAt: TimeInterval
        var lastSeenAt: TimeInterval
    }

    private let lock = NSLock()
    private let policies: [ServerRateLimitScope: ServerRateLimitPolicy]
    private let clock: Clock
    private let salt: String
    private let entryTTL: TimeInterval
    private let maximumEntryCount: Int
    private var buckets: [BucketKey: Bucket] = [:]
    private var evaluationCount = 0

    init(
        policies: [ServerRateLimitScope: ServerRateLimitPolicy] = productionPolicies,
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
        salt: String = ServerTokenSecurity.generateToken(),
        entryTTL: TimeInterval = 30 * 60,
        maximumEntryCount: Int = 10_000
    ) {
        precondition(Set(policies.keys) == Set(ServerRateLimitScope.allCases))
        precondition(!salt.isEmpty && entryTTL > 0 && maximumEntryCount >= 100)
        self.policies = policies
        self.clock = clock
        self.salt = salt
        self.entryTTL = entryTTL
        self.maximumEntryCount = maximumEntryCount
    }

    func evaluate(
        scope: ServerRateLimitScope,
        identityComponents: [String],
        cost: Double = 1
    ) -> ServerRateLimitDecision {
        precondition(!identityComponents.isEmpty && cost > 0)
        let framedIdentity = identityComponents.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let digest = ServerTokenSecurity.digest("\(salt)|\(framedIdentity)") ?? "digest-failure"
        let key = BucketKey(scope: scope, digest: digest)
        let now = clock()
        let policy = policies[scope]!

        lock.lock()
        defer { lock.unlock() }
        evaluationCount &+= 1
        if evaluationCount % 128 == 0 || buckets.count > maximumEntryCount {
            prune(now: now)
        }

        var bucket = buckets[key] ?? Bucket(
            tokens: policy.capacity,
            updatedAt: now,
            lastSeenAt: now
        )
        let elapsed = max(now - bucket.updatedAt, 0)
        bucket.tokens = min(policy.capacity, bucket.tokens + elapsed * policy.refillPerSecond)
        bucket.updatedAt = now
        bucket.lastSeenAt = now

        guard bucket.tokens >= cost else {
            buckets[key] = bucket
            if buckets.count > maximumEntryCount { prune(now: now) }
            let missing = cost - bucket.tokens
            return ServerRateLimitDecision(
                isAllowed: false,
                retryAfterSeconds: max(Int(ceil(missing / policy.refillPerSecond)), 1)
            )
        }
        bucket.tokens -= cost
        buckets[key] = bucket
        if buckets.count > maximumEntryCount { prune(now: now) }
        return .allowed
    }

    var retainedEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buckets.count
    }

    private func prune(now: TimeInterval) {
        buckets = buckets.filter { now - $0.value.lastSeenAt <= entryTTL }
        guard buckets.count > maximumEntryCount else { return }
        let overflow = buckets.count - maximumEntryCount
        let oldestKeys = buckets.sorted {
            if $0.value.lastSeenAt != $1.value.lastSeenAt {
                return $0.value.lastSeenAt < $1.value.lastSeenAt
            }
            if $0.key.scope.rawValue != $1.key.scope.rawValue {
                return $0.key.scope.rawValue < $1.key.scope.rawValue
            }
            return $0.key.digest < $1.key.digest
        }.prefix(overflow).map(\.key)
        for key in oldestKeys { buckets.removeValue(forKey: key) }
    }
}
