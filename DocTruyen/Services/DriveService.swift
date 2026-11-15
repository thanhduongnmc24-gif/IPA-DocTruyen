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

struct DriveOverwriteResult {
    let success: Bool
    let message: String
}

final class DriveService {
    static let shared = DriveService()
    private let session: URLSession

    private var cachedAccessToken: String = ""
    private var cachedAccessTokenExpiry: Date = .distantPast

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 120
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

    /// Tự động xin Access Token mới từ Refresh Token (vĩnh viễn không hết hạn) nếu có cấu hình
    private func resolveValidAccessToken(
        manualAccessToken: String?,
        clientId: String?,
        clientSecret: String?,
        refreshToken: String?
    ) async -> String? {
        let cleanRefresh = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanClientId = clientId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanClientSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !cleanRefresh.isEmpty, !cleanClientId.isEmpty, !cleanClientSecret.isEmpty {
            if !cachedAccessToken.isEmpty && Date() < cachedAccessTokenExpiry {
                return cachedAccessToken
            }

            if let tokenURL = URL(string: "https://oauth2.googleapis.com/token") {
                var req = URLRequest(url: tokenURL)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

                var comps = URLComponents()
                comps.queryItems = [
                    URLQueryItem(name: "client_id", value: cleanClientId),
                    URLQueryItem(name: "client_secret", value: cleanClientSecret),
                    URLQueryItem(name: "refresh_token", value: cleanRefresh),
                    URLQueryItem(name: "grant_type", value: "refresh_token")
                ]
                req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

                if let (data, resp) = try? await session.data(for: req),
                   let http = resp as? HTTPURLResponse,
                   (200...299).contains(http.statusCode),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let newToken = json["access_token"] as? String {
                    let expiresIn = (json["expires_in"] as? Double) ?? 3500
                    cachedAccessToken = newToken
                    cachedAccessTokenExpiry = Date().addingTimeInterval(max(60, expiresIn - 120))
                    return newToken
                }
            }
        }

        let cleanManual = manualAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleanManual.isEmpty ? nil : cleanManual
    }

    /// Ghi đè nội dung đã dịch và cập nhật tên chương lên thẳng Google Drive
    /// Hỗ trợ 2 cơ chế:
    /// 1. Qua Google Apps Script Web App URL (Đơn giản nhất: chỉ cần dán 1 link `https://script.google.com/macros/s/.../exec`, dùng vĩnh viễn không cần OAuth Token)
    /// 2. Qua Google Drive REST API v3 (OAuth Access Token hoặc Refresh Token)
    func overwriteRemoteDriveFile(
        fileId: String,
        newFileName: String?,
        content: String,
        apiKey: String,
        appsScriptWebAppUrl: String?,
        accessToken: String?,
        clientId: String? = nil,
        clientSecret: String? = nil,
        refreshToken: String? = nil
    ) async -> DriveOverwriteResult {
        // ƯU TIÊN 1: Ghi đè qua Google Apps Script Web App Bridge nếu người dùng đã dán link
        if let scriptUrlStr = appsScriptWebAppUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !scriptUrlStr.isEmpty,
           let scriptUrl = URL(string: scriptUrlStr) {
            var request = URLRequest(url: scriptUrl)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            var payload: [String: Any] = [
                "fileId": fileId,
                "content": content
            ]
            if let newFileName, !newFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let finalName = newFileName.lowercased().hasSuffix(".txt") ? newFileName : "\(newFileName).txt"
                payload["newName"] = finalName
            }

            if let body = try? JSONSerialization.data(withJSONObject: payload) {
                request.httpBody = body
                do {
                    let (data, response) = try await session.data(for: request)
                    if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                        let respText = String(data: data, encoding: .utf8) ?? ""
                        if respText.lowercased().contains("\"ok\":true") || respText.lowercased().contains("success") {
                            return DriveOverwriteResult(success: true, message: "Đã ghi đè lên Google Drive (Apps Script)")
                        }
                    }
                } catch {
                    // Nếu Apps Script lỗi mạng thì thử tiếp phương án 2 bên dưới
                }
            }
        }

        // ƯU TIÊN 2: Ghi đè qua Google Drive API v3 với OAuth Token / Refresh Token
        let resolvedToken = await resolveValidAccessToken(
            manualAccessToken: accessToken,
            clientId: clientId,
            clientSecret: clientSecret,
            refreshToken: refreshToken
        )

        guard let token = resolvedToken, !token.isEmpty else {
            return DriveOverwriteResult(
                success: false,
                message: "Chỉ lưu trên máy (Chưa cấu hình Link Apps Script hoặc OAuth Token để ghi đè lên Drive)"
            )
        }

        var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files/\(fileId)")!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "media")
        ]

        guard let url = components.url, let bodyData = content.data(using: .utf8) else {
            return DriveOverwriteResult(success: false, message: "Lỗi tạo dữ liệu upload Drive")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                // Nếu có đổi tên chương thì cập nhật luôn tên file trên Google Drive
                if let newFileName, !newFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let finalName = newFileName.lowercased().hasSuffix(".txt") ? newFileName : "\(newFileName).txt"
                    await renameRemoteDriveFile(fileId: fileId, newName: finalName, bearerToken: token)
                }
                return DriveOverwriteResult(success: true, message: "Đã ghi đè lên Google Drive")
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return DriveOverwriteResult(success: false, message: "Drive từ chối ghi đè (HTTP \(code))")
            }
        } catch {
            return DriveOverwriteResult(success: false, message: "Lỗi mạng khi ghi lên Drive")
        }
    }

    private func renameRemoteDriveFile(fileId: String, newName: String, bearerToken: String) async {
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let body = ["name": newName]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: request)
    }
}
