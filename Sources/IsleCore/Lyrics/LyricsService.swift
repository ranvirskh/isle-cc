import CryptoKit
import Foundation

/// Disk cache for resolved lyrics. Stores the words together with the resolution state.
public final class LyricsCache: @unchecked Sendable {
    struct Entry: Codable {
        var payload: LyricsPayload
        var storedAt: Date
        var expiresAt: Date?
    }

    public let directory: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()
    /// "Unavailable" is remembered for a day so the same track is not re-requested on every play.
    public var unavailableTTL: TimeInterval = 24 * 3600
    /// After a network failure the miss is only remembered briefly.
    public var failureTTL: TimeInterval = 10 * 60
    public var foundTTL: TimeInterval = 90 * 24 * 3600

    public init(directory: URL) {
        self.directory = directory
    }

    public static func key(for query: LyricsQuery) -> String {
        let duration = query.duration.map { String(Int(($0 / 2).rounded())) } ?? "-"
        let raw = [LyricsNormalizer.fold(query.artist), LyricsNormalizer.fold(query.title),
                   LyricsNormalizer.fold(query.album), duration].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func url(_ key: String) -> URL {
        directory.appendingPathComponent(key + ".json")
    }

    public func load(_ query: LyricsQuery, now: Date = Date()) -> LyricsPayload? {
        lock.lock()
        defer { lock.unlock() }
        let file = url(Self.key(for: query))
        guard let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        if let expires = entry.expiresAt, expires <= now {
            try? fileManager.removeItem(at: file)
            return nil
        }
        return entry.payload
    }

    public func store(_ payload: LyricsPayload, for query: LyricsQuery, afterFailure: Bool = false, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let ttl: TimeInterval
        if payload.kind == .unavailable { ttl = afterFailure ? failureTTL : unavailableTTL } else { ttl = foundTTL }
        let entry = Entry(payload: payload, storedAt: now, expiresAt: now.addingTimeInterval(ttl))
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: url(Self.key(for: query)), options: .atomic)
        } catch {
            // A cache that cannot be written is only a slower cache.
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            try? fileManager.removeItem(at: file)
        }
    }

    public var entryCount: Int {
        ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.count
    }
}

/// Owns lyric lookups for the current track: consent gate, sanity check, cache, debounce, cancellation.
@MainActor
public final class LyricsService {
    public struct Snapshot: Equatable {
        public var trackIdentity: String
        public var state: LyricsState
        /// Raw words, kept for a possible full-lyrics panel. Presentation filtering never touches these.
        public var payload: LyricsPayload?

        public init(trackIdentity: String, state: LyricsState, payload: LyricsPayload?) {
            self.trackIdentity = trackIdentity
            self.state = state
            self.payload = payload
        }
    }

    private let resolver: LyricsResolver
    private let cache: LyricsCache?
    private let debounce: TimeInterval
    /// Consent gate. Checked before every lookup; when false nothing is sent.
    public var isEnabled: () -> Bool
    public var onChange: ((Snapshot?) -> Void)?
    public private(set) var snapshot: Snapshot?
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(resolver: LyricsResolver, cache: LyricsCache?, debounce: TimeInterval = 0.4, isEnabled: @escaping () -> Bool) {
        self.resolver = resolver
        self.cache = cache
        self.debounce = debounce
        self.isEnabled = isEnabled
    }

    private func publish(_ new: Snapshot?) {
        guard new != snapshot else { return }
        snapshot = new
        onChange?(new)
    }

    /// Call on every track change (nil when nothing is playing). Cancels any lookup for the previous track.
    public func trackChanged(_ track: TrackInfo?) {
        task?.cancel()
        task = nil
        generation += 1
        let myGeneration = generation

        guard let track, !track.isEmpty, isEnabled() else {
            publish(nil)
            return
        }
        let identity = track.identity
        guard MetadataSanity.namesASong(title: track.title, artist: track.artist) else {
            publish(Snapshot(trackIdentity: identity, state: .unavailable, payload: nil))
            return
        }
        let query = LyricsQuery(track: track)
        if let cached = cache?.load(query) {
            publish(Snapshot(trackIdentity: identity, state: LyricsState(payload: cached), payload: cached))
            return
        }
        publish(Snapshot(trackIdentity: identity, state: .loading, payload: nil))

        let resolver = self.resolver, cache = self.cache, debounce = self.debounce
        task = Task { [weak self] in
            // Debounce: skipping through tracks must not fire a request per track.
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, self.generation == myGeneration, self.isEnabled() else { return }
            let outcome: LyricsResolver.Outcome
            do {
                outcome = try await resolver.resolve(query)
            } catch {
                return // cancelled: a newer track owns the state now
            }
            guard !Task.isCancelled, self.generation == myGeneration else { return }
            cache?.store(outcome.payload, for: query, afterFailure: outcome.hadFailure)
            self.publish(Snapshot(trackIdentity: identity, state: LyricsState(payload: outcome.payload), payload: outcome.payload))
        }
    }

    /// Duration often arrives after the title. Re-run only if nothing useful was found yet.
    public func refreshIfUnresolved(_ track: TrackInfo?) {
        guard let track, let snapshot, snapshot.trackIdentity == track.identity else {
            trackChanged(track)
            return
        }
        if case .loading = snapshot.state { return }
    }

    /// Consent withdrawn: stop everything and drop what is shown.
    public func disable() {
        task?.cancel()
        task = nil
        generation += 1
        publish(nil)
    }

    /// For tests: waits for the in-flight lookup, if any.
    public func waitForIdle() async {
        await task?.value
    }
}
