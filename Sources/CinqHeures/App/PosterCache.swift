import SwiftUI
import CinqHeuresCore
import ImageIO

/// Poster thumbnails for the lists.
///
/// The site's posters are 400 x 600 JPEGs shown here at about 30 x 45 points. `AsyncImage` fetches
/// and scales them on the main thread as rows scroll into view, which on a 120 Hz display drops
/// every other frame. Here each poster is downloaded once (the disk cache keeps it between launches),
/// shrunk to a small bitmap off the main thread, and kept in memory, so a row that comes back into
/// view draws instantly.
final class PosterCache: @unchecked Sendable {
    static let shared = PosterCache()

    static let maxPixels = 150
    private let memory = NSCache<NSString, PlatformImage>()
    private let disk: URLCache
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]

    private init() {
        memory.totalCostLimit = 160 << 20      // bytes of decoded thumbnails kept in memory
        let configuration = URLSessionConfiguration.default
        disk = URLCache(memoryCapacity: 8 << 20, diskCapacity: 300 << 20,
                        directory: Self.folder)
        configuration.urlCache = disk
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpAdditionalHeaders = ["User-Agent": SiteClient.userAgent]
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    /// Where the downloaded posters are kept.
    static let folder = URL.cachesDirectory.appendingPathComponent("CinqHeures/Posters")

    /// Forgets every poster, on disk and in memory.
    func clear() {
        memory.removeAllObjects()
        disk.removeAllCachedResponses()
    }

    private func key(_ url: URL, _ pixels: Int) -> NSString { "\(pixels)|\(url.absoluteString)" as NSString }

    /// The thumbnail if it's already in memory: lets a view show it on its very first frame.
    func cached(_ url: URL?, pixels: Int = PosterCache.maxPixels) -> PlatformImage? {
        url.flatMap { memory.object(forKey: key($0, pixels)) }
    }

    func image(for url: URL, pixels: Int = PosterCache.maxPixels) async -> PlatformImage? {
        let name = key(url, pixels)
        if let hit = memory.object(forKey: name) { return hit }
        let task = lock.withLock { () -> Task<PlatformImage?, Never> in
            if let running = inFlight[name as String] { return running }
            let task = Task<PlatformImage?, Never> { await self.load(url, pixels: pixels) }
            inFlight[name as String] = task
            return task
        }
        let image = await task.value
        lock.withLock { inFlight[name as String] = nil }
        return image
    }

    private func load(_ url: URL, pixels: Int) async -> PlatformImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,      // decode here, not while drawing
                  kCGImageSourceThumbnailMaxPixelSize: pixels,
              ] as CFDictionary)
        else { return nil }
        let image = PlatformImage(thumbnail: thumbnail)
        memory.setObject(image, forKey: key(url, pixels), cost: thumbnail.width * thumbnail.height * 4)
        return image
    }
}
