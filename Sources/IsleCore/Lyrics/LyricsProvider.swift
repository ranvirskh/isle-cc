import Foundation

public struct HTTPResponse {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// The only door to the network for lyrics. Tests inject a canned transport; the app injects URLSession.
public protocol HTTPTransport: Sendable {
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse
}

public enum LyricsError: Error, Equatable {
    case rateLimited(until: Date)
    case http(Int)
    case badURL
}

/// A lyrics source. A second provider can be added by conforming to this; only LRCLIB is implemented.
public protocol LyricsProvider: Sendable {
    var name: String { get }
    /// Returns nil when the provider has nothing usable for this track. Throws on network failure.
    func lyrics(for query: LyricsQuery) async throws -> LyricsPayload?
}

/// LRCLIB (https://lrclib.net/docs). Free, no account. Sends title, artist, album and duration; never audio.
public final class LRCLIBProvider: LyricsProvider, @unchecked Sendable {
    public let name = "LRCLIB"
    private let transport: HTTPTransport
    private let userAgent: String
    private let baseURL: String
    private let timeout: TimeInterval
    private let requestGap: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var blockedUntil: Date?

    public init(transport: HTTPTransport, userAgent: String, baseURL: String = "https://lrclib.net",
                timeout: TimeInterval = 6, requestGap: TimeInterval = 0.25,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.userAgent = userAgent
        self.baseURL = baseURL
        self.timeout = timeout
        self.requestGap = requestGap
        self.now = now
    }

    private func url(path: String, items: [(String, String)]) -> URL? {
        var components = URLComponents(string: baseURL + path)
        components?.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents leaves "+" unescaped, which servers read as a space.
        let encoded = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encoded
        return components?.url
    }

    private func currentBlock() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return blockedUntil
    }

    private func setBlock(_ until: Date) {
        lock.lock()
        defer { lock.unlock() }
        blockedUntil = until
    }

    private func fetch(_ url: URL) async throws -> [LyricsRecord] {
        if let blocked = currentBlock(), blocked > now() { throw LyricsError.rateLimited(until: blocked) }

        try Task.checkCancellation()
        let response = try await transport.get(url, headers: ["User-Agent": userAgent, "Lrclib-Client": userAgent], timeout: timeout)
        try Task.checkCancellation()

        switch response.status {
        case 200:
            return LyricsRecord.decodeList(response.body)
        case 404:
            return []
        case 429, 503:
            // The docs require honoring Retry-After; the body is not guaranteed to be JSON.
            let header = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
            let seconds = header.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? (response.status == 429 ? 60 : 2)
            let until = now().addingTimeInterval(min(max(seconds, 1), 3600))
            setBlock(until)
            throw LyricsError.rateLimited(until: until)
        default:
            throw LyricsError.http(response.status)
        }
    }

    public func lyrics(for query: LyricsQuery) async throws -> LyricsPayload? {
        var candidates: [LyricsRecord] = []

        // 1. Exact signature lookup (title, artist, album, duration).
        var items: [(String, String)] = [("track_name", query.title), ("artist_name", query.artist)]
        if !query.album.trimmingCharacters(in: .whitespaces).isEmpty { items.append(("album_name", query.album)) }
        if let d = query.duration, d >= 1, d <= 3600 { items.append(("duration", String(Int(d.rounded())))) }
        guard let getURL = url(path: "/api/get", items: items) else { throw LyricsError.badURL }

        var firstError: Error?
        do {
            candidates += try await fetch(getURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LyricsError {
            if case .rateLimited = error { throw error }
            firstError = error
        } catch {
            firstError = error
        }

        if let chosen = LyricsSelector.select(candidates, for: query), chosen.kind == .timed {
            return LyricsSelector.payload(for: chosen, provider: name)
        }

        // 2. Search, so a synced row from another pressing can win over a plain exact match.
        try Task.checkCancellation()
        if requestGap > 0 { try await Task.sleep(nanoseconds: UInt64(requestGap * 1_000_000_000)) }
        let cleaned = TitleCleaner.clean(query.title)
        guard let searchURL = url(path: "/api/search", items: [("track_name", cleaned), ("artist_name", query.artist)]) else {
            throw LyricsError.badURL
        }
        do {
            candidates += try await fetch(searchURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Both requests failed: report the failure. One failed: keep what the other returned.
            if candidates.isEmpty { throw firstError ?? error }
        }

        guard let chosen = LyricsSelector.select(candidates, for: query) else {
            if candidates.isEmpty, let firstError { throw firstError }
            return nil
        }
        let payload = LyricsSelector.payload(for: chosen, provider: name)
        return payload.kind == .unavailable ? nil : payload
    }
}

/// Runs providers in order. A provider that throws counts as an empty result, so the next one still runs.
public struct LyricsResolver: Sendable {
    public struct Outcome: Equatable {
        public var payload: LyricsPayload
        /// True when at least one provider failed (network), so "unavailable" should expire sooner.
        public var hadFailure: Bool
    }

    public let providers: [LyricsProvider]

    public init(providers: [LyricsProvider]) {
        self.providers = providers
    }

    public func resolve(_ query: LyricsQuery) async throws -> Outcome {
        var hadFailure = false
        for provider in providers {
            try Task.checkCancellation()
            do {
                if let payload = try await provider.lyrics(for: query), payload.kind != .unavailable {
                    return Outcome(payload: payload, hadFailure: hadFailure)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                hadFailure = true
            }
        }
        return Outcome(payload: .unavailable, hadFailure: hadFailure)
    }
}
