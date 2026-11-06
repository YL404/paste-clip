import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Link thumbnails, downscaled to the list row size and cached on disk.
/// Only the few images on screen are kept in memory, and only while the panel is open.
final class ThumbnailCache {
    static let size = ThumbnailDownloader.size

    private let directory: URL
    private let memory = NSCache<NSURL, NSImage>()
    private var tasks: [URL: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Links without a usable image; retried after the next launch.
    private var failed: Set<URL> = []
    /// Links whose download hit a network error; retried the next time the panel opens.
    private var networkFailed: Set<URL> = []
    var onLoad: ((URL) -> Void)?

    init() throws {
        directory = try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "PasteClip/Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 32
    }

    /// Returns the cached thumbnail, or nil and starts fetching it. `onLoad` fires when it arrives.
    func image(for link: URL) -> NSImage? {
        if let image = memory.object(forKey: link as NSURL) {
            return image
        }
        let file = fileURL(for: link)
        if let image = NSImage(contentsOf: file) {
            image.size = Self.size
            memory.setObject(image, forKey: link as NSURL)
            return image
        }
        fetch(link, to: file)
        return nil
    }

    /// Cancels in-flight downloads and drops decoded images.
    func reset() {
        for entry in tasks.values {
            entry.task.cancel()
        }
        tasks = [:]
        networkFailed = []
        memory.removeAllObjects()
    }

    private func fetch(_ link: URL, to file: URL) {
        guard tasks[link] == nil, !failed.contains(link), !networkFailed.contains(link) else { return }
        let id = UUID()
        let task = Task { @concurrent [weak self] in
            let result = await ThumbnailDownloader.download(link, to: file)
            await self?.finish(link, id: id, result: result)
        }
        tasks[link] = (id, task)
    }

    private func finish(_ link: URL, id: UUID, result: ThumbnailDownloader.Result) {
        guard tasks[link]?.id == id else { return }
        tasks[link] = nil
        switch result {
        case .saved: onLoad?(link)
        case .failed: failed.insert(link)
        case .networkError: networkFailed.insert(link)
        case .cancelled: break
        }
    }

    private func fileURL(for link: URL) -> URL {
        let digest = SHA256.hash(data: Data(link.absoluteString.utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined() + ".png")
    }
}

/// Network and image work for thumbnails. Runs off the main actor.
nonisolated enum ThumbnailDownloader {
    static let size = CGSize(width: 48, height: 27)

    enum Result {
        case saved, failed, networkError, cancelled
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) PasteClip/0.1",
        ]
        return URLSession(configuration: configuration)
    }()

    private static let maxPageBytes = 512 * 1024
    private static let maxImageBytes = 10 * 1024 * 1024

    @concurrent
    static func download(_ link: URL, to file: URL) async -> Result {
        do {
            let imageURL: URL
            if let videoID = Link.youTubeVideoID(link), let url = Link.youTubeThumbnailURL(videoID: videoID) {
                imageURL = url
            } else {
                // Meta tags live in <head>, so stop reading once it ends.
                guard let (page, pageURL) = try await fetch(link, limit: maxPageBytes, stopAfter: Array("</head>".utf8)),
                      let url = Link.previewImageURL(inHTML: String(decoding: page, as: UTF8.self), baseURL: pageURL)
                else { return .failed }
                imageURL = url
            }
            guard let (image, _) = try await fetch(imageURL, limit: maxImageBytes),
                  let png = makeThumbnail(from: image)
            else { return .failed }
            try png.write(to: file, options: .atomic)
            return .saved
        } catch {
            if Task.isCancelled { return .cancelled }
            // Timeouts, TLS and connection errors are usually transient; worth another try later.
            return error is URLError ? .networkError : .failed
        }
    }

    /// Downloads a 2xx response body and returns it with the final URL after redirects.
    /// Without `marker`, bodies over `limit` are rejected. With a lowercase ASCII `marker`,
    /// reading stops after the marker (matched case-insensitively) or at `limit`.
    private static func fetch(_ url: URL, limit: Int, stopAfter marker: [UInt8]? = nil) async throws -> (Data, URL)? {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let finalURL = response.url ?? url
        if marker == nil, http.expectedContentLength > limit { return nil }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            // `| 0x20` lowercases ASCII letters and leaves "<", "/" and ">" unchanged.
            if let marker, byte == marker.last, data.count >= marker.count,
               zip(data.suffix(marker.count), marker).allSatisfy({ $0 | 0x20 == $1 }) {
                break
            }
            if data.count >= limit {
                return marker == nil ? nil : (data, finalURL)
            }
        }
        return (data, finalURL)
    }

    /// Scales and center-crops the image to the row thumbnail size at 2x, encoded as PNG to keep transparency.
    static func makeThumbnail(from data: Data) -> Data? {
        let width = Int(size.width * 2)
        let height = Int(size.height * 2)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int, sourceWidth > 0,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int, sourceHeight > 0
        else { return nil }

        // Decode only as many pixels as the crop needs, so large images never load at full size.
        let scale = min(1, max(Double(width) / Double(sourceWidth), Double(height) / Double(sourceHeight)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((Double(max(sourceWidth, sourceHeight)) * scale).rounded(.up)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let fill = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let drawWidth = Double(image.width) * fill
        let drawHeight = Double(image.height) * fill
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (Double(width) - drawWidth) / 2, y: (Double(height) - drawHeight) / 2,
            width: drawWidth, height: drawHeight
        ))
        guard let cropped = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, cropped, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
