import CryptoKit
import Foundation

public enum SitePreviewVariant: String, CaseIterable, Sendable {
    case master
    case small
    case medium
    case large

    public var pixelSize: CGSize {
        switch self {
        case .master: CGSize(width: 1_440, height: 900)
        case .small: CGSize(width: 192, height: 120)
        case .medium: CGSize(width: 320, height: 200)
        case .large: CGSize(width: 640, height: 400)
        }
    }

    public static func bestFit(pointSize: CGSize, displayScale: CGFloat) -> SitePreviewVariant {
        let requiredWidth = pointSize.width * max(1, displayScale)
        if requiredWidth <= small.pixelSize.width { return .small }
        if requiredWidth <= medium.pixelSize.width { return .medium }
        if requiredWidth <= large.pixelSize.width { return .large }
        return .master
    }
}

public enum SitePreviewSizing {
    public static func aspectFillSourceRect(imageSize: CGSize, destinationSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, destinationSize.width > 0, destinationSize.height > 0 else { return .zero }
        let destinationAspect = destinationSize.width / destinationSize.height
        let imageAspect = imageSize.width / imageSize.height
        if imageAspect > destinationAspect {
            let width = imageSize.height * destinationAspect
            return CGRect(x: (imageSize.width - width) / 2, y: 0, width: width, height: imageSize.height)
        }
        let height = imageSize.width / destinationAspect
        return CGRect(x: 0, y: (imageSize.height - height) / 2, width: imageSize.width, height: height)
    }
}

public actor SitePreviewCache {
    public let directory: URL
    public let maximumBytes: Int64

    public init(directory: URL? = nil, maximumBytes: Int64 = 50 * 1024 * 1024) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appending(path: "OpenTraffic/Previews", directoryHint: .isDirectory)
        }
        self.maximumBytes = maximumBytes
    }

    public func data(identity: String, variant: SitePreviewVariant) -> Data? {
        try? Data(contentsOf: fileURL(identity: identity, variant: variant))
    }

    public func store(_ data: Data, identity: String, variant: SitePreviewVariant) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(identity: identity, variant: variant), options: .atomic)
        try pruneIfNeeded()
    }

    public func remove(identity: String) {
        let prefix = digest(identity)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix + "-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func totalBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func fileURL(identity: String, variant: SitePreviewVariant) -> URL {
        directory.appending(path: "\(digest(identity))-\(variant.rawValue).png")
    }

    private func digest(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func pruneIfNeeded() throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        var files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        var total = files.reduce(Int64(0)) { value, file in
            value + Int64((try? file.resourceValues(forKeys: keys).fileSize) ?? 0)
        }
        guard total > maximumBytes else { return }
        files.sort {
            let left = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return left < right
        }
        for file in files where total > maximumBytes {
            let size = Int64((try? file.resourceValues(forKeys: keys).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: file)
            total -= size
        }
    }
}
