import Foundation

struct DriveItem: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var name: String
    let mimeType: String
    let modifiedTime: String?
    let thumbnailLink: String?
    var coverUrl: String?

    var isFolder: Bool {
        mimeType == "application/vnd.google-apps.folder"
    }

    var isTextFile: Bool {
        name.lowercased().hasSuffix(".txt") || mimeType.lowercased() == "text/plain"
    }

    var isImageFile: Bool {
        let lowerName = name.lowercased()
        let lowerMime = mimeType.lowercased()
        return lowerMime.hasPrefix("image/") ||
            lowerName.hasSuffix(".png") ||
            lowerName.hasSuffix(".jpg") ||
            lowerName.hasSuffix(".jpeg") ||
            lowerName.hasSuffix(".webp") ||
            lowerName.hasSuffix(".gif") ||
            lowerName.hasSuffix(".bmp")
    }

    var cleanChapterName: String {
        if let customTitle = LocalChapterStorage.shared.customTitle(for: id),
           !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customTitle
        }
        if name.lowercased().hasSuffix(".txt") {
            return String(name.dropLast(4))
        }
        return name
    }
}

struct DriveListResponse: Codable {
    let nextPageToken: String?
    let files: [DriveItem]?
    let error: DriveAPIErrorDetail?
}

struct DriveAPIErrorDetail: Codable {
    let code: Int?
    let message: String?
}

struct FolderNode: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let name: String
}

struct StoryReadingState: Codable, Equatable {
    var folderId: String
    var folderStack: [FolderNode]
    var chapterId: String
    var chapterName: String
    var paragraphIndex: Int
    var savedAt: TimeInterval
}

struct PersistedReadingData: Codable {
    var states: [String: StoryReadingState]
    var lastReadingFolderId: String?
}

enum GeminiModelChoice: String, CaseIterable, Identifiable, Codable {
    case flash35Lite = "3.5-flash-lite"
    case flash31Lite = "3.1-flash-lite"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flash35Lite:
            return "Gemini 2.5 / 3.5 Flash Lite (Ưu tiên)"
        case .flash31Lite:
            return "Gemini 3.1 Flash Lite (Dự phòng Quota)"
        }
    }

    var shortBadge: String {
        switch self {
        case .flash35Lite:
            return "Flash Lite (Chính)"
        case .flash31Lite:
            return "3.1 Flash Lite"
        }
    }

    /// Chỉ sử dụng các endpoint thực tế hoạt động trên Google AI Studio để không bị lỗi 404 làm chậm/ngắt luồng dịch
    var candidateEndpointModels: [String] {
        switch self {
        case .flash35Lite:
            return [
                "gemini-2.5-flash-lite",
                "gemini-2.5-flash",
                "gemini-2.0-flash"
            ]
        case .flash31Lite:
            return [
                "gemini-3.1-flash-lite-preview",
                "gemini-2.5-flash-lite",
                "gemini-2.0-flash-lite"
            ]
        }
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable, Codable {
    case sepia = "sepia"
    case pearl = "pearl"
    case midnight = "midnight"
    case jade = "jade"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sepia: return "Giấy cổ"
        case .pearl: return "Trắng ngọc"
        case .midnight: return "Đêm tối"
        case .jade: return "Xanh dịu"
        }
    }
}

enum DefaultPrompts {
    static let standardNovelPolish = """
Bạn là một biên tập viên và dịch giả tiểu thuyết tiên hiệp, kiếm hiệp, huyền huyễn, cổ trang kỳ cựu.
Nhiệm vụ của bạn là biên tập và viết lại (cover/dịch mượt) đoạn truyện convert từ tiếng Trung sang tiếng Việt dưới đây sao cho:
1. Câu văn trôi chảy, tự nhiên, thuần Việt, giàu nhịp điệu văn học nhưng giữ nguyên 100% cốt truyện, tình tiết, tên riêng (nhân vật, địa danh, chiêu thức, cảnh giới, chức tước).
2. Sắp xếp lại trật tự từ ngữ bị ngược do ngữ pháp Hán-Việt convert (ví dụ: "đánh một trận từ đầu đến đuôi thua trận về sau" -> "sau trận đại bại thảm hại từ đầu đến cuối", "bọn hắn chỗ mắng người" -> "người mà bọn họ mắng chửi", "mũi như treo mật, mày như mũi kiếm" -> "sống mũi cao thẳng như treo mật, hàng mày sắc bén như kiếm").
3. Sửa các từ bị viết lách luật hoặc lỗi chính tả (ví dụ: "ch.ết" -> "chết", "tựu liền" -> "ngay cả").
4. Giữ dòng tiêu đề chương bắt đầu bằng "Chương [số]: [Tên chương đã dịch mượt]". Tuyệt đối KHÔNG cắt bớt tình tiết, KHÔNG thêm lời bình luận hay giải thích ở đầu hoặc cuối. Chỉ trả về đúng nội dung chương truyện đã biên tập hoàn chỉnh.
"""
}

enum ChapterTitleExtractor {
    /// Quét trong vài dòng đầu của nội dung chương (tối đa 10 dòng không rỗng đầu tiên),
    /// dòng nào bắt đầu bằng chữ "Chương" thì lấy nguyên câu đó làm tên chương.
    static func extractUpdatedChapterTitle(
        rawFileName: String,
        storyTitle: String,
        chapterContent: String
    ) -> String? {
        let nonEmptyLines = chapterContent.components(separatedBy: .newlines)
            .map { line -> String in
                var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let r = s.range(of: #"^[#*>\-\s]+"#, options: .regularExpression) {
                    s.removeSubrange(r)
                }
                return s.replacingOccurrences(of: "**", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        let topLines = nonEmptyLines.prefix(10)

        for line in topLines {
            let folded = line.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
            if folded.hasPrefix("chuong ") || folded.hasPrefix("chuong:") || folded.hasPrefix("chuong\t") {
                // Loại bỏ các ký tự không hợp lệ trong tên file trên Google Drive
                let safeTitle = line
                    .replacingOccurrences(of: "/", with: " - ")
                    .replacingOccurrences(of: "\\", with: " - ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !safeTitle.isEmpty {
                    return safeTitle
                }
            }
        }

        return nil
    }
}
