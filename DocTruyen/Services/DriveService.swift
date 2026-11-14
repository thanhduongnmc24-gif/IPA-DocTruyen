import Foundation

enum DriveServiceError: LocalizedError {
    case missingCredentials
    case quotaOrAutomatedBlock
    case htmlReturnedInsteadOfText
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Chưa cấu hình Google Drive API Key hoặc Folder ID. Vui lòng kiểm tra trong mục Cài đặt."
        case .quotaOrAutomatedBlock:
            return "Google đang tạm chặn truy vấn tự động. Hãy thử lại sau ít giây hoặc đổi mạng."
        case .htmlReturnedInsteadOfText:
            return "Google trả về HTML thay vì nội dung .txt. Hãy kiểm tra quyền chia sẻ công khai của file hoặc API Key."
        case .apiError(let msg):
            return msg
        }
    }
}

final class DriveService {
    static let shared = DriveService()
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    func fileMediaURLString(fileId: String, apiKey: String) -> String {
        "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media&key=\(apiKey)"
    }

    func listChildren(folderId: String, apiKey: String, extraQuery: String = "") async throws -> [DriveItem] {
        let trimmedFolder = folderId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedFolder.isEmpty, !trimmedKey.isEmpty else {
            throw DriveServiceError.missingCredentials
        }

        var allFiles: [DriveItem] = []
        var pageToken = ""

        repeat {
            let baseQuery = "'\(trimmedFolder)' in parents and trashed=false"
            let finalQuery = extraQuery.isEmpty ? baseQuery : "\(baseQuery) and (\(extraQuery))"

            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "q", value: finalQuery),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,modifiedTime,thumbnailLink)"),
                URLQueryItem(name: "orderBy", value: "name_natural"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "key", value: trimmedKey)
            ]

            if !pageToken.isEmpty {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }

            components.queryItems = queryItems
            guard let url = components.url else {
                throw DriveServiceError.apiError("URL Google Drive không hợp lệ.")
            }

            let (data, response) = try await session.data(from: url)
            let httpResponse = response as? HTTPURLResponse
            let decoded = try? JSONDecoder().decode(DriveListResponse.self, from: data)

            if let statusCode = httpResponse?.statusCode, !(200...299).contains(statusCode) {
                let msg = decoded?.error?.message ?? "Không tải được dữ liệu Google Drive (HTTP \(statusCode))."
                throw DriveServiceError.apiError(msg)
            }

            allFiles.append(contentsOf: decoded?.files ?? [])
            pageToken = decoded?.nextPageToken ?? ""
        } while !pageToken.isEmpty

        return allFiles
    }

    func fetchFolderCover(folderId: String, apiKey: String) async -> String? {
        do {
            let children = try await listChildren(
                folderId: folderId,
                apiKey: apiKey,
                extraQuery: "mimeType contains 'image/'"
            )
            guard let imageFile = children.first(where: { $0.isImageFile }) else {
                return nil
            }
            return imageFile.thumbnailLink ?? fileMediaURLString(fileId: imageFile.id, apiKey: apiKey)
        } catch {
            return nil
        }
    }

    func downloadTextFile(fileId: String, apiKey: String) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw DriveServiceError.missingCredentials
        }

        guard let url = URL(string: fileMediaURLString(fileId: fileId, apiKey: trimmedKey)) else {
            throw DriveServiceError.apiError("URL file không hợp lệ.")
        }

        var request = URLRequest(url: url)
        request.setValue("text/plain,*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)

        if let statusCode = httpResponse?.statusCode, !(200...299).contains(statusCode) {
            if text.contains("automated queries") || text.contains("We're sorry") {
                throw DriveServiceError.quotaOrAutomatedBlock
            }
            if contentType.contains("text/html") {
                throw DriveServiceError.htmlReturnedInsteadOfText
            }
            throw DriveServiceError.apiError(text.isEmpty ? "Không đọc được chương truyện (HTTP \(statusCode))." : text)
        }

        if contentType.contains("text/html") {
            throw DriveServiceError.htmlReturnedInsteadOfText
        }

        return text
    }

    /// Ghi đè trực tiếp nội dung đã dịch lên file gốc trên Google Drive (nếu có OAuth Access Token hoặc quyền ghi)
    func overwriteRemoteDriveFileIfPossible(fileId: String, content: String, apiKey: String, accessToken: String?) async -> Bool {
        var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files/\(fileId)")!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "media"),
            URLQueryItem(name: "key", value: apiKey)
        ]

        guard let url = components.url, let bodyData = content.data(using: .utf8) else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let token = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return true
            }
        } catch {
            return false
        }
        return false
    }
}
