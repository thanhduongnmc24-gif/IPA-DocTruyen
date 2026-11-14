import Foundation

enum DriveInputParser {
    /// Tự động nhận diện và bóc tách Folder ID ngay cả khi người dùng dán nguyên đường link Google Drive
    /// Ví dụ: https://drive.google.com/drive/folders/1aBcDeFgHiJkLmNoPqRsTuVwXyZ?usp=sharing -> 1aBcDeFgHiJkLmNoPqRsTuVwXyZ
    static func extractFolderId(from rawInput: String) -> String {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

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

        // Trường hợp 3: Người dùng dán trực tiếp chuỗi ID (loại bỏ tham số thừa sau dấu ? hoặc / nếu có)
        let firstPart = trimmed.components(separatedBy: "?").first ?? trimmed
        let cleanId = firstPart.components(separatedBy: "/").last ?? firstPart
        return cleanId.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
