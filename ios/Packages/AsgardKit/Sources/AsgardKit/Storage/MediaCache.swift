import Foundation

/// Decrypted attachments on disk, protected until first unlock so the
/// notification extension can show image previews.
public enum MediaCache {
    static func url(_ id: UUID) -> URL { AppGroup.mediaCacheURL.appending(path: id.lower) }

    public static func data(for id: UUID) -> Data? { try? Data(contentsOf: url(id)) }

    public static func fileURL(for id: UUID) -> URL? {
        let u = url(id)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    public static func store(_ data: Data, for id: UUID) {
        try? data.write(to: url(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public static func move(from: UUID, to: UUID) {
        try? FileManager.default.moveItem(at: url(from), to: url(to))
    }

    public static func remove(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }

    public static func clear() {
        try? FileManager.default.removeItem(at: AppGroup.mediaCacheURL)
    }

    public static var totalBytes: Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: AppGroup.mediaCacheURL, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
