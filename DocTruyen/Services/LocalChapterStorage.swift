import Foundation

final class LocalChapterStorage {
    static let shared = LocalChapterStorage()

    private let fileManager = FileManager.default
    private let rootDirectory: URL
    private let metadataFileURL: URL
    private var translatedChapterIds: Set<String> = []
    private let queue = DispatchQueue(label: "com.anhhai.doctruyen.storage", attributes: .concurrent)

    private init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        rootDirectory = docs.appendingPathComponent("ChaptersStorage", isDirectory: true)
        metadataFileURL = docs.appendingPathComponent("TranslatedChaptersMeta.json")

        if !fileManager.fileExists(atPath: rootDirectory.path) {
            try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
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

    private func sanitizedFileName(for chapterId: String, chapterName: String?) -> String {
        let safeId = chapterId.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        return "\(safeId).txt"
    }

    func fileURL(for chapterId: String, chapterName: String? = nil) -> URL {
        let fileName = sanitizedFileName(for: chapterId, chapterName: chapterName)
        return rootDirectory.appendingPathComponent(fileName)
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
}
