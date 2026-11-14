import Foundation

struct CachedFolderDiskPayload: Codable {
    let folderId: String
    let isChaptersMode: Bool
    let folders: [DriveItem]
    let chapters: [DriveItem]
    let savedAt: TimeInterval
}

final class LocalChapterStorage {
    static let shared = LocalChapterStorage()

    private let fileManager = FileManager.default
    private let chaptersDirectory: URL
    private let foldersCacheDirectory: URL
    private let metadataFileURL: URL
    private var translatedChapterIds: Set<String> = []
    private let queue = DispatchQueue(label: "com.anhhai.doctruyen.storage", attributes: .concurrent)

    private init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        chaptersDirectory = docs.appendingPathComponent("ChaptersStorage", isDirectory: true)
        foldersCacheDirectory = docs.appendingPathComponent("FoldersDiskCache", isDirectory: true)
        metadataFileURL = docs.appendingPathComponent("TranslatedChaptersMeta.json")

        if !fileManager.fileExists(atPath: chaptersDirectory.path) {
            try? fileManager.createDirectory(at: chaptersDirectory, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: foldersCacheDirectory.path) {
            try? fileManager.createDirectory(at: foldersCacheDirectory, withIntermediateDirectories: true)
        }
        loadMetadata()
    }

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataFileURL),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        translatedChapterIds = Set(ids)
    }

    private func saveMetadata() {
        let array = Array(translatedChapterIds)
        if let data = try? JSONEncoder().encode(array) {
            try? data.write(to: metadataFileURL, options: .atomic)
        }
    }

    private func sanitizedIdentifier(_ rawId: String) -> String {
        let safe = rawId.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        return safe.isEmpty ? "default_root" : safe
    }

    // MARK: - Chapter Content Disk Storage
    func fileURL(for chapterId: String, chapterName: String? = nil) -> URL {
        let fileName = "\(sanitizedIdentifier(chapterId)).txt"
        return chaptersDirectory.appendingPathComponent(fileName)
    }

    func hasLocalFile(for chapterId: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: chapterId).path)
    }

    func isChapterTranslated(_ chapterId: String) -> Bool {
        queue.sync {
            translatedChapterIds.contains(chapterId)
        }
    }

    func readChapterContent(chapterId: String) -> String? {
        let url = fileURL(for: chapterId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Ghi đè nội dung của file cũ bằng nội dung mới (hoặc nội dung đã dịch)
    func overwriteChapterFile(chapterId: String, chapterName: String? = nil, content: String, markAsTranslated: Bool) throws {
        let url = fileURL(for: chapterId, chapterName: chapterName)
        try content.write(to: url, atomically: true, encoding: .utf8)

        queue.async(flags: .barrier) {
            if markAsTranslated {
                self.translatedChapterIds.insert(chapterId)
            }
            self.saveMetadata()
        }
    }

    func removeTranslatedOverride(chapterId: String) {
        let url = fileURL(for: chapterId)
        try? fileManager.removeItem(at: url)
        queue.async(flags: .barrier) {
            self.translatedChapterIds.remove(chapterId)
            self.saveMetadata()
        }
    }

    func translatedCount(in chapters: [DriveItem]) -> Int {
        queue.sync {
            chapters.filter { translatedChapterIds.contains($0.id) }.count
        }
    }

    // MARK: - Folder & Chapter List Disk Cache (Không cần tải lại từ Drive khi mở lại app)
    private func folderCacheFileURL(for folderId: String) -> URL {
        let fileName = "\(sanitizedIdentifier(folderId)).json"
        return foldersCacheDirectory.appendingPathComponent(fileName)
    }

    func saveFolderSnapshotToDisk(
        folderId: String,
        isChaptersMode: Bool,
        folders: [DriveItem],
        chapters: [DriveItem]
    ) {
        guard !folderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let payload = CachedFolderDiskPayload(
            folderId: folderId,
            isChaptersMode: isChaptersMode,
            folders: folders,
            chapters: chapters,
            savedAt: Date().timeIntervalSince1970
        )
        let url = folderCacheFileURL(for: folderId)
        queue.async(flags: .barrier) {
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func loadFolderSnapshotFromDisk(folderId: String) -> CachedFolderDiskPayload? {
        guard !folderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let url = folderCacheFileURL(for: folderId)
        return queue.sync {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(CachedFolderDiskPayload.self, from: data) else {
                return nil
            }
            return decoded
        }
    }

    func clearFolderDiskCache(folderId: String? = nil) {
        queue.async(flags: .barrier) {
            if let folderId {
                let url = self.folderCacheFileURL(for: folderId)
                try? self.fileManager.removeItem(at: url)
            } else {
                try? self.fileManager.removeItem(at: self.foldersCacheDirectory)
                try? self.fileManager.createDirectory(at: self.foldersCacheDirectory, withIntermediateDirectories: true)
            }
        }
    }
}
