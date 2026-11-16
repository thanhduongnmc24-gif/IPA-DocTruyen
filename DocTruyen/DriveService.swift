import Foundation
import UIKit

enum DriveServiceError: LocalizedError {
    case missingCredentials
    case quotaOrAutomatedBlock
    case htmlReturnedInsteadOfText
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Chưa cấu hình Google Drive API Key, Folder ID hoặc Link Apps Script. Vui lòng kiểm tra trong mục Cài đặt."
        case .quotaOrAutomatedBlock:
            return "Google đang tạm giới hạn tải tự động qua API Key. Hãy dán Link Apps Script trong Cài đặt để đọc & ghi đè không giới hạn."
        case .htmlReturnedInsteadOfText:
            return "Google trả về trang HTML thay vì nội dung .txt. Hãy kiểm tra quyền chia sẻ file hoặc dán Link Apps Script."
        case .apiError(let msg):
            return msg
        }
    }
}

struct DriveOverwriteResult {
    let success: Bool
    let message: String
}

private final class AppsScriptRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        if [301, 302, 303].contains(response.statusCode) {
            redirected.httpMethod = "GET"
            redirected.httpBody = nil
            redirected.setValue(nil, forHTTPHeaderField: "Content-Type")
            redirected.setValue(nil, forHTTPHeaderField: "Content-Length")
        }
        completionHandler(redirected)
    }
}

final class DriveService {
    static let shared = DriveService()
    private let session: URLSession
    private let scriptSession: URLSession
    private let redirectDelegate = AppsScriptRedirectDelegate()

    private var cachedAccessToken: String = ""
    private var cachedAccessTokenExpiry: Date = .distantPast

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)

        let scriptConfig = URLSessionConfiguration.ephemeral
        scriptConfig.timeoutIntervalForRequest = 60
        scriptConfig.timeoutIntervalForResource = 150
        scriptConfig.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        scriptConfig.waitsForConnectivity = true
        self.scriptSession = URLSession(configuration: scriptConfig, delegate: redirectDelegate, delegateQueue: nil)
    }

    func fileMediaURLString(fileId: String, apiKey: String) -> String {
        "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media&key=\(apiKey)"
    }

    // MARK: - Tải danh sách Thư mục & Chương truyện (Hỗ trợ đầy đủ 4.000+ chương, retry từng trang)
    func listChildren(
        folderId: String,
        apiKey: String,
        appsScriptWebAppUrl: String? = nil,
        extraQuery: String = "",
        pageSize: Int = 1000
    ) async throws -> [DriveItem] {
        let trimmedFolder = DriveInputParser.extractFolderId(from: folderId)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanScriptUrl = DriveInputParser.normalizeAppsScriptUrl(appsScriptWebAppUrl ?? "")

        guard !trimmedFolder.isEmpty else {
            throw DriveServiceError.missingCredentials
        }

        var lastDriveError: Error?
        if !trimmedKey.isEmpty {
            do {
                let items = try await listChildrenViaDriveAPI(
                    folderId: trimmedFolder,
                    apiKey: trimmedKey,
                    extraQuery: extraQuery,
                    pageSize: pageSize
                )
                return sortItemsNaturally(items)
            } catch {
                lastDriveError = error
            }
        }

        if !cleanScriptUrl.isEmpty && extraQuery.isEmpty {
            if let viaScript = try? await listChildrenViaAppsScript(folderId: trimmedFolder, scriptUrlStr: cleanScriptUrl),
               !viaScript.isEmpty {
                return sortItemsNaturally(viaScript)
            }
        }

        if let lastDriveError {
            throw lastDriveError
        }
        throw DriveServiceError.missingCredentials
    }

    /// Sắp xếp tự nhiên theo số (0001, 0002, ..., 1000, ..., 4000) ngay trên máy để không bị lỗi phân trang `orderBy=name_natural` của Google Drive
    private func sortItemsNaturally(_ items: [DriveItem]) -> [DriveItem] {
        items.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder {
                return lhs.isFolder && !rhs.isFolder
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func listChildrenViaDriveAPI(
        folderId: String,
        apiKey: String,
        extraQuery: String,
        pageSize: Int = 1000
    ) async throws -> [DriveItem] {
        var allFiles: [DriveItem] = []
        var seenIds: Set<String> = []
        var pageToken = ""
        let includeThumb = !extraQuery.isEmpty

        repeat {
            let baseQuery = "'\(folderId)' in parents and trashed=false"
            let finalQuery = extraQuery.isEmpty ? baseQuery : "\(baseQuery) and (\(extraQuery))"

            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            let fieldsValue = includeThumb
                ? "nextPageToken,files(id,name,mimeType,modifiedTime,thumbnailLink)"
                : "nextPageToken,files(id,name,mimeType,modifiedTime)"

            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "q", value: finalQuery),
                URLQueryItem(name: "fields", value: fieldsValue),
                URLQueryItem(name: "pageSize", value: "\(min(max(pageSize, 1), 1000))"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                URLQueryItem(name: "key", value: apiKey)
            ]

            if !pageToken.isEmpty {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }

            components.queryItems = queryItems
            guard let url = components.url else {
                throw DriveServiceError.apiError("URL Google Drive không hợp lệ.")
            }

            // Retry tối đa 3 lần cho RIÊNG từng trang để không bị mất dữ liệu các trang trước nếu trang sau nghẽn mạng
            var pageDecoded: DriveListResponse?
            var pageError: Error?

            for attempt in 1...3 {
                do {
                    var req = URLRequest(url: url)
                    req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                    let (data, response) = try await session.data(for: req)
                    let httpResponse = response as? HTTPURLResponse
                    let decoded = try? JSONDecoder().decode(DriveListResponse.self, from: data)

                    if let statusCode = httpResponse?.statusCode, !(200...299).contains(statusCode) {
                        let msg = decoded?.error?.message ?? "Không tải được danh sách chương từ Google Drive (HTTP \(statusCode))."
                        throw DriveServiceError.apiError(msg)
                    }

                    pageDecoded = decoded
                    pageError = nil
                    break
                } catch {
                    pageError = error
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
                    }
                }
            }

            if let pageError {
                throw pageError
            }

            for item in pageDecoded?.files ?? [] {
                if seenIds.insert(item.id).inserted {
                    allFiles.append(item)
                }
            }

            let nextToken = pageDecoded?.nextPageToken ?? ""
            if nextToken == pageToken {
                break
            }
            pageToken = (pageSize < 1000) ? "" : nextToken
        } while !pageToken.isEmpty

        return allFiles
    }

    private func listChildrenViaAppsScript(folderId: String, scriptUrlStr: String) async throws -> [DriveItem] {
        guard var comps = URLComponents(string: scriptUrlStr) else { return [] }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "action", value: "list"))
        items.append(URLQueryItem(name: "folderId", value: folderId))
        comps.queryItems = items
        guard let url = comps.url else { return [] }

        let (data, response) = try await scriptSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return []
        }
        if let decoded = try? JSONDecoder().decode(DriveListResponse.self, from: data),
           let files = decoded.files {
            return files
        }
        return []
    }

    // MARK: - Tìm và tải file ảnh đại diện (tên bất kỳ, đuôi bất kỳ) trong mỗi thư mục truyện
    func fetchAndCacheFolderCover(
        folderId: String,
        apiKey: String,
        appsScriptWebAppUrl: String? = nil
    ) async -> String? {
        if LocalChapterStorage.shared.hasCachedCoverImage(for: folderId) {
            return "local://cover/\(folderId)"
        }

        var candidateFile: DriveItem?

        if let nonTxtFiles = try? await listChildren(
            folderId: folderId,
            apiKey: apiKey,
            appsScriptWebAppUrl: appsScriptWebAppUrl,
            extraQuery: "mimeType != 'application/vnd.google-apps.folder' and not name contains '.txt'",
            pageSize: 20
        ) {
            candidateFile = nonTxtFiles.first(where: { !$0.isFolder && !$0.isTextFile })
        }

        if candidateFile == nil {
            if let imageFiles = try? await listChildren(
                folderId: folderId,
                apiKey: apiKey,
                appsScriptWebAppUrl: appsScriptWebAppUrl,
                extraQuery: "mimeType contains 'image/'",
                pageSize: 20
            ) {
                candidateFile = imageFiles.first(where: { !$0.isFolder && !$0.isTextFile })
            }
        }

        guard let coverFile = candidateFile else {
            return nil
        }

        if await downloadAndCacheCoverFile(coverFile, forFolderId: folderId, apiKey: apiKey) {
            return "local://cover/\(folderId)"
        }

        return coverFile.thumbnailLink ?? "https://drive.google.com/thumbnail?id=\(coverFile.id)&sz=w600"
    }

    @discardableResult
    func downloadAndCacheCoverFile(
        _ file: DriveItem,
        forFolderId folderId: String,
        apiKey: String
    ) async -> Bool {
        if LocalChapterStorage.shared.hasCachedCoverImage(for: folderId) {
            return true
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidateURLStrings: [String] = []

        if let thumb = file.thumbnailLink, !thumb.isEmpty {
            let highResThumb = thumb.replacingOccurrences(of: "=s220", with: "=s600")
            candidateURLStrings.append(highResThumb)
        }

        candidateURLStrings.append("https://drive.google.com/thumbnail?id=\(file.id)&sz=w600")
        candidateURLStrings.append("https://lh3.googleusercontent.com/d/\(file.id)=w600")

        if !trimmedKey.isEmpty {
            candidateURLStrings.append(fileMediaURLString(fileId: file.id, apiKey: trimmedKey))
        }

        candidateURLStrings.append("https://drive.google.com/uc?export=download&id=\(file.id)&confirm=t")

        for urlStr in candidateURLStrings {
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

            if let (data, resp) = try? await session.data(for: req),
               let http = resp as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               !data.isEmpty,
               LocalChapterStorage.shared.saveCachedCoverImageData(data, for: folderId) != nil {
                return true
            }
        }

        return false
    }

    // MARK: - Tải nội dung chương truyện
    func downloadTextFile(
        fileId: String,
        apiKey: String,
        appsScriptWebAppUrl: String? = nil,
        accessToken: String? = nil
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanScriptUrl = DriveInputParser.normalizeAppsScriptUrl(appsScriptWebAppUrl ?? "")
        let cleanToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var lastError: Error = DriveServiceError.missingCredentials

        if !trimmedKey.isEmpty, let url = URL(string: fileMediaURLString(fileId: fileId, apiKey: trimmedKey)) {
            for attempt in 1...2 {
                do {
                    var request = URLRequest(url: url)
                    request.setValue("text/plain,*/*", forHTTPHeaderField: "Accept")
                    if !cleanToken.isEmpty {
                        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
                    }

                    let (data, response) = try await session.data(for: request)
                    let httpResponse = response as? HTTPURLResponse
                    let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                    let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)

                    if let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) {
                        if !contentType.contains("text/html") && !isGoogleErrorHtml(text) {
                            return text
                        }
                        lastError = DriveServiceError.htmlReturnedInsteadOfText
                    } else {
                        if text.contains("automated queries") || text.contains("We're sorry") || text.contains("downloadQuotaExceeded") {
                            lastError = DriveServiceError.quotaOrAutomatedBlock
                        } else if contentType.contains("text/html") {
                            lastError = DriveServiceError.htmlReturnedInsteadOfText
                        } else {
                            let code = httpResponse?.statusCode ?? 0
                            lastError = DriveServiceError.apiError(text.isEmpty ? "Không đọc được chương truyện (HTTP \(code))." : text)
                        }
                    }
                } catch {
                    lastError = error
                }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
            }
        }

        if !cleanScriptUrl.isEmpty {
            if let scriptText = await downloadTextViaAppsScript(fileId: fileId, scriptUrlStr: cleanScriptUrl),
               !scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return scriptText
            }
        }

        if let fallbackUrl = URL(string: "https://drive.google.com/uc?export=download&id=\(fileId)&confirm=t") {
            var req = URLRequest(url: fallbackUrl)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            if let (data, response) = try? await session.data(for: req),
               let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode) {
                let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                if !contentType.contains("text/html") && !isGoogleErrorHtml(text) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }

        throw lastError
    }

    private func isGoogleErrorHtml(_ text: String) -> Bool {
        let prefix = String(text.prefix(300)).lowercased()
        return prefix.contains("<!doctype html") || prefix.contains("<html")
    }

    private func downloadTextViaAppsScript(fileId: String, scriptUrlStr: String) async -> String? {
        if var comps = URLComponents(string: scriptUrlStr) {
            var q = comps.queryItems ?? []
            q.append(URLQueryItem(name: "action", value: "read"))
            q.append(URLQueryItem(name: "fileId", value: fileId))
            comps.queryItems = q
            if let getUrl = comps.url,
               let (data, resp) = try? await scriptSession.data(from: getUrl),
               let http = resp as? HTTPURLResponse,
               (200...299).contains(http.statusCode) {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ok = json["ok"] as? Bool, ok == true,
                   let content = json["content"] as? String {
                    return content
                }
            }
        }
        return nil
    }

    // MARK: - Quản lý OAuth Access Token
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

    // MARK: - Ghi đè nội dung đã dịch và cập nhật tên chương lên thẳng Google Drive
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
        let cleanScriptUrl = DriveInputParser.normalizeAppsScriptUrl(appsScriptWebAppUrl ?? "")
        var lastScriptFailureReason: String?

        if !cleanScriptUrl.isEmpty, let scriptUrl = URL(string: cleanScriptUrl) {
            var payload: [String: Any] = [
                "action": "overwrite",
                "fileId": fileId,
                "content": content
            ]
            if let newFileName, !newFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmedName = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalName = trimmedName.lowercased().hasSuffix(".txt") ? trimmedName : "\(trimmedName).txt"
                payload["newName"] = finalName
            }

            if let body = try? JSONSerialization.data(withJSONObject: payload) {
                for attempt in 1...4 {
                    if Task.isCancelled {
                        return DriveOverwriteResult(success: false, message: "Đã hủy ghi đè")
                    }

                    var request = URLRequest(url: scriptUrl)
                    request.httpMethod = "POST"
                    request.setValue("text/plain;charset=utf-8", forHTTPHeaderField: "Content-Type")
                    request.httpBody = body

                    do {
                        let (data, response) = try await scriptSession.data(for: request)
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let respText = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                        if (200...299).contains(statusCode) {
                            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                if let ok = json["ok"] as? Bool {
                                    if ok {
                                        return DriveOverwriteResult(success: true, message: "Đã ghi đè lên Google Drive (Apps Script)")
                                    } else {
                                        let errDetail = (json["error"] as? String) ?? "Apps Script trả về ok=false"
                                        lastScriptFailureReason = "Lỗi Apps Script: \(errDetail)"
                                    }
                                } else if let status = (json["status"] as? String)?.lowercased(),
                                          status == "ok" || status == "success" {
                                    return DriveOverwriteResult(success: true, message: "Đã ghi đè lên Google Drive (Apps Script)")
                                } else if json["error"] == nil {
                                    return DriveOverwriteResult(success: true, message: "Đã ghi đè lên Google Drive (Apps Script)")
                                }
                            } else {
                                let lower = respText.lowercased()
                                let compact = lower.replacingOccurrences(of: " ", with: "")
                                if compact.contains("\"ok\":true") || lower.contains("success") || lower == "ok" {
                                    return DriveOverwriteResult(success: true, message: "Đã ghi đè lên Google Drive (Apps Script)")
                                } else if isGoogleErrorHtml(respText) {
                                    lastScriptFailureReason = "Apps Script trả về HTML (kiểm tra quyền Deploy 'Bất kỳ ai / Anyone')"
                                } else {
                                    lastScriptFailureReason = respText.isEmpty ? "Apps Script phản hồi rỗng" : String(respText.prefix(120))
                                }
                            }
                        } else {
                            lastScriptFailureReason = "Apps Script HTTP \(statusCode)"
                        }
                    } catch {
                        lastScriptFailureReason = error.localizedDescription
                    }

                    if attempt < 4 {
                        let backoffNs = UInt64(attempt) * 1_200_000_000
                        try? await Task.sleep(nanoseconds: backoffNs)
                    }
                }
            }
        }

        let resolvedToken = await resolveValidAccessToken(
            manualAccessToken: accessToken,
            clientId: clientId,
            clientSecret: clientSecret,
            refreshToken: refreshToken
        )

        guard let token = resolvedToken, !token.isEmpty else {
            if let lastScriptFailureReason {
                return DriveOverwriteResult(
                    success: false,
                    message: "Chưa ghi đè được lên Drive (\(lastScriptFailureReason))"
                )
            }
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

        for attempt in 1...3 {
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = bodyData

            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    if let newFileName, !newFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let trimmedName = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let finalName = trimmedName.lowercased().hasSuffix(".txt") ? trimmedName : "\(trimmedName).txt"
                        await renameRemoteDriveFile(fileId: fileId, newName: finalName, bearerToken: token)
                    }
                    return DriveOverwriteResult(success: true, message: "Đã ghi đè lên Google Drive")
                } else if attempt == 3 {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    return DriveOverwriteResult(success: false, message: "Drive từ chối ghi đè (HTTP \(code))")
                }
            } catch {
                if attempt == 3 {
                    return DriveOverwriteResult(success: false, message: "Lỗi mạng khi ghi lên Drive: \(error.localizedDescription)")
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
        }

        return DriveOverwriteResult(success: false, message: "Không thể ghi đè lên Drive")
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
