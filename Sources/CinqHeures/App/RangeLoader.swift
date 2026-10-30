import AVFoundation
import CinqHeuresCore
import UniformTypeIdentifiers

/// Feeds AVPlayer an MP3 through small, bounded range requests of our own.
///
/// 5heures.be's audio comes from a Rails app behind Cloudflare, and a file that hasn't been
/// requested for a while is slow the first time: a deep seek can wait a minute or more for the
/// body of its answer, then everything is fast. Left to itself AVFoundation gives up or asks the
/// wrong thing (the whole file, then a seek on the same connection), and the website's own player
/// ends up playing from the start. Here every request is small and is asked again patiently, what
/// has been fetched is kept so jumping back is instant, and the app is told when the server is slow.
final class RangeLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private static let scheme = "cinqhttps"
    private static let chunk: Int64 = 512 * 1024
    /// How far past the playhead to read, so a long episode isn't downloaded whole.
    private static let readAhead: Int64 = 12 * 1024 * 1024

    let queue = DispatchQueue(label: "RangeLoader")
    private let session: URLSession
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var length: Int64?
    private var cache: [Int64: Data] = [:]
    private var cachedURL: URL?
    private var playheadByte: Int64 = 0
    private var bytesPerSecond: Double = 16_000
    /// Requests that have been waiting more than a few seconds. Several run at once, so the server
    /// counts as slow until all of them have answered, not as soon as one does.
    private var slowRequests = Set<UUID>()
    /// At most this much audio is kept in memory (chunks far from the playhead are dropped first).
    private static let maxChunks = 96      // 48 MB

    /// Called (from any thread) when the server starts or stops being slow to answer.
    var onSlowChange: (@Sendable (Bool) -> Void)?

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        super.init()
    }

    /// An asset that reads `url` through this loader. Asking again for the same file keeps what was fetched.
    func asset(for url: URL) -> AVURLAsset {
        lock.withLock {
            if cachedURL != url { cache = [:]; length = nil; cachedURL = url; playheadByte = 0 }
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = Self.scheme
        let asset = AVURLAsset(url: components.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// Drops the audio held in memory (cache reset, or nothing playing any more).
    func clear() {
        lock.withLock { cache = [:]; length = nil; cachedURL = nil; playheadByte = 0 }
    }

    /// Tells the loader where playback is, so it reads only a little way ahead.
    func playhead(seconds: Double, duration: Double) {
        lock.withLock {
            if duration > 60, let length { bytesPerSecond = Double(length) / duration }
            playheadByte = Int64(seconds * bytesPerSecond)
        }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard var components = request.request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              components.scheme == Self.scheme else { return false }
        components.scheme = "https"
        let url = components.url!
        let box = UncheckedBox(request)
        let key = ObjectIdentifier(request)
        let task = Task { [weak self] in
            await self?.serve(box.value, url: url)
            self?.forget(key)
        }
        lock.withLock { tasks[key] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        let task = lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(request)) }
        task?.cancel()
    }

    private func forget(_ key: ObjectIdentifier) {
        _ = lock.withLock { tasks.removeValue(forKey: key) }
    }

    // MARK: Serving

    private func serve(_ request: AVAssetResourceLoadingRequest, url: URL) async {
        do {
            let total = try await totalLength(of: url)
            if let info = request.contentInformationRequest {
                info.contentType = UTType.mp3.identifier
                info.contentLength = total
                info.isByteRangeAccessSupported = true
            }
            if let data = request.dataRequest {
                var offset = data.requestedOffset
                let end = data.requestsAllDataToEndOfResource ? total : min(total, offset + Int64(data.requestedLength))
                let start = offset
                while offset < end {
                    try Task.checkCancellation()
                    // Don't run far ahead of what's being listened to.
                    while offset > max(start, lock.withLock { playheadByte }) + Self.readAhead {
                        try await Task.sleep(for: .milliseconds(500))
                    }
                    let piece = try await piece(at: offset, total: total, url: url)
                    let wanted = Int(min(Int64(piece.count), end - offset))
                    data.respond(with: piece.prefix(wanted))
                    offset += Int64(wanted)
                }
            }
            request.finishLoading()
        } catch is CancellationError {
            // AVPlayer asked for something else: nothing to report.
        } catch {
            request.finishLoading(with: error)
        }
    }

    /// The bytes from `offset` to the end of its chunk, from memory when they were fetched before.
    private func piece(at offset: Int64, total: Int64, url: URL) async throws -> Data {
        let index = offset / Self.chunk
        let skip = Int(offset - index * Self.chunk)
        if let hit = lock.withLock({ cache[index] }) { return hit.dropFirst(skip) }
        let first = index * Self.chunk
        let last = min(total, first + Self.chunk) - 1
        let data = try await fetch(url, range: first...last)
        lock.withLock {
            guard cachedURL == url else { return }
            cache[index] = data
            if cache.count > Self.maxChunks {
                let here = playheadByte / Self.chunk
                for key in cache.keys.sorted(by: { abs($0 - here) > abs($1 - here) }).prefix(cache.count - Self.maxChunks) {
                    cache[key] = nil
                }
            }
        }
        return data.dropFirst(skip)
    }

    private func totalLength(of url: URL) async throws -> Int64 {
        if let length = lock.withLock({ length }) { return length }
        var found: Int64?
        _ = try await fetch(url, range: 0...1) { response in
            found = (response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last).flatMap { Int64($0) }
        }
        guard let found else { throw SiteError.unreadable }
        lock.withLock { length = found }
        return found
    }

    private func markSlow(_ request: UUID, _ isSlow: Bool) {
        let change = lock.withLock { () -> Bool? in
            let before = !slowRequests.isEmpty
            if isSlow { slowRequests.insert(request) } else { slowRequests.remove(request) }
            let after = !slowRequests.isEmpty
            return before == after ? nil : after
        }
        if let change { onSlowChange?(change) }
    }

    /// One range, asked for again for up to about three minutes while the server stalls or errors.
    @discardableResult
    private func fetch(_ url: URL, range: ClosedRange<Int64>,
                       inspecting: ((HTTPURLResponse) -> Void)? = nil) async throws -> Data {
        var lastError: Error = SiteError.unreadable
        let id = UUID()
        let slowTimer = Task { [weak self] in
            try await Task.sleep(for: .seconds(3))
            self?.markSlow(id, true)
        }
        defer {
            slowTimer.cancel()
            markSlow(id, false)
        }
        for attempt in 0..<9 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
            var request = URLRequest(url: url)
            request.setValue(SiteClient.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw SiteError.unreadable }
                guard http.statusCode == 206 || http.statusCode == 200 else { throw SiteError.http(http.statusCode) }
                inspecting?(http)
                // A 200 means the server ignored the range and sent the whole file from the start.
                if http.statusCode == 200 { return data.dropFirst(Int(range.lowerBound)).prefix(range.count) }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
