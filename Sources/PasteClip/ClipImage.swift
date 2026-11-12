import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A copied image, normalized to PNG so identical images always hash the same.
/// Multi-frame formats such as GIF keep only their first frame.
struct ClipImage {
    let png: Data
    let width: Int
    let height: Int
    var digest: Data {
        /// The file name is computed from the same bytes that are stored.
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
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        png = output as Data
        width = cgImage.width
        height = cgImage.height
    }
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
    func store(_ image: ClipImage) throws -> Data {
        let digest = image.digest
        let file = fileURL(digest: digest)
        guard !FileManager.default.fileExists(atPath: file.path) else { return digest }
        try image.png.write(to: file, options: .atomic)
        return digest
    }

    func data(digest: Data) -> Data? {
        try? Data(contentsOf: fileURL(digest: digest))
    }

    /// Removes files no longer referenced by any clip. Called after rows are deleted.
    func removeOrphanedFiles(referencedBy digests: Set<Data>) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "png" {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.count == 64, let digest = Self.digest(fromHex: name), !digests.contains(digest) else { continue }
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
