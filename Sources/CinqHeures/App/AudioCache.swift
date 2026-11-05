import CinqHeuresCore
import CryptoKit
import Foundation

/// The episodes played lately, kept on disk: the one playing and the last few before it.
///
/// While an episode plays its whole file downloads in the background, from the start, one file at a
/// time. `RangeLoader` reads from it whatever has arrived, so a jump into the part already fetched is
/// instant, even when 5heures.be's server would have taken a minute to answer; once complete, the
/// episode plays from the file, offline too. On iPhone and iPad it only downloads over Wi-Fi (not on a
/// mobile connection, a personal hotspot or in Low Data Mode): an interrupted file carries on later.
final class AudioCache: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = AudioCache()
    static let folder = URL.cachesDirectory.appendingPathComponent("CinqHeures/Episodes")
    /// The one playing and the five before it.
    static let kept = 6

    private let lock = NSLock()
    private var session: URLSession!
    /// The file being fetched now: where it comes from, how much has been written, its full length.
    private var download: (url: URL, task: URLSessionDataTask, handle: FileHandle, written: Int64, total: Int64?)?

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 90
        #if os(iOS)
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        #endif
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    }

    // MARK: Files

    private static func name(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func complete(_ url: URL) -> URL { folder.appendingPathComponent(name(for: url) + ".mp3") }
    private static func partial(_ url: URL) -> URL { folder.appendingPathComponent(name(for: url) + ".part") }

    /// The whole file on disk, if it has been downloaded.
    func file(for url: URL) -> URL? {
        let file = Self.complete(url)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// The file's length, once known (from a complete file or the download's answer).
    func length(of url: URL) -> Int64? {
        if let file = file(for: url) { return (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) }
        return lock.withLock { download?.url == url ? download?.total : nil }
    }

    /// The bytes in `range`, if they're on disk: in the complete file, or already in the part being fetched.
    func read(_ url: URL, range: ClosedRange<Int64>) -> Data? {
        let source: URL
        if let file = file(for: url) {
            source = file
        } else {
            let available = lock.withLock { download?.url == url ? download?.written ?? 0 : 0 }
            guard range.upperBound < available else { return nil }
            source = Self.partial(url)
        }
        guard let handle = try? FileHandle(forReadingFrom: source) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(range.lowerBound))) != nil,
              let data = try? handle.read(upToCount: range.count), data.count == range.count else { return nil }
        return data
    }

    // MARK: Downloading

    /// The episode at `url` is being played: keep it, and fetch the rest of it if it isn't all here.
    func playing(_ url: URL) {
        if let file = file(for: url) {
            // Most recently played first, for `prune`.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            prune(keeping: url)
            return
        }
        lock.withLock {
            if download?.url == url { return }
            stopCurrent()
            start(url)
        }
        prune(keeping: url)
    }

    /// Called with the lock held.
    private func start(_ url: URL) {
        let part = Self.partial(url)
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: part) else { return }
        let written = Int64((try? handle.seekToEnd()) ?? 0)
        var request = URLRequest(url: url)
        request.setValue(SiteClient.userAgent, forHTTPHeaderField: "User-Agent")
        if written > 0 { request.setValue("bytes=\(written)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        download = (url, task, handle, written, nil)
        task.resume()
    }

    /// Called with the lock held. The part stays on disk, to resume from.
    private func stopCurrent() {
        guard let current = download else { return }
        current.task.cancel()
        try? current.handle.close()
        download = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let allowed = lock.withLock { () -> Bool in
            guard var current = download, current.task == dataTask, let http else { return false }
            switch http.statusCode {
            case 206:
                // "bytes 1000-…/52000000": the total is after the slash.
                current.total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) }
            case 200:
                // The whole file from the start (a first request, or a server that ignored the range).
                if current.written > 0 {
                    try? current.handle.truncate(atOffset: 0)
                    current.written = 0
                }
                current.total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            default:
                return false
            }
            download = current
            return true
        }
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            guard var current = download, current.task == dataTask else { return }
            guard (try? current.handle.write(contentsOf: data)) != nil else { stopCurrent(); return }
            current.written += Int64(data.count)
            download = current
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            guard let current = download, current.task == task else { return }
            try? current.handle.close()
            download = nil
            let finished = error == nil && (current.total.map { current.written >= $0 } ?? (current.written > 0))
            // Otherwise the part stays, and carries on from where it stopped next time it's played.
            if finished { try? FileManager.default.moveItem(at: Self.partial(current.url), to: Self.complete(current.url)) }
        }
    }

    // MARK: Keeping it small

    /// Keeps the files of the `kept` episodes played last (and the one playing); deletes the rest.
    private func prune(keeping url: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: Array(keys)) else { return }
        let active = lock.withLock { download.map { Self.partial($0.url) } }
        let current = [Self.complete(url), Self.partial(url)]
        let dated = files.filter { !current.contains($0) && $0 != active }
            .map { ($0, (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        // Parts count as episodes too: one stopped half-way is resumed if it's played again soon.
        for (file, _) in dated.dropFirst(Self.kept - 1) { try? FileManager.default.removeItem(at: file) }
    }

    /// Deletes every file (Réinitialiser › Cache).
    func clear() {
        lock.withLock { stopCurrent() }
        try? FileManager.default.removeItem(at: Self.folder)
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    }
}
