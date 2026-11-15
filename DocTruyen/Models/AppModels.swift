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
4. Giữ dòng tiêu đề chương ở dòng đầu tiên theo định dạng "Chương [số]: [Tên chương đã dịch mượt]". Tuyệt đối KHÔNG cắt bớt tình tiết, KHÔNG thêm lời bình luận hay giải thích ở đầu hoặc cuối. Chỉ trả về đúng nội dung chương truyện đã biên tập hoàn chỉnh.
"""
}

enum ChapterTitleExtractor {
    /// Tự động chuẩn hóa chuỗi tiếng Việt (bỏ dấu, chữ thường, bỏ ký tự đặc biệt) để so sánh tên chương và tên truyện
    static func normalizedComparisonString(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
        let cleaned = folded.replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    /// Kiểm tra xem tên file chương hiện tại có bị trùng với tên truyện (ví dụ: "1000 Cửu Vực Phàm Tiên") hoặc chỉ có số chương mà thiếu tên chương thật hay không
    static func isChapterNameMatchingStoryTitle(rawFileName: String, storyTitle: String) -> Bool {
        let baseName = rawFileName.lowercased().hasSuffix(".txt")
            ? String(rawFileName.dropLast(4))
            : rawFileName

        let normChap = normalizedComparisonString(baseName)
        let normStory = normalizedComparisonString(storyTitle)

        if !normStory.isEmpty && normChap.contains(normStory) {
            return true
        }

        // Bóc phần chữ sau số thứ tự chương (ví dụ "1000 - Cửu Vực Phàm Tiên" -> "cuu vuc pham tien")
        let strippedLeadingNumber = normChap.replacingOccurrences(
            of: "^(chuong|chapter|hoi|q|quyen)?\\s*\\d+\\s*",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // Nếu sau số chương không có tên gì, hoặc trùng một phần lớn với tên bộ truyện
        if strippedLeadingNumber.isEmpty {
            return true
        }
        if !normStory.isEmpty && (normStory.contains(strippedLeadingNumber) || strippedLeadingNumber.contains(normStory)) {
            return true
        }
        return false
    }

    /// Bóc tên chương từ dòng đầu tiên của nội dung chương sau cụm "Chương X:" và ghép thành tên chương chuẩn
    static func extractUpdatedChapterTitle(
        rawFileName: String,
        storyTitle: String,
        chapterContent: String
    ) -> String? {
        let baseName = rawFileName.lowercased().hasSuffix(".txt")
            ? String(rawFileName.dropLast(4))
            : rawFileName

        // Tìm dòng đầu tiên không rỗng trong nội dung đã dịch
        let lines = chapterContent.components(separatedBy: .newlines)
            .map { line -> String in
                var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let r = s.range(of: #"^#{1,6}\s*"#, options: .regularExpression) {
                    s.removeSubrange(r)
                }
                return s.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        guard let firstLine = lines.first else { return nil }

        // Trích xuất tiền tố số thứ tự có sẵn từ tên file gốc (ví dụ: "1000", "0101")
        var filePrefixNumber: String?
        if let matchRange = baseName.range(of: #"^\s*\d+"#, options: .regularExpression) {
            filePrefixNumber = String(baseName[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Kiểm tra xem dòng đầu tiên có dạng "Chương X: Tên chương" hoặc "Chương X - Tên chương" không
        let pattern = #"^(?i)(?:chương|chuong|chapter|hồi|hoi)\s*(\d+)\s*[:\-–—\.]?\s*(.+)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: firstLine, range: NSRange(firstLine.startIndex..., in: firstLine)),
           let numRange = Range(match.range(at: 1), in: firstLine),
           let titleRange = Range(match.range(at: 2), in: firstLine) {

            let chapNumFromText = String(firstLine[numRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let extractedSubtitle = String(firstLine[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !extractedSubtitle.isEmpty, extractedSubtitle.count <= 90 else { return nil }

            // Nếu tên chương hiện tại trùng với tên truyện (VD: "1000 Cửu Vực Phàm Tiên" hoặc "0101 - Cửu Vực Phàm Tiên")
            // hoặc luôn cập nhật khi tìm thấy "Chương X: <Tên chương>" ở dòng đầu tiên:
            if isChapterNameMatchingStoryTitle(rawFileName: rawFileName, storyTitle: storyTitle) {
                if let prefix = filePrefixNumber {
                    return "\(prefix) - \(extractedSubtitle)"
                } else {
                    return "Chương \(chapNumFromText): \(extractedSubtitle)"
                }
            }
        }

        // Trường hợp dòng đầu tiên là tiêu đề ngắn gọn ngay dưới dạng "Định nghĩa về Tiên" (khi AI lược chữ Chương X:)
        if isChapterNameMatchingStoryTitle(rawFileName: rawFileName, storyTitle: storyTitle),
           firstLine.count <= 65,
           !firstLine.hasSuffix("."),
           !firstLine.hasSuffix("!") {
            if let prefix = filePrefixNumber {
                return "\(prefix) - \(firstLine)"
            } else {
                return firstLine
            }
        }

        return nil
    }
}
