import Foundation

struct DriveItem: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let name: String
    let mimeType: String
    let modifiedTime: String?
    let thumbnailLink: String?
    var coverUrl: String?

    var isFolder: Bool {
        mimeType == "application/vnd.google-apps.folder"
    }

    var isTextFile: Bool {
        name.lowercased().hasSuffix(".txt")
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
            return "Gemini 3.5 Flash Lite (Ưu tiên)"
        case .flash31Lite:
            return "Gemini 3.1 Flash Lite (Dự phòng Quota)"
        }
    }

    var shortBadge: String {
        switch self {
        case .flash35Lite:
            return "3.5 Flash Lite"
        case .flash31Lite:
            return "3.1 Flash Lite"
        }
    }

    /// Danh sách model ID thử lần lượt để đảm bảo tương thích mọi endpoint của Google Gemini API
    /// và tự động chuyển xuống 3.1 Flash Lite khi hết quota (429 / RESOURCE_EXHAUSTED).
    var candidateEndpointModels: [String] {
        switch self {
        case .flash35Lite:
            return [
                "gemini-3.5-flash-lite",
                "gemini-3.5-flash-lite-preview",
                "gemini-2.5-flash-lite"
            ]
        case .flash31Lite:
            return [
                "gemini-3.1-flash-lite",
                "gemini-3.1-flash-lite-preview",
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
4. Tuyệt đối KHÔNG cắt bớt tình tiết, KHÔNG thêm lời bình luận hay giải thích ở đầu hoặc cuối. Chỉ trả về đúng nội dung chương truyện đã biên tập hoàn chỉnh.
"""
}
