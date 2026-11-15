import Foundation

enum DriveInputParser {
    /// Kiểm tra xem chuỗi người dùng nhập vào có phải là link Google Apps Script Web App hay không
    static func isAppsScriptUrl(_ rawInput: String) -> Bool {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        return trimmed.contains("script.google.com") ||
            trimmed.contains("script.googleusercontent.com") ||
            trimmed.contains("/macros/s/")
    }

    /// Chuẩn hóa đường link Google Apps Script Web App (tự động đổi /dev sang /exec nếu cần)
    static func normalizeAppsScriptUrl(_ rawInput: String) -> String {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let range = trimmed.range(of: #"https://script\.google\.com/macros/s/[a-zA-Z0-9_-]+/(exec|dev)"#, options: .regularExpression) {
            var matched = String(trimmed[range])
            if matched.hasSuffix("/dev") {
                matched = String(matched.dropLast(4)) + "/exec"
            }
            return matched
        }
        return trimmed
    }

    /// Tự động nhận diện và bóc tách Folder ID ngay cả khi người dùng dán nguyên đường link Google Drive.
    /// Nếu người dùng dán nhầm link Google Apps Script (.../exec) vào ô Folder ID thì trả về chuỗi rỗng ""
    /// để không bao giờ nhận nhầm chữ "exec" làm Folder ID.
    static func extractFolderId(from rawInput: String) -> String {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Chặn trường hợp dán nhầm link Google Apps Script hoặc giá trị rác "exec" / "dev"
        if isAppsScriptUrl(trimmed) {
            return ""
        }
        let lower = trimmed.lowercased()
        if lower == "exec" || lower == "dev" || lower == "edit" || lower == "view" {
            return ""
        }

        // Trường hợp 1: Link dạng /folders/FOLDER_ID
        if let range = trimmed.range(of: #"/folders/([a-zA-Z0-9_-]+)"#, options: .regularExpression) {
            let match = String(trimmed[range])
            return match.replacingOccurrences(of: "/folders/", with: "")
        }

        // Trường hợp 2: Link dạng ?id=FOLDER_ID hoặc &id=FOLDER_ID
        if let components = URLComponents(string: trimmed),
           let idParam = components.queryItems?.first(where: { $0.name == "id" })?.value,
           !idParam.isEmpty {
            return idParam
        }

        // Nếu là một đường link http/https khác không chứa /folders/ và không có ?id= thì không phải Folder ID
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.contains("google.com") {
            return ""
        }

        // Trường hợp 3: Người dùng dán trực tiếp chuỗi ID
        let firstPart = trimmed.components(separatedBy: "?").first ?? trimmed
        let cleanId = (firstPart.components(separatedBy: "/").last ?? firstPart)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleanId.lowercased() == "exec" || cleanId.lowercased() == "dev" || cleanId.count < 8 {
            return ""
        }
        return cleanId
    }
}
