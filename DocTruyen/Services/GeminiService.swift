import Foundation

enum GeminiServiceError: LocalizedError {
    case emptyAPIKey
    case emptyContent
    case quotaExceededAllModels(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .emptyAPIKey:
            return "Bạn chưa nhập Gemini API Key. Hãy mở Cài đặt AI để nhập API Key trước khi dịch."
        case .emptyContent:
            return "Nội dung chương trống, không có gì để dịch."
        case .quotaExceededAllModels(let detail):
            return "Máy chủ Gemini hiện đang quá tải hoặc hết hạn mức (Quota) trên tất cả các model dự phòng: \(detail)"
        case .apiError(let message):
            return message
        }
    }
}

struct GeminiTranslationOutcome {
    let translatedText: String
    let usedModelChoice: GeminiModelChoice
    let actualEndpointModel: String
    let didAutoSwitchToFallback: Bool
}

final class GeminiService {
    static let shared = GeminiService()
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 240
        self.session = URLSession(configuration: config)
    }

    func translateChapterContent(
        rawContent: String,
        customInstruction: String,
        apiKey: String,
        preferredModel: GeminiModelChoice,
        autoFallbackWhenQuotaExceeded: Bool = true
    ) async throws -> GeminiTranslationOutcome {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw GeminiServiceError.emptyAPIKey
        }

        let trimmedContent = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            throw GeminiServiceError.emptyContent
        }

        let instruction = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? DefaultPrompts.standardNovelPolish
            : customInstruction

        var modelOrder: [GeminiModelChoice] = [preferredModel]
        if autoFallbackWhenQuotaExceeded {
            let fallback: GeminiModelChoice = (preferredModel == .flash35Lite) ? .flash31Lite : .flash35Lite
            modelOrder.append(fallback)
        }

        var lastErrorMessage = "Không thể kết nối tới Gemini API."

        for (choiceIndex, choice) in modelOrder.enumerated() {
            let candidates = choice.candidateEndpointModels

            for endpointModel in candidates {
                // Thử tối đa 3 lần cho mỗi endpoint nếu máy chủ Google báo quá tải tạm thời (503 High Demand / Overloaded)
                for attempt in 1...3 {
                    do {
                        let resultText = try await callGenerateContent(
                            endpointModel: endpointModel,
                            apiKey: cleanKey,
                            systemInstruction: instruction,
                            userContent: trimmedContent
                        )
                        return GeminiTranslationOutcome(
                            translatedText: resultText,
                            usedModelChoice: choice,
                            actualEndpointModel: endpointModel,
                            didAutoSwitchToFallback: choiceIndex > 0
                        )
                    } catch let err as InternalCallError {
                        lastErrorMessage = err.message

                        if err.isModelNotFound {
                            // Model ID này không tồn tại trên endpoint -> chuyển ngay sang candidate tiếp theo
                            break
                        } else if err.isServerOverloaded {
                            // Lỗi "This model is currently experiencing high demand..." (HTTP 503 / UNAVAILABLE)
                            // Chờ 1.5s - 3s rồi thử lại, nếu vẫn quá tải thì thử sang model dự phòng tiếp theo
                            if attempt < 2 {
                                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_600_000_000)
                                continue
                            } else {
                                break
                            }
                        } else if err.isQuotaExceeded {
                            // Hết quota (HTTP 429) -> thử sang model tiếp theo
                            break
                        } else {
                            throw GeminiServiceError.apiError(err.message)
                        }
                    } catch {
                        lastErrorMessage = error.localizedDescription
                        if attempt < 2 {
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            continue
                        } else {
                            break
                        }
                    }
                }
            }
        }

        throw GeminiServiceError.quotaExceededAllModels(lastErrorMessage)
    }

    private struct InternalCallError: Error {
        let statusCode: Int
        let message: String
        let isQuotaExceeded: Bool
        let isServerOverloaded: Bool
        let isModelNotFound: Bool
    }

    private func callGenerateContent(
        endpointModel: String,
        apiKey: String,
        systemInstruction: String,
        userContent: String
    ) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(endpointModel):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw InternalCallError(
                statusCode: 400,
                message: "URL Gemini không hợp lệ.",
                isQuotaExceeded: false,
                isServerOverloaded: false,
                isModelNotFound: false
            )
        }

        let promptPayload = """
\(systemInstruction)

--- NỘI DUNG GỐC CẦN DỊCH / BIÊN TẬP LẠI ---
\(userContent)
"""

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": promptPayload]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.35,
                "topP": 0.95
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500

        if !(200...299).contains(statusCode) {
            let rawText = String(data: data, encoding: .utf8) ?? ""
            let lower = rawText.lowercased()

            let isQuota = statusCode == 429 ||
                lower.contains("quota") ||
                lower.contains("resource_exhausted") ||
                lower.contains("rate limit")

            let isOverloaded = statusCode == 503 ||
                statusCode == 502 ||
                statusCode == 504 ||
                lower.contains("high demand") ||
                lower.contains("overloaded") ||
                lower.contains("unavailable") ||
                lower.contains("try again later")

            let isNotFound = statusCode == 404 ||
                lower.contains("not found") ||
                lower.contains("not supported")

            var parsedError = "Lỗi Gemini API (HTTP \(statusCode))"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errObj = json["error"] as? [String: Any],
               let msg = errObj["message"] as? String {
                parsedError = msg
            }

            throw InternalCallError(
                statusCode: statusCode,
                message: parsedError,
                isQuotaExceeded: isQuota,
                isServerOverloaded: isOverloaded,
                isModelNotFound: isNotFound
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw InternalCallError(
                statusCode: 500,
                message: "Phản hồi từ Gemini không đúng định dạng.",
                isQuotaExceeded: false,
                isServerOverloaded: false,
                isModelNotFound: false
            )
        }

        let combinedText = parts.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combinedText.isEmpty else {
            throw InternalCallError(
                statusCode: 500,
                message: "Gemini trả về nội dung rỗng.",
                isQuotaExceeded: false,
                isServerOverloaded: false,
                isModelNotFound: false
            )
        }

        return combinedText
    }
}
