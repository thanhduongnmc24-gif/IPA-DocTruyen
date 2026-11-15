import Foundation
import UIKit

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
    private let originalChaptersDirectory: URL
    private let foldersCacheDirectory: URL
    private let coversCacheDirectory: URL
    private let metadataFileURL: URL
    private let driveSyncedFileURL: URL
    private let customTitlesFileURL: URL

    private var translatedChapterIds: Set<String> = []
    private var driveSyncedChapterIds: Set<String> = []
    private var customChapterTitles: [String: String] = [:]
    private let coverMemoryCache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "com.anhhai.doctruyen.storage", attributes: .concurrent)

    private init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        chaptersDirectory = docs.appendingPathComponent("ChaptersStorage", isDirectory: true)
        originalChaptersDirectory = docs.appendingPathComponent("OriginalChaptersStorage", isDirectory: true)
        foldersCacheDirectory = docs.appendingPathComponent("FoldersDiskCache", isDirectory: true)
        coversCacheDirectory = docs.appendingPathComponent("CoversDiskCache", isDirectory: true)
        metadataFileURL = docs.appendingPathComponent("TranslatedChaptersMeta.json")
        driveSyncedFileURL = docs.appendingPathComponent("DriveSyncedChaptersMeta.json")
        customTitlesFileURL = docs.appendingPathComponent("CustomChapterTitlesMeta.json")

        for dir in [chaptersDirectory, originalChaptersDirectory, foldersCacheDirectory, coversCacheDirectory] {
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        coverMemoryCache.countLimit = 120
        loadMetadata()
    }

    private func loadMetadata() {
        if let data = try? Data(contentsOf: metadataFileURL),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            translatedChapterIds = Set(ids)
        }
        if let syncedData = try? Data(contentsOf: driveSyncedFileURL),
           let syncedIds = try? JSONDecoder().decode([String].self, from: syncedData) {
            driveSyncedChapterIds = Set(syncedIds)
        }
        if let titleData = try? Data(contentsOf: customTitlesFileURL),
           let titles = try? JSONDecoder().decode([String: String].self, from: titleData) {
            customChapterTitles = titles
        }
    }

    private func saveMetadataLocked() {
        let translatedArray = Array(translatedChapterIds)
        if let data = try? JSONEncoder().encode(translatedArray) {
            try? data.write(to: metadataFileURL, options: .atomic)
        }
        let syncedArray = Array(driveSyncedChapterIds)
        if let syncedData = try? JSONEncoder().encode(syncedArray) {
            try? syncedData.write(to: driveSyncedFileURL, options: .atomic)
        }
        if let titleData = try? JSONEncoder().encode(customChapterTitles) {
            try? titleData.write(to: customTitlesFileURL, options: .atomic)
        }
    }

    private func sanitizedIdentifier(_ rawId: String) -> String {
        let safe = rawId.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        return safe.isEmpty ? "default_root" : safe
    }

    // MARK: - Story Folder Cover Image Cache (Lưu ảnh đại diện của từng bộ truyện trên máy)
    private func coverFileURL(for folderId: String) -> URL {
        let fileName = "\(sanitizedIdentifier(folderId)).jpg"
        return coversCacheDirectory.appendingPathComponent(fileName)
    }

    func hasCachedCoverImage(for folderId: String) -> Bool {
        let key = folderId as NSString
        if coverMemoryCache.object(forKey: key) != nil {
            return true
        }
        return fileManager.fileExists(atPath: coverFileURL(for: folderId).path)
    }

    func loadCachedCoverImage(for folderId: String) -> UIImage? {
        let key = folderId as NSString
        if let mem = coverMemoryCache.object(forKey: key) {
            return mem
        }
        let url = coverFileURL(for: folderId)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else {
            return nil
        }
        coverMemoryCache.setObject(img, forKey: key)
        return img
    }

    func saveCachedCoverImageData(_ data: Data, for folderId: String) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let key = folderId as NSString
        coverMemoryCache.setObject(image, forKey: key)
        let url = coverFileURL(for: folderId)
        let jpegData = image.jpegData(compressionQuality: 0.86) ?? data
        try? jpegData.write(to: url, options: .atomic)
        return image
    }

    func clearCoverCache() {
        coverMemoryCache.removeAllObjects()
        queue.sync(flags: .barrier) {
            try? self.fileManager.removeItem(at: self.coversCacheDirectory)
            try? self.fileManager.createDirectory(at: self.coversCacheDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Custom Chapter Titles
    func customTitle(for chapterId: String) -> String? {
        queue.sync {
            customChapterTitles[chapterId]
        }
    }

    func setCustomTitle(_ newTitle: String?, for chapterId: String) {
        queue.sync(flags: .barrier) {
            if let newTitle, !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.customChapterTitles[chapterId] = newTitle
            } else {
                self.customChapterTitles.removeValue(forKey: chapterId)
            }
            self.saveMetadataLocked()
        }
    }

    // MARK: - Chapter Content Disk Storage
    func fileURL(for chapterId: String, chapterName: String? = nil) -> URL {
        let fileName = "\(sanitizedIdentifier(chapterId)).txt"
        return chaptersDirectory.appendingPathComponent(fileName)
    }

    private func originalFileURL(for chapterId: String) -> URL {
        let fileName = "\(sanitizedIdentifier(chapterId))_raw.txt"
        return originalChaptersDirectory.appendingPathComponent(fileName)
    }

    func hasLocalFile(for chapterId: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: chapterId).path)
    }

    func isChapterTranslated(_ chapterId: String) -> Bool {
        queue.sync {
            translatedChapterIds.contains(chapterId)
        }
    }

    func isChapterSyncedToDrive(_ chapterId: String) -> Bool {
        queue.sync {
            driveSyncedChapterIds.contains(chapterId)
        }
    }

    func markChapterSyncedToDrive(_ chapterId: String, synced: Bool = true) {
        queue.sync(flags: .barrier) {
            if synced {
                self.driveSyncedChapterIds.insert(chapterId)
                self.translatedChapterIds.insert(chapterId)
            } else {
                self.driveSyncedChapterIds.remove(chapterId)
            }
            self.saveMetadataLocked()
        }
    }

    func readChapterContent(chapterId: String) -> String? {
        let url = fileURL(for: chapterId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func saveOriginalChapterIfNeeded(chapterId: String, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = originalFileURL(for: chapterId)
        if !fileManager.fileExists(atPath: url.path) {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func readOriginalChapterContent(chapterId: String) -> String? {
        let url = originalFileURL(for: chapterId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func overwriteChapterFile(
        chapterId: String,
        chapterName: String? = nil,
        content: String,
        markAsTranslated: Bool,
        markAsSyncedToDrive: Bool = false,
        updatedChapterTitle: String? = nil
    ) throws {
        let url = fileURL(for: chapterId, chapterName: chapterName)
        try content.write(to: url, atomically: true, encoding: .utf8)

        queue.sync(flags: .barrier) {
            if markAsTranslated {
                self.translatedChapterIds.insert(chapterId)
                if markAsSyncedToDrive {
                    self.driveSyncedChapterIds.insert(chapterId)
                } else {
                    self.driveSyncedChapterIds.remove(chapterId)
                }
            }
            if let updatedChapterTitle, !updatedChapterTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.customChapterTitles[chapterId] = updatedChapterTitle
            }
            self.saveMetadataLocked()
        }
    }

    func removeTranslatedOverride(chapterId: String) {
        let url = fileURL(for: chapterId)
        try? fileManager.removeItem(at: url)
        queue.sync(flags: .barrier) {
            self.translatedChapterIds.remove(chapterId)
            self.driveSyncedChapterIds.remove(chapterId)
            self.customChapterTitles.removeValue(forKey: chapterId)
            self.saveMetadataLocked()
        }
    }

    func translatedCount(in chapters: [DriveItem]) -> Int {
        queue.sync {
            chapters.filter { translatedChapterIds.contains($0.id) }.count
        }
    }

    func driveSyncedCount(in chapters: [DriveItem]) -> Int {
        queue.sync {
            chapters.filter { driveSyncedChapterIds.contains($0.id) }.count
        }
    }

    func unsyncedTranslatedChapters(in chapters: [DriveItem]) -> [DriveItem] {
        queue.sync {
            chapters.filter { chap in
                guard translatedChapterIds.contains(chap.id) && !driveSyncedChapterIds.contains(chap.id) else {
                    return false
                }
                return fileManager.fileExists(atPath: fileURL(for: chap.id).path)
            }
        }
    }

    // MARK: - Folder & Chapter List Disk Cache
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
        let trimmed = folderId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (!folders.isEmpty || !chapters.isEmpty) else { return }
        let payload = CachedFolderDiskPayload(
            folderId: trimmed,
            isChaptersMode: isChaptersMode,
            folders: folders,
            chapters: chapters,
            savedAt: Date().timeIntervalSince1970
        )
        let url = folderCacheFileURL(for: trimmed)
        queue.async(flags: .barrier) {
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func loadFolderSnapshotFromDisk(folderId: String) -> CachedFolderDiskPayload? {
        let trimmed = folderId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = folderCacheFileURL(for: trimmed)
        return queue.sync {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(CachedFolderDiskPayload.self, from: data),
                  (!decoded.folders.isEmpty || !decoded.chapters.isEmpty) else {
                return nil
            }
            return decoded
        }
    }

    func clearFolderDiskCache(folderId: String? = nil) {
        queue.sync(flags: .barrier) {
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
