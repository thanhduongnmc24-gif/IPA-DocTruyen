import Foundation
import AVFoundation
import MediaPlayer
import CryptoKit
import Combine

enum StoryVoiceChoice: String, CaseIterable, Identifiable, Codable {
    case namMinh = "vi-VN-NamMinhNeural"
    case hoaiMy = "vi-VN-HoaiMyNeural"
    case geminiKore = "gemini-kore"
    case geminiPuck = "gemini-puck"
    case googleVi = "google-vi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .namMinh: return "Nam Minh (AI Trầm ấm)"
        case .hoaiMy: return "Hoài My (AI Truyền cảm)"
        case .geminiKore: return "Gemini AI Nữ (Kore)"
        case .geminiPuck: return "Gemini AI Nam (Puck)"
        case .googleVi: return "Chị Google (Dự phòng)"
        }
    }

    var shortName: String {
        switch self {
        case .namMinh: return "Nam Minh AI"
        case .hoaiMy: return "Hoài My AI"
        case .geminiKore: return "Gemini Nữ"
        case .geminiPuck: return "Gemini Nam"
        case .googleVi: return "Google"
        }
    }

    var geminiVoiceName: String {
        switch self {
        case .geminiPuck, .namMinh:
            return "Puck"
        case .geminiKore, .hoaiMy, .googleVi:
            return "Kore"
        }
    }

    var edgeVoiceName: String {
        switch self {
        case .geminiPuck, .namMinh:
            return "vi-VN-NamMinhNeural"
        case .geminiKore, .hoaiMy, .googleVi:
            return "vi-VN-HoaiMyNeural"
        }
    }
}

// MARK: - Codable Struct chuẩn cho Gemini TTS (Không chứa safetySettings hay systemInstruction để tránh lỗi HTTP 400 trên endpoint TTS)
private struct GeminiTTSRequestPayload: Encodable {
    struct Content: Encodable {
        struct Part: Encodable {
            let text: String
        }
        let parts: [Part]
    }
    struct GenerationConfig: Encodable {
        struct SpeechConfig: Encodable {
            struct VoiceConfig: Encodable {
                struct PrebuiltVoiceConfig: Encodable {
                    let voiceName: String
                }
                let prebuiltVoiceConfig: PrebuiltVoiceConfig
            }
            let voiceConfig: VoiceConfig
        }
        let responseModalities: [String]
        let speechConfig: SpeechConfig
    }

    let contents: [Content]
    let generationConfig: GenerationConfig
}

private struct GeminiTTSResponsePayload: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                struct InlineData: Decodable {
                    let mimeType: String?
                    let data: String?
                }
                let inlineData: InlineData?
            }
            let parts: [Part]?
        }
        let content: Content?
    }
    let candidates: [Candidate]?
}

@MainActor
final class StorySpeechManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = StorySpeechManager()

    @Published var isSpeaking: Bool = false
    @Published var isPaused: Bool = false
    @Published var isBuffering: Bool = false
    @Published var currentChunkIndex: Int = 0
    @Published var totalChunks: Int = 0
    @Published var currentChapterTitle: String = ""
    @Published var activeVoiceLabel: String = ""

    @Published var selectedVoiceChoice: StoryVoiceChoice = .namMinh {
        didSet {
            UserDefaults.standard.set(selectedVoiceChoice.rawValue, forKey: "DOC_TRUYEN_SPEECH_VOICE_CHOICE")
            if isSpeaking {
                prefetchedAudioCache.removeAll()
                restartFromCurrentChunk()
            }
        }
    }

    @Published var playbackSpeedMultiplier: Double = 1.1 {
        didSet {
            UserDefaults.standard.set(playbackSpeedMultiplier, forKey: "DOC_TRUYEN_SPEECH_SPEED_MULTIPLIER")
            if let player = audioPlayer {
                player.enableRate = true
                player.rate = Float(min(2.0, max(0.6, playbackSpeedMultiplier)))
            }
            updateNowPlayingInfo()
        }
    }

    var onChapterFinished: (() -> Void)?
    var onError: ((String) -> Void)?

    private var audioPlayer: AVAudioPlayer?
    private var chunks: [String] = []
    private var chunkStartRatios: [Double] = []
    private var hasPrependedTitleChunk: Bool = false
    private var prefetchedAudioCache: [Int: Data] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var playSessionToken: UUID = UUID()
    private var consecutiveFailures: Int = 0
    private var tempFileToggle: Int = 0

    private override init() {
        super.init()

        let savedSpeed = UserDefaults.standard.double(forKey: "DOC_TRUYEN_SPEECH_SPEED_MULTIPLIER")
        if savedSpeed >= 0.6 && savedSpeed <= 2.0 {
            playbackSpeedMultiplier = savedSpeed
        }
        if let savedVoiceRaw = UserDefaults.standard.string(forKey: "DOC_TRUYEN_SPEECH_VOICE_CHOICE"),
           let voice = StoryVoiceChoice(rawValue: savedVoiceRaw) {
            selectedVoiceChoice = voice
        } else {
            selectedVoiceChoice = .namMinh
            UserDefaults.standard.set(StoryVoiceChoice.namMinh.rawValue, forKey: "DOC_TRUYEN_SPEECH_VOICE_CHOICE")
        }

        setupRemoteCommands()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetooth, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipForwardChunk() }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipBackwardChunk() }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        let titleValue: String = currentChapterTitle.isEmpty ? "Đọc Truyện AI" : currentChapterTitle
        let artistValue: String = activeVoiceLabel.isEmpty ? selectedVoiceChoice.shortName : activeVoiceLabel
        let rateValue: Double = (isSpeaking && !isPaused) ? playbackSpeedMultiplier : 0.0

        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = titleValue
        info[MPMediaItemPropertyArtist] = artistValue
        info[MPNowPlayingInfoPropertyPlaybackRate] = rateValue
        if totalChunks > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(totalChunks)
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentChunkIndex)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func startSpeaking(title: String, text: String, fromScrollRatio: Double = 0.0) {
        stopInternal(resetTitle: false)
        configureAudioSession()

        currentChapterTitle = title
        let built = buildSpeechChunksWithRatios(from: text, title: title)
        chunks = built.chunks
        chunkStartRatios = built.ratios
        hasPrependedTitleChunk = built.hasPrependedTitle
        totalChunks = chunks.count

        guard !chunks.isEmpty else {
            isSpeaking = false
            isPaused = false
            return
        }

        let targetIndex = resolveChunkIndex(forScrollRatio: fromScrollRatio)
        currentChunkIndex = max(0, min(targetIndex, chunks.count - 1))
        consecutiveFailures = 0
        isSpeaking = true
        isPaused = false
        playSessionToken = UUID()
        playCurrentChunk()
        updateNowPlayingInfo()
    }

    func startSpeaking(title: String, text: String, fromChunkIndex: Int) {
        stopInternal(resetTitle: false)
        configureAudioSession()

        currentChapterTitle = title
        let built = buildSpeechChunksWithRatios(from: text, title: title)
        chunks = built.chunks
        chunkStartRatios = built.ratios
        hasPrependedTitleChunk = built.hasPrependedTitle
        totalChunks = chunks.count

        guard !chunks.isEmpty else {
            isSpeaking = false
            isPaused = false
            return
        }

        currentChunkIndex = max(0, min(fromChunkIndex, chunks.count - 1))
        consecutiveFailures = 0
        isSpeaking = true
        isPaused = false
        playSessionToken = UUID()
        playCurrentChunk()
        updateNowPlayingInfo()
    }

    func jumpToScrollRatio(_ ratio: Double) {
        guard !chunks.isEmpty else { return }
        let targetIndex = resolveChunkIndex(forScrollRatio: ratio)
        currentChunkIndex = max(0, min(targetIndex, chunks.count - 1))
        consecutiveFailures = 0
        if !isSpeaking {
            isSpeaking = true
        }
        restartFromCurrentChunk()
    }

    func resolveChunkIndex(forScrollRatio ratio: Double) -> Int {
        guard !chunks.isEmpty else { return 0 }
        let clamped = min(1.0, max(0.0, ratio))
        if clamped <= 0.015 {
            return 0
        }

        let searchStart = (hasPrependedTitleChunk && chunks.count > 1) ? 1 : 0
        var bestIndex = searchStart
        var smallestDiff = Double.greatestFiniteMagnitude

        for idx in searchStart..<chunks.count {
            let chunkRatio = idx < chunkStartRatios.count ? chunkStartRatios[idx] : (Double(idx) / Double(max(1, chunks.count)))
            if chunkRatio <= clamped + 0.008 {
                bestIndex = idx
            }
            let diff = abs(chunkRatio - clamped)
            if diff < smallestDiff {
                smallestDiff = diff
            }
        }
        return max(0, min(bestIndex, chunks.count - 1))
    }

    private func restartFromCurrentChunk() {
        guard isSpeaking, !chunks.isEmpty else { return }
        audioPlayer?.stop()
        audioPlayer = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        playSessionToken = UUID()
        isPaused = false
        playCurrentChunk()
    }

    func togglePlayPause() {
        guard isSpeaking else { return }
        if isPaused {
            resume()
        } else {
            pause()
        }
    }

    func pause() {
        guard isSpeaking, !isPaused else { return }
        isPaused = true
        audioPlayer?.pause()
        updateNowPlayingInfo()
    }

    func resume() {
        guard isSpeaking, isPaused else { return }
        configureAudioSession()
        isPaused = false
        if let player = audioPlayer {
            player.enableRate = true
            player.rate = Float(min(2.0, max(0.6, playbackSpeedMultiplier)))
            player.play()
        } else {
            playCurrentChunk()
        }
        updateNowPlayingInfo()
    }

    func stop() {
        stopInternal(resetTitle: true)
    }

    func skipForwardChunk() {
        guard isSpeaking, !chunks.isEmpty else { return }
        if currentChunkIndex + 1 < chunks.count {
            currentChunkIndex += 1
            consecutiveFailures = 0
            restartFromCurrentChunk()
        } else {
            stopInternal(resetTitle: false)
            onChapterFinished?()
        }
    }

    func skipBackwardChunk() {
        guard isSpeaking, !chunks.isEmpty else { return }
        currentChunkIndex = max(0, currentChunkIndex - 1)
        consecutiveFailures = 0
        restartFromCurrentChunk()
    }

    func adjustSpeed(delta: Double) {
        let clamped = min(2.0, max(0.6, ((playbackSpeedMultiplier + delta) * 10).rounded() / 10))
        playbackSpeedMultiplier = clamped
    }

    private func stopInternal(resetTitle: Bool) {
        playSessionToken = UUID()
        audioPlayer?.stop()
        audioPlayer = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedAudioCache.removeAll()

        isSpeaking = false
        isPaused = false
        isBuffering = false
        currentChunkIndex = 0
        totalChunks = 0
        chunks = []
        chunkStartRatios = []
        hasPrependedTitleChunk = false
        activeVoiceLabel = ""
        consecutiveFailures = 0
        if resetTitle {
            currentChapterTitle = ""
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    private static var currentSavedGeminiApiKey: String {
        (UserDefaults.standard.string(forKey: "DOC_TRUYEN_GEMINI_API_KEY") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Phát từng đoạn & tải trước tuần tự
    private func playCurrentChunk() {
        let sessionToken = playSessionToken
        guard currentChunkIndex >= 0, currentChunkIndex < chunks.count else {
            isSpeaking = false
            isPaused = false
            onChapterFinished?()
            return
        }

        let voiceMode = selectedVoiceChoice
        let chunkIdx = currentChunkIndex
        let text = chunks[chunkIdx]

        if let cachedData = prefetchedAudioCache[chunkIdx] {
            prefetchedAudioCache.removeValue(forKey: chunkIdx)
            if playAudioData(cachedData, voiceLabel: voiceMode.shortName) {
                consecutiveFailures = 0
                startSequentialPrefetch(after: chunkIdx, voice: voiceMode, sessionToken: sessionToken)
                return
            }
        }

        isBuffering = true
        let apiKey = Self.currentSavedGeminiApiKey
        Task {
            let audioData: Data?
            if let cached = self.prefetchedAudioCache[chunkIdx] {
                self.prefetchedAudioCache.removeValue(forKey: chunkIdx)
                audioData = cached
            } else {
                audioData = await Self.synthesizeSpeechData(text: text, voice: voiceMode, geminiApiKey: apiKey)
            }

            guard self.playSessionToken == sessionToken, self.isSpeaking, !self.isPaused else { return }
            self.isBuffering = false

            if let audioData, self.playAudioData(audioData, voiceLabel: voiceMode.shortName) {
                self.consecutiveFailures = 0
                self.startSequentialPrefetch(after: chunkIdx, voice: voiceMode, sessionToken: sessionToken)
            } else {
                self.consecutiveFailures += 1
                if self.consecutiveFailures < 3 && self.currentChunkIndex + 1 < self.chunks.count {
                    self.currentChunkIndex += 1
                    self.playCurrentChunk()
                } else {
                    self.stopInternal(resetTitle: false)
                    self.onError?("Không thể tải âm thanh giọng đọc AI. Vui lòng kiểm tra kết nối mạng.")
                }
            }
        }
    }

    private func startSequentialPrefetch(after index: Int, voice: StoryVoiceChoice, sessionToken: UUID) {
        prefetchTask?.cancel()
        let apiKey = Self.currentSavedGeminiApiKey
        let maxLookahead = (voice == .geminiKore || voice == .geminiPuck) ? 1 : 2

        prefetchTask = Task {
            for offset in 1...maxLookahead {
                if Task.isCancelled || self.playSessionToken != sessionToken { return }
                let targetIdx = index + offset
                guard targetIdx < self.chunks.count else { break }
                if self.prefetchedAudioCache[targetIdx] != nil { continue }

                let targetText = self.chunks[targetIdx]
                let data = await Self.synthesizeSpeechData(text: targetText, voice: voice, geminiApiKey: apiKey)
                if Task.isCancelled || self.playSessionToken != sessionToken { return }
                if let data {
                    self.prefetchedAudioCache[targetIdx] = data
                }
            }
        }
    }

    private static func synthesizeSpeechData(
        text: String,
        voice: StoryVoiceChoice,
        geminiApiKey: String
    ) async -> Data? {
        let cleaned = sanitizeLineForSpeech(text)
        guard !cleaned.isEmpty else { return nil }

        switch voice {
        case .namMinh, .hoaiMy:
            // 1. Ưu tiên tuyệt đối Edge Neural AI v2 (Sec-MS-GEC v2 2-143.0.3650.75)
            if let edgeData = await EdgeNeuralTTSClient.synthesize(text: cleaned, voiceName: voice.edgeVoiceName),
               edgeData.count > 200 {
                return edgeData
            }
            // 2. Dự phòng sang Gemini TTS (3.1 Flash TTS / 2.5 Flash TTS)
            if !geminiApiKey.isEmpty {
                if let geminiAudio = await GeminiTTSClient.synthesize(
                    text: cleaned,
                    voiceName: voice.geminiVoiceName,
                    apiKey: geminiApiKey
                ), geminiAudio.count > 200 {
                    return geminiAudio
                }
            }
            // 3. Dự phòng cuối cùng
            if let googleData = await GoogleTranslateTTSClient.synthesize(text: cleaned),
               googleData.count > 200 {
                return googleData
            }

        case .geminiKore, .geminiPuck:
            // 1. Ưu tiên Gemini TTS (xoay vòng 3 model: gemini-3.1-flash-tts-preview -> gemini-2.5-flash-preview-tts -> gemini-2.5-flash-lite-preview-tts)
            if !geminiApiKey.isEmpty {
                if let geminiAudio = await GeminiTTSClient.synthesize(
                    text: cleaned,
                    voiceName: voice.geminiVoiceName,
                    apiKey: geminiApiKey
                ), geminiAudio.count > 200 {
                    return geminiAudio
                }
            }
            // 2. Dự phòng sang Edge Neural AI v2 cùng giới tính giọng (Hoài My / Nam Minh)
            if let edgeData = await EdgeNeuralTTSClient.synthesize(text: cleaned, voiceName: voice.edgeVoiceName),
               edgeData.count > 200 {
                return edgeData
            }
            // 3. Dự phòng cuối cùng
            if let googleData = await GoogleTranslateTTSClient.synthesize(text: cleaned),
               googleData.count > 200 {
                return googleData
            }

        case .googleVi:
            if let googleData = await GoogleTranslateTTSClient.synthesize(text: cleaned),
               googleData.count > 200 {
                return googleData
            }
            if let edgeData = await EdgeNeuralTTSClient.synthesize(text: cleaned, voiceName: "vi-VN-HoaiMyNeural"),
               edgeData.count > 200 {
                return edgeData
            }
        }

        return nil
    }

    @discardableResult
    private func playAudioData(_ data: Data, voiceLabel: String) -> Bool {
        guard data.count > 200 else { return false }
        audioPlayer?.stop()
        audioPlayer = nil
        configureAudioSession()

        let isWAV = Self.isRIFFWaveData(data)
        let hint = isWAV ? AVFileType.wav.rawValue : AVFileType.mp3.rawValue
        let ext = isWAV ? "wav" : "mp3"
        let targetRate = Float(min(2.0, max(0.6, playbackSpeedMultiplier)))

        tempFileToggle = (tempFileToggle + 1) % 2
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctruyen_tts_slot_\(tempFileToggle).\(ext)")

        if let _ = try? data.write(to: tempURL, options: .atomic),
           let filePlayer = try? AVAudioPlayer(contentsOf: tempURL) {
            filePlayer.delegate = self
            filePlayer.enableRate = true
            filePlayer.prepareToPlay()
            filePlayer.rate = targetRate
            if filePlayer.play() {
                audioPlayer = filePlayer
                activeVoiceLabel = voiceLabel
                updateNowPlayingInfo()
                return true
            }
        }

        if let memPlayer = try? AVAudioPlayer(data: data, fileTypeHint: hint) {
            memPlayer.delegate = self
            memPlayer.enableRate = true
            memPlayer.prepareToPlay()
            memPlayer.rate = targetRate
            if memPlayer.play() {
                audioPlayer = memPlayer
                activeVoiceLabel = voiceLabel
                updateNowPlayingInfo()
                return true
            }
        }

        return false
    }

    private static func isRIFFWaveData(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let riff = String(data: data.subdata(in: 0..<4), encoding: .ascii)
        let wave = String(data: data.subdata(in: 8..<12), encoding: .ascii)
        return riff == "RIFF" && wave == "WAVE"
    }

    private func advanceToNextChunkOrChapter() {
        guard isSpeaking, !isPaused else { return }
        if currentChunkIndex + 1 < chunks.count {
            currentChunkIndex += 1
            playCurrentChunk()
        } else {
            isSpeaking = false
            isPaused = false
            currentChunkIndex = 0
            onChapterFinished?()
        }
    }

    // MARK: - AVAudioPlayerDelegate
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.audioPlayer === player else { return }
            self.audioPlayer = nil
            self.advanceToNextChunkOrChapter()
        }
    }

    // MARK: - Làm sạch ký tự đặc biệt (===, ..., ", —, ***) NHƯNG giữ nguyên dấu phẩy ngắt câu tự nhiên
    static func sanitizeLineForSpeech(_ rawLine: String) -> String {
        var s = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        if let r = s.range(of: #"^#{1,6}\s*"#, options: .regularExpression) {
            s.removeSubrange(r)
        }

        let forbiddenLiterals = [
            "\"", "“", "”", "„", "‟", "«", "»", "‹", "›",
            "‘", "’", "`", "´",
            "【", "】", "『", "』", "「", "」", "《", "》", "〈", "〉", "〔", "〕",
            "[", "]", "{", "}",
            "=", "*", "#", "_", "~", "^", "|", "\\", "<", ">"
        ]
        for token in forbiddenLiterals {
            s = s.replacingOccurrences(of: token, with: " ")
        }

        if s.range(of: #"^[\s=\-\*_~•·\.…o0O\+<>\|/]+$"#, options: .regularExpression) != nil {
            return ""
        }

        s = s.replacingOccurrences(of: #"(\.{2,}|…+)"#, with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\-{2,}|—+|–+)"#, with: ", ", options: .regularExpression)

        s = s.replacingOccurrences(of: #"(\s*,\s*){2,}"#, with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[,\s]+([.!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([.!?])\s*,+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[\s,.;:\-!?]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[\s,;:]+$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        guard s.rangeOfCharacter(from: .alphanumerics) != nil else {
            return ""
        }
        return s
    }

    private func buildSpeechChunksWithRatios(
        from rawText: String,
        title: String
    ) -> (chunks: [String], ratios: [Double], hasPrependedTitle: Bool) {
        let rawLines = rawText.components(separatedBy: .newlines)
        let charsPerVisualLine: Double = 38.0

        var lineVisualStarts: [Double] = []
        var cumulativeVisualLines: Double = 0.0

        for rawLine in rawLines {
            lineVisualStarts.append(cumulativeVisualLines)
            var displayLine = rawLine
            if let r = displayLine.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                displayLine.removeSubrange(r)
            }
            displayLine = displayLine.replacingOccurrences(of: "**", with: "")
            let trimmed = displayLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                cumulativeVisualLines += 1.0
            } else {
                let wrappedLines = max(1.0, ceil(Double(trimmed.count) / charsPerVisualLine))
                cumulativeVisualLines += wrappedLines
            }
        }

        let totalVisualLines = max(1.0, cumulativeVisualLines)

        var resultChunks: [String] = []
        var resultRatios: [Double] = []
        var hasPrependedTitle = false

        let cleanTitle = Self.sanitizeLineForSpeech(title)
        let firstNonEmptyCleaned = rawLines
            .map { Self.sanitizeLineForSpeech($0) }
            .first(where: { !$0.isEmpty })

        if !cleanTitle.isEmpty {
            if let first = firstNonEmptyCleaned {
                let foldedFirst = first.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
                let foldedTitle = cleanTitle.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
                if !foldedFirst.contains(foldedTitle) {
                    resultChunks.append(cleanTitle)
                    resultRatios.append(0.0)
                    hasPrependedTitle = true
                }
            } else {
                resultChunks.append(cleanTitle)
                resultRatios.append(0.0)
                hasPrependedTitle = true
            }
        }

        let maxChunkLen = 175

        for (lineIdx, rawLine) in rawLines.enumerated() {
            let linecleaned = Self.sanitizeLineForSpeech(rawLine)
            guard !linecleaned.isEmpty else { continue }

            let lineStartVisual = lineVisualStarts[lineIdx]
            let lineVisualHeight = max(1.0, ceil(Double(linecleaned.count) / charsPerVisualLine))
            let lineTotalChars = max(1, linecleaned.count)

            let lineSubChunks = splitCleanedLineIntoChunks(linecleaned, maxChunkLen: maxChunkLen)
            var consumedChars = 0

            for sub in lineSubChunks {
                let finalChunk = Self.sanitizeLineForSpeech(sub)
                guard !finalChunk.isEmpty else { continue }
                let progressInLine = min(1.0, Double(consumedChars) / Double(lineTotalChars))
                let chunkVisualY = lineStartVisual + progressInLine * lineVisualHeight
                let ratio = min(1.0, max(0.0, chunkVisualY / totalVisualLines))

                resultChunks.append(finalChunk)
                resultRatios.append(ratio)
                consumedChars += sub.count
            }
        }

        return (resultChunks, resultRatios, hasPrependedTitle)
    }

    private func splitCleanedLineIntoChunks(_ line: String, maxChunkLen: Int) -> [String] {
        if line.count <= maxChunkLen {
            return [line]
        }

        var output: [String] = []
        let sentences = line.components(separatedBy: CharacterSet(charactersIn: ".!?;"))
        var buf = ""

        for rawSentence in sentences {
            let s = Self.sanitizeLineForSpeech(rawSentence)
            guard !s.isEmpty else { continue }

            if s.count > maxChunkLen {
                if !buf.isEmpty {
                    output.append(buf)
                    buf = ""
                }
                let clauses = s.components(separatedBy: ",")
                var subBuf = ""
                for rawClause in clauses {
                    let c = Self.sanitizeLineForSpeech(rawClause)
                    guard !c.isEmpty else { continue }
                    let cand = subBuf.isEmpty ? c : "\(subBuf), \(c)"
                    if cand.count > maxChunkLen && !subBuf.isEmpty {
                        output.append(subBuf)
                        subBuf = c
                    } else {
                        subBuf = cand
                    }
                }
                if !subBuf.isEmpty {
                    if subBuf.count > maxChunkLen {
                        let extraWords = splitByWords(subBuf, maxLen: maxChunkLen)
                        for w in extraWords {
                            output.append(w)
                        }
                    } else {
                        output.append(subBuf)
                    }
                }
            } else {
                let cand = buf.isEmpty ? s : "\(buf). \(s)"
                if cand.count > maxChunkLen && !buf.isEmpty {
                    output.append(buf)
                    buf = s
                } else {
                    buf = cand
                }
            }
        }

        if !buf.isEmpty {
            output.append(buf)
        }
        return output
    }

    private func splitByWords(_ text: String, maxLen: Int) -> [String] {
        let words = text.components(separatedBy: " ")
        var chunks: [String] = []
        var current = ""
        for w in words where !w.isEmpty {
            let cand = current.isEmpty ? w : "\(current) \(w)"
            if cand.count > maxLen && !current.isEmpty {
                chunks.append(current)
                current = w
            } else {
                current = cand
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}

// MARK: - Gemini 3.1 / 2.5 Flash Native Audio TTS Client
private enum GeminiTTSClient {
    private static let stateLock = NSLock()
    private static var cooldownByModel: [String: TimeInterval] = [:]

    private static let candidateTTSModels: [String] = [
        "gemini-3.1-flash-tts-preview",
        "gemini-2.5-flash-preview-tts",
        "gemini-2.5-flash-lite-preview-tts"
    ]

    private static func isModelCoolingDown(_ model: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let until = cooldownByModel[model] else { return false }
        return Date().timeIntervalSince1970 < until
    }

    private static func markModelCooldown(_ model: String, seconds: TimeInterval) {
        stateLock.lock()
        cooldownByModel[model] = Date().timeIntervalSince1970 + seconds
        stateLock.unlock()
    }

    static func synthesize(text: String, voiceName: String, apiKey: String) async -> Data? {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !trimmed.isEmpty else {
            return nil
        }

        for model in candidateTTSModels {
            if isModelCoolingDown(model) {
                continue
            }
            let result = await callGeminiAudioEndpoint(
                model: model,
                text: trimmed,
                voiceName: voiceName,
                apiKey: cleanKey
            )
            switch result {
            case .success(let wavData):
                return wavData
            case .rateLimited:
                // Chỉ đánh dấu cooldown trên nhánh model bị 429 và thử ngay sang model TTS tiếp theo
                markModelCooldown(model, seconds: 22)
                continue
            case .tryNextModel:
                continue
            }
        }
        return nil
    }

    private enum CallResult {
        case success(Data)
        case rateLimited
        case tryNextModel
    }

    private static func callGeminiAudioEndpoint(
        model: String,
        text: String,
        voiceName: String,
        apiKey: String
    ) async -> CallResult {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return .tryNextModel }

        let part = GeminiTTSRequestPayload.Content.Part(text: text)
        let content = GeminiTTSRequestPayload.Content(parts: [part])
        let prebuilt = GeminiTTSRequestPayload.GenerationConfig.SpeechConfig.VoiceConfig.PrebuiltVoiceConfig(voiceName: voiceName)
        let voiceCfg = GeminiTTSRequestPayload.GenerationConfig.SpeechConfig.VoiceConfig(prebuiltVoiceConfig: prebuilt)
        let speechCfg = GeminiTTSRequestPayload.GenerationConfig.SpeechConfig(voiceConfig: voiceCfg)
        let genCfg = GeminiTTSRequestPayload.GenerationConfig(responseModalities: ["AUDIO"], speechConfig: speechCfg)
        let payload = GeminiTTSRequestPayload(contents: [content], generationConfig: genCfg)

        guard let bodyData = try? JSONEncoder().encode(payload) else {
            return .tryNextModel
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
            if statusCode == 429 || statusCode == 503 {
                return .rateLimited
            }
            guard (200...299).contains(statusCode) else {
                return .tryNextModel
            }

            guard let decoded = try? JSONDecoder().decode(GeminiTTSResponsePayload.self, from: data),
                  let parts = decoded.candidates?.first?.content?.parts else {
                return .tryNextModel
            }

            for item in parts {
                if let inlineData = item.inlineData,
                   let b64 = inlineData.data,
                   let rawAudio = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                   rawAudio.count > 200 {
                    let mime = (inlineData.mimeType ?? "").lowercased()
                    if mime.contains("wav") || isAlreadyContainerized(rawAudio) {
                        return .success(rawAudio)
                    } else {
                        let sampleRate = extractSampleRate(from: mime) ?? 24000
                        let wavData = wrapRawPCMInWAVHeader(
                            pcmData: rawAudio,
                            sampleRate: UInt32(sampleRate),
                            channels: 1,
                            bitsPerSample: 16
                        )
                        return .success(wavData)
                    }
                }
            }
            return .tryNextModel
        } catch {
            return .tryNextModel
        }
    }

    private static func extractSampleRate(from mimeType: String) -> Int? {
        guard let range = mimeType.range(of: #"rate=\d+"#, options: .regularExpression) else {
            return nil
        }
        let sub = mimeType[range].replacingOccurrences(of: "rate=", with: "")
        return Int(sub)
    }

    private static func isAlreadyContainerized(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic = String(data: data.subdata(in: 0..<4), encoding: .ascii) ?? ""
        if magic == "RIFF" || magic.hasPrefix("ID3") {
            return true
        }
        return false
    }

    static func wrapRawPCMInWAVHeader(
        pcmData: Data,
        sampleRate: UInt32 = 24000,
        channels: UInt16 = 1,
        bitsPerSample: UInt16 = 16
    ) -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let chunkSize = UInt32(36) + dataSize

        var header = Data(capacity: 44 + pcmData.count)
        header.append(Data("RIFF".utf8))
        header.append(uint32LE(chunkSize))
        header.append(Data("WAVE".utf8))
        header.append(Data("fmt ".utf8))
        header.append(uint32LE(16))
        header.append(uint16LE(1))
        header.append(uint16LE(channels))
        header.append(uint32LE(sampleRate))
        header.append(uint32LE(byteRate))
        header.append(uint16LE(blockAlign))
        header.append(uint16LE(bitsPerSample))
        header.append(Data("data".utf8))
        header.append(uint32LE(dataSize))
        header.append(pcmData)
        return header
    }

    private static func uint32LE(_ value: UInt32) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: 4)
    }

    private static func uint16LE(_ value: UInt16) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: 2)
    }
}

// MARK: - Microsoft Edge Neural TTS WebSocket Client (Chuẩn Sec-MS-GEC v2 <16-hex>-<64-hex> & 2-143.0.3650.75 theo edge-tts 7.3.1)
private enum EdgeNeuralTTSClient {
    private static let trustedToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let secMsGecVersion = "2-143.0.3650.75"
    private static let clockLock = NSLock()
    private static var serverTimeOffsetSeconds: TimeInterval = 0
    private static var hasSyncedServerClock: Bool = false

    private static let u32Mask: UInt64 = 0xFFFFFFFF

    private static let sha256Initial: [UInt64] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    ]

    private static let sha256State: [UInt64] = [
        0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A,
        0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2
    ]

    private static let sha256Schedule: [UInt64] = [
        0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA,
        0xA622EE8C, 0xD1DD9491, 0xC0DD25A0, 0xF9E70AB6,
        0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33,
        0xD258B060, 0x72766564
    ]

    private static let sha256RoundConstants: [UInt64] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
        0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
        0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
        0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
        0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
        0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
    ]

    private static let cs64CoeffA: [UInt64] = [
        0xE82E91B1, 0x44DE24C6, 0x3BEB65BC, 0xC89C5933,
        0x8D1EC211, 0x314EF5D5, 0xE92491B1, 0xF0A5B9D5,
        0x06064CF3, 0xDA79FA60, 0xBED20560, 0x89F9C9F8,
        0x35FA38C6, 0xCB49E3C6
    ]

    private static let cs64CoeffB: [UInt64] = [
        0xB32700D0, 0x88DFF51D, 0x29514038, 0xB328CBDF,
        0xD405B4D5, 0x26E55F3C, 0x607801C6, 0x82B2C1FB,
        0xFA51A3DA, 0x207CC464, 0x3C3C74F3, 0xD2D14B61,
        0xBB04A2C1, 0xC5626167
    ]

    static func synthesize(text: String, voiceName: String) async -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !isClockSynced() {
            await syncServerClock()
        }

        if let data = await attemptSynthesizeWithTimeout(text: trimmed, voiceName: voiceName, timeoutSeconds: 10.0),
           data.count > 200 {
            return data
        }

        await syncServerClock()
        if let retryData = await attemptSynthesizeWithTimeout(text: trimmed, voiceName: voiceName, timeoutSeconds: 10.0),
           retryData.count > 200 {
            return retryData
        }

        return nil
    }

    private static func isClockSynced() -> Bool {
        clockLock.lock()
        defer { clockLock.unlock() }
        return hasSyncedServerClock
    }

    private static func setServerClockOffset(_ offset: TimeInterval) {
        clockLock.lock()
        serverTimeOffsetSeconds = offset
        hasSyncedServerClock = true
        clockLock.unlock()
    }

    private static func currentSyncedTimestamp() -> TimeInterval {
        clockLock.lock()
        let offset = serverTimeOffsetSeconds
        clockLock.unlock()
        return Date().timeIntervalSince1970 + offset
    }

    private static func syncServerClock() async {
        let probeUrls = [
            "https://www.bing.com",
            "https://translate.googleapis.com"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        for urlStr in probeUrls {
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 3
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse,
                   let dateHeader = http.value(forHTTPHeaderField: "Date"),
                   let serverDate = df.date(from: dateHeader) {
                    let offset = serverDate.timeIntervalSince1970 - Date().timeIntervalSince1970
                    setServerClockOffset(offset)
                    return
                }
            } catch {
                continue
            }
        }
    }

    private static func attemptSynthesizeWithTimeout(
        text: String,
        voiceName: String,
        timeoutSeconds: Double
    ) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                await performWebSocketSynthesize(text: text, voiceName: voiceName)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return nil
            }
            let firstResult = await group.next() ?? nil
            group.cancelAll()
            return firstResult
        }
    }

    private static func performWebSocketSynthesize(text: String, voiceName: String) async -> Data? {
        let connectionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let nowTimestamp = currentSyncedTimestamp()
        let secMsGec = generateSecMsGecV2(timestamp: nowTimestamp)
        let urlString = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(trustedToken)&ConnectionId=\(connectionId)&Sec-MS-GEC=\(secMsGec)&Sec-MS-GEC-Version=\(secMsGecVersion)"
        guard let url = URL(string: urlString) else { return nil }

        let muid = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("muid=\(muid);", forHTTPHeaderField: "Cookie")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config)
        let ws = session.webSocketTask(with: request)
        ws.resume()

        return await withTaskCancellationHandler {
            defer {
                ws.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            }

            let timestamp = formatEdgeTimestamp(from: nowTimestamp)
            let configPayload = "X-Timestamp:\(timestamp)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"true\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"

            let escapedText = text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")

            let reqId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='\(voiceName)'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>\(escapedText)</prosody></voice></speak>"
            let ssmlPayload = "X-RequestId:\(reqId)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(timestamp)Z\r\nPath:ssml\r\n\r\n\(ssml)"

            do {
                try await ws.send(.string(configPayload))
                try await ws.send(.string(ssmlPayload))

                var audioBuffer = Data()
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    switch message {
                    case .string(let str):
                        if str.contains("Path:turn.end") {
                            return audioBuffer.isEmpty ? nil : audioBuffer
                        }
                    case .data(let data):
                        if data.count >= 2 {
                            let headerLen = (Int(data[0]) << 8) | Int(data[1])
                            let payloadStart = 2 + headerLen
                            if payloadStart < data.count {
                                let headerData = data.subdata(in: 2..<payloadStart)
                                if let headerStr = String(data: headerData, encoding: .utf8),
                                   headerStr.contains("Path:audio") {
                                    audioBuffer.append(data.subdata(in: payloadStart..<data.count))
                                }
                            }
                        }
                    @unknown default:
                        break
                    }
                }
                return nil
            } catch {
                return nil
            }
        } onCancel: {
            ws.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
    }

    // MARK: - Thuật toán Sec-MS-GEC v2 (<16-hex>-<64-hex>) chính xác theo rany2/edge-tts 7.3.1 drm.py
    private static func rol16(_ value: UInt64) -> UInt64 {
        let v = value & u32Mask
        return ((v << 16) | (v >> 16)) & u32Mask
    }

    private static func sigma0(_ value: UInt64) -> UInt64 {
        let s1 = (value >> 7) ^ (value << 25)
        let s2 = (value >> 18) ^ (value << 14)
        return (s1 ^ s2 ^ (value >> 3)) & u32Mask
    }

    private static func sigma1(_ value: UInt64) -> UInt64 {
        let s1 = (value >> 17) ^ (value << 15)
        let s2 = (value >> 19) ^ (value << 13)
        return (s1 ^ s2 ^ (value >> 10)) & u32Mask
    }

    private static func sha256Rounds(state: inout [UInt64], words: [UInt64], firstRound: Int) {
        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]

        for i in firstRound..<64 {
            let k: UInt64 = (firstRound == 14 && i == 14) ? 0xC9DC06A7 : sha256RoundConstants[i]
            let rotE = e &* 0x100000001
            let rotA = a &* 0x100000001
            let sumE = (rotE >> 6) ^ (rotE >> 11) ^ (rotE >> 25)
            let ch = g ^ (e & (f ^ g))
            let t1 = h &+ sumE &+ ch &+ k &+ words[i]
            let sumA = (rotA >> 2) ^ (rotA >> 13) ^ (rotA >> 22)
            let maj = (a & b) | (c & (a | b))
            let t2 = sumA &+ maj

            h = g
            g = f
            f = e
            e = (d &+ t1) & u32Mask
            d = c
            c = b
            b = a
            a = (t1 &+ t2) & u32Mask
        }

        state[0] = a
        state[1] = b
        state[2] = c
        state[3] = d
        state[4] = e
        state[5] = f
        state[6] = g
        state[7] = h
    }

    private static func expandSchedule(_ words: inout [UInt64], firstWord: Int) {
        for i in firstWord..<64 {
            let x = words[i - 2]
            let y = words[i - 15]
            let s1 = (x >> 17) ^ (x << 15) ^ (x >> 19) ^ (x << 13) ^ (x >> 10)
            let s0 = (y >> 7) ^ (y << 25) ^ (y >> 18) ^ (y << 14) ^ (y >> 3)
            let sum = s1 &+ words[i - 7] &+ s0 &+ words[i - 16]
            words[i] = sum & u32Mask
        }
    }

    static func generateSecMsGecV2(timestamp: TimeInterval) -> String {
        let winEpochOffset: Int64 = 11_644_473_600
        let unixSeconds = Int64(timestamp)
        let totalSeconds = unixSeconds + winEpochOffset
        let roundedSeconds = totalSeconds - (totalSeconds % 300)
        let fileTime = roundedSeconds * 10_000_000
        let rawString = "\(fileTime)\(trustedToken)"
        let dataBytes = Array(rawString.utf8)
        guard dataBytes.count >= 7 else { return "" }

        // 1. _sha256_init(data[:7])
        var initWords = [UInt64](repeating: 0, count: 64)
        initWords[14] = (UInt64(dataBytes[0]) << 16) | (UInt64(dataBytes[1]) << 8) | UInt64(dataBytes[2])
        initWords[15] = (UInt64(dataBytes[3]) << 24) | (UInt64(dataBytes[4]) << 16) | (UInt64(dataBytes[5]) << 8) | UInt64(dataBytes[6])

        for i in 16..<30 {
            var v = sha256Schedule[i - 16]
            if i - 2 >= 14 {
                let s1 = sigma1(initWords[i - 2])
                v = v &+ ((i == 16) ? (s1 ^ 0x000B92C0) : s1)
            }
            if i - 7 >= 14 {
                v = v &+ initWords[i - 7]
            }
            if i - 15 >= 14 {
                let s0 = sigma0(initWords[i - 15])
                v = v &+ ((i == 29) ? (s0 ^ 0x059C0B80) : s0)
            }
            initWords[i] = v & u32Mask
        }

        let w30 = sigma1(initWords[28]) &+ initWords[23] &+ sigma0(initWords[15]) &+ initWords[14] &+ 0xC9DC06A7 &- sha256RoundConstants[14]
        initWords[30] = w30 & u32Mask
        expandSchedule(&initWords, firstWord: 31)

        var working = sha256State
        sha256Rounds(state: &working, words: initWords, firstRound: 14)

        var state = [UInt64](repeating: 0, count: 8)
        for i in 0..<8 {
            state[i] = (sha256Initial[i] &+ working[i]) & u32Mask
        }

        // 2. _sha256_digest(data)
        let totalLen = 57 + dataBytes.count
        let remBytes = Array(dataBytes[7..<dataBytes.count])
        let padZeros = ((55 - (totalLen % 64)) % 64 + 64) % 64

        var padded = [UInt8]()
        padded.reserveCapacity(remBytes.count + 1 + padZeros + 8)
        padded.append(contentsOf: remBytes)
        padded.append(0x80)
        for _ in 0..<padZeros {
            padded.append(0x00)
        }
        let bitLen = UInt64(totalLen) * 8
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLen >> UInt64(shift)) & 0xFF))
        }

        var offset = 0
        while offset < padded.count {
            var blockWords = [UInt64](repeating: 0, count: 64)
            for i in 0..<16 {
                let p = offset + i * 4
                let b0 = UInt64(padded[p]) << 24
                let b1 = UInt64(padded[p + 1]) << 16
                let b2 = UInt64(padded[p + 2]) << 8
                let b3 = UInt64(padded[p + 3])
                blockWords[i] = b0 | b1 | b2 | b3
            }
            expandSchedule(&blockWords, firstWord: 16)
            var blkWorking = state
            sha256Rounds(state: &blkWorking, words: blockWords, firstRound: 0)
            for i in 0..<8 {
                state[i] = (state[i] &+ blkWorking[i]) & u32Mask
            }
            offset += 64
        }

        var digestBytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            let word = state[i]
            digestBytes[i * 4 + 0] = UInt8((word >> 24) & 0xFF)
            digestBytes[i * 4 + 1] = UInt8((word >> 16) & 0xFF)
            digestBytes[i * 4 + 2] = UInt8((word >> 8) & 0xFF)
            digestBytes[i * 4 + 3] = UInt8(word & 0xFF)
        }

        // 3. _cs64_digest(data, digest)
        var keyA = UInt64(digestBytes[0]) | (UInt64(digestBytes[1]) << 8) | (UInt64(digestBytes[2]) << 16) | (UInt64(digestBytes[3]) << 24)
        var keyB = UInt64(digestBytes[4]) | (UInt64(digestBytes[5]) << 8) | (UInt64(digestBytes[6]) << 16) | (UInt64(digestBytes[7]) << 24)
        keyA |= 1
        keyB |= 1

        let factor0 = (keyA &* 0x82893933) & u32Mask
        let factor1 = (keyB &* 0x82893933) & u32Mask

        var terms = [UInt64]()
        var offsets = [UInt64]()
        for i in 0..<14 {
            let f = (i % 2 == 0) ? factor0 : factor1
            terms.append((cs64CoeffA[i] &* f) & u32Mask)
            offsets.append(cs64CoeffB[i])
        }

        var prefixed = [UInt8]()
        prefixed.append(0x00)
        prefixed.append(contentsOf: dataBytes)
        while prefixed.count % 4 != 0 {
            prefixed.append(0x00)
        }

        var leWords = [UInt64]()
        var pIdx = 0
        while pIdx < prefixed.count {
            let w = UInt64(prefixed[pIdx]) | (UInt64(prefixed[pIdx + 1]) << 8) | (UInt64(prefixed[pIdx + 2]) << 16) | (UInt64(prefixed[pIdx + 3]) << 24)
            leWords.append(w)
            pIdx += 4
        }
        if leWords.count % 2 == 1 {
            leWords.append(0)
        }

        for (idx, word) in leWords.enumerated() {
            let k = (idx % 2 == 0) ? keyA : keyB
            let c: UInt64 = (idx % 2 == 0) ? 0xEF0569FB : 0xC31713DB
            var term = word &* k
            var off = rol16(word) &* c
            if idx == 0 {
                term = term &+ (0xF2F90B1A &* factor0)
                off = off &+ 0x0B1A0000
            }
            terms.append(term & u32Mask)
            offsets.append(off & u32Mask)
        }

        var swapAcc: UInt64 = 0
        var swapLast: UInt64 = 0
        var st: UInt64 = 0
        var acc: UInt64 = 0

        var tIdx = 0
        while tIdx < terms.count {
            let x = terms[tIdx]
            let y = terms[tIdx + 1]

            let t0 = rol16((offsets[tIdx] &+ x) & u32Mask)
            let q0 = (t0 &* 0x76F50F34) & u32Mask
            swapAcc = swapAcc &+ ((rol16(q0) &* 0xC3EFEA97 &+ q0) & u32Mask)

            let t1 = rol16((offsets[tIdx + 1] &+ y) & u32Mask)
            let q1 = (t1 &* 0x1881CE3C) & u32Mask
            swapLast = (rol16(q1) &* 0x35BD1EC9 &+ q1) & u32Mask
            swapAcc = (swapAcc &+ swapLast) & u32Mask

            st = (st &* keyA &+ x) & u32Mask
            st = (rol16(st) &* 0xCF98B111) & u32Mask
            st = (rol16(st) &* 0x87085B9F) & u32Mask
            st = (rol16(st) &* 0x12CEB96D) & u32Mask
            st = (rol16(st) &* 0x257E1D83) & u32Mask
            acc = acc &+ st

            var tm = (st &* keyB &+ y) & u32Mask
            tm = (rol16(tm) &* 0xA27416F5) & u32Mask
            tm = (rol16(tm) &* 0xD38396FF) & u32Mask
            let inner = (rol16(tm) &* 0x7C932B89) & u32Mask
            st = (rol16(inner) &* 0xBFA49F69) & u32Mask
            acc = (acc &+ st) & u32Mask

            tIdx += 2
        }

        let cs0 = (swapLast ^ st) & u32Mask
        let cs1 = (swapAcc ^ acc) & u32Mask
        let csBytes: [UInt8] = [
            UInt8(cs0 & 0xFF), UInt8((cs0 >> 8) & 0xFF), UInt8((cs0 >> 16) & 0xFF), UInt8((cs0 >> 24) & 0xFF),
            UInt8(cs1 & 0xFF), UInt8((cs1 >> 8) & 0xFF), UInt8((cs1 >> 16) & 0xFF), UInt8((cs1 >> 24) & 0xFF)
        ]

        var csHex = ""
        for b in csBytes {
            csHex += String(format: "%02X", b)
        }
        var shaHex = ""
        for b in digestBytes {
            shaHex += String(format: "%02X", b)
        }
        return "\(csHex)-\(shaHex)"
    }

    private static func formatEdgeTimestamp(from timestamp: TimeInterval) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "EEE MMM dd yyyy HH:mm:ss"
        let base = df.string(from: Date(timeIntervalSince1970: timestamp))
        return "\(base) GMT+0000 (Coordinated Universal Time)"
    }
}

// MARK: - Google Cloud / Translate TTS Multi-Endpoint Client
private enum GoogleTranslateTTSClient {
    static func synthesize(text: String) async -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let subSegments = splitForGoogleLimit(trimmed, maxLen: 150)
        var combinedAudio = Data()

        for segment in subSegments {
            guard let segmentData = await fetchSingleSegmentAudio(segment),
                  segmentData.count > 150 else {
                return combinedAudio.isEmpty ? nil : combinedAudio
            }
            combinedAudio.append(segmentData)
        }

        return combinedAudio.count > 200 ? combinedAudio : nil
    }

    private static func buildCandidateURLs(for segment: String) -> [URL] {
        var urls: [URL] = []

        if var c1 = URLComponents(string: "https://translate.googleapis.com/translate_tts") {
            c1.queryItems = [
                URLQueryItem(name: "client", value: "gtx"),
                URLQueryItem(name: "ie", value: "UTF-8"),
                URLQueryItem(name: "tl", value: "vi"),
                URLQueryItem(name: "dt", value: "t"),
                URLQueryItem(name: "q", value: segment)
            ]
            if let u = c1.url { urls.append(u) }
        }

        if var c2 = URLComponents(string: "https://translate.google.com/translate_tts") {
            c2.queryItems = [
                URLQueryItem(name: "ie", value: "UTF-8"),
                URLQueryItem(name: "tl", value: "vi"),
                URLQueryItem(name: "client", value: "tw-ob"),
                URLQueryItem(name: "ttsspeed", value: "1"),
                URLQueryItem(name: "total", value: "1"),
                URLQueryItem(name: "idx", value: "0"),
                URLQueryItem(name: "textlen", value: "\(segment.count)"),
                URLQueryItem(name: "q", value: segment)
            ]
            if let u = c2.url { urls.append(u) }
        }

        if var c3 = URLComponents(string: "https://clients5.google.com/translate_tts") {
            c3.queryItems = [
                URLQueryItem(name: "ie", value: "UTF-8"),
                URLQueryItem(name: "tl", value: "vi"),
                URLQueryItem(name: "client", value: "dict-chrome-ex"),
                URLQueryItem(name: "q", value: segment)
            ]
            if let u = c3.url { urls.append(u) }
        }

        return urls
    }

    private static func fetchSingleSegmentAudio(_ segment: String) async -> Data? {
        let candidateUrls = buildCandidateURLs(for: segment)

        for url in candidateUrls {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            request.setValue("https://translate.google.com/", forHTTPHeaderField: "Referer")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      data.count > 200 else {
                    continue
                }
                let mime = (http.mimeType ?? "").lowercased()
                if mime.contains("html") || mime.contains("text") {
                    continue
                }
                return data
            } catch {
                continue
            }
        }
        return nil
    }

    private static func splitForGoogleLimit(_ text: String, maxLen: Int) -> [String] {
        if text.count <= maxLen {
            return [text]
        }
        var results: [String] = []
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: ",.;!?"))
        var current = ""
        for raw in clauses {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            let candidate = current.isEmpty ? part : "\(current), \(part)"
            if candidate.count > maxLen && !current.isEmpty {
                results.append(current)
                current = part
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            results.append(current)
        }
        return results.isEmpty ? [String(text.prefix(maxLen))] : results
    }
}
