import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A copied image, normalized to PNG so identical images always hash the same.
/// Multi-frame formats such as GIF keep only their first frame.
nonisolated struct ClipImage {
    let png: Data
    let width: Int
    let height: Int
    var digest: Data {
        Data(SHA256.hash(data: png))
    }
    var searchText: String { "图片 \(width)×\(height)" }

    /// Converts the first frame of pasteboard image data to PNG. Returns nil for data
    /// that AppKit cannot decode, or that cannot be encoded as PNG.
    init?(data: Data) {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        var properties: [CFString: Any] = [:]
        if image.size.width > 0, image.size.height > 0 {
            let dpiX = Double(cgImage.width) / Double(image.size.width) * 72
            let dpiY = Double(cgImage.height) / Double(image.size.height) * 72
            if abs(dpiX - 72) > 0.5 || abs(dpiY - 72) > 0.5 {
                properties[kCGImagePropertyDPIWidth] = dpiX
                properties[kCGImagePropertyDPIHeight] = dpiY
            }
        }
        CGImageDestinationAddImage(destination, cgImage, properties.isEmpty ? nil : properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        png = output as Data
        width = cgImage.width
        height = cgImage.height
    }

    /// Scales and center-crops image bytes to `size` at 2x, encoded as PNG to keep transparency.
    static func thumbnailPNG(from data: Data, size: CGSize) -> Data? {
        let width = Int(size.width * 2)
        let height = Int(size.height * 2)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int, sourceWidth > 0,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int, sourceHeight > 0
        else { return nil }
        let scale = min(1, max(Double(width) / Double(sourceWidth), Double(height) / Double(sourceHeight)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((Double(max(sourceWidth, sourceHeight)) * scale).rounded(.up)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let fill = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let drawWidth = Double(image.width) * fill
        let drawHeight = Double(image.height) * fill
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(width) - drawWidth) / 2, y: (Double(height) - drawHeight) / 2,
                                       width: drawWidth, height: drawHeight))
        guard let cropped = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, cropped, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// Decoded row thumbnails. The panel clears this cache when it closes; disk copies survive.
final class ImageThumbnailCache {
    private let cache = NSCache<NSData, NSImage>()

    init() { cache.countLimit = 32 }

    func image(digest: Data, size: CGSize, using storage: ImageStorage) -> NSImage? {
        let key = digest as NSData
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = storage.thumbnail(digest: digest, size: size) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func clear() { cache.removeAllObjects() }
}

/// The original PNGs behind image clips, stored outside the SQLite database so a page
/// of rows never holds image data. Files are named by their content hash and shared.
final class ImageStorage {
    private let directory: URL

    init() throws {
        directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "PasteClip/Images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(digest: Data) -> URL {
        directory.appending(path: digest.map { String(format: "%02x", $0) }.joined() + ".png")
    }

    /// Writes `image` if no file with its hash exists, and returns its digest.
    @discardableResult
    func store(_ image: ClipImage, thumbnail: Data? = nil, thumbnailSize: CGSize = .zero) throws -> Data {
        let digest = image.digest
        let file = fileURL(digest: digest)
        if !FileManager.default.fileExists(atPath: file.path) {
            try image.png.write(to: file, options: .atomic)
        }
        if let thumbnail, thumbnailSize != .zero {
            let thumbFile = thumbnailURL(digest: digest, size: thumbnailSize)
            if !FileManager.default.fileExists(atPath: thumbFile.path) {
                try? thumbnail.write(to: thumbFile, options: .atomic)
            }
        }
        return digest
    }

    func data(digest: Data) -> Data? {
        try? Data(contentsOf: fileURL(digest: digest))
    }

    /// A downscaled copy for list rows, cached on disk. The original PNG is never decoded
    /// at full size just to draw a 96×54 thumbnail.
    func thumbnail(digest: Data, size: CGSize) -> NSImage? {
        let file = thumbnailURL(digest: digest, size: size)
        if let image = NSImage(contentsOf: file) {
            image.size = size
            return image
        }
        guard let data = data(digest: digest),
              let thumbnail = ClipImage.thumbnailPNG(from: data, size: size)
        else { return nil }
        try? thumbnail.write(to: file, options: .atomic)
        let image = NSImage(data: thumbnail)
        image?.size = size
        return image
    }

    /// Opens the stored PNG lazily via file URL without loading raw bytes into heap `Data`.
    func preview(digest: Data) -> (image: NSImage, byteCount: Int)? {
        let file = fileURL(digest: digest)
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
              let byteCount = values.fileSize,
              let image = NSImage(contentsOf: file)
        else { return nil }
        return (image, byteCount)
    }

    private func thumbnailURL(digest: Data, size: CGSize) -> URL {
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name)-thumb-\(Int(size.width))x\(Int(size.height)).png")
    }

    /// Removes files no longer referenced by any clip. Called after rows are deleted.
    func removeOrphanedFiles(referencedBy digests: Set<Data>) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "png" {
            let name = file.deletingPathExtension().lastPathComponent
            let hash = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard hash.count == 64, let digest = Self.digest(fromHex: hash), !digests.contains(digest) else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func digest(fromHex hex: String) -> Data? {
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard next <= hex.endIndex, let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
