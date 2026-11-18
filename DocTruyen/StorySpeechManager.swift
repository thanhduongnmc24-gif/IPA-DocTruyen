import Foundation
import AVFoundation
import MediaPlayer
import CryptoKit
import Combine

enum StoryVoiceChoice: String, CaseIterable, Identifiable, Codable {
    case geminiKore = "gemini-kore"
    case geminiPuck = "gemini-puck"
    case namMinh = "vi-VN-NamMinhNeural"
    case hoaiMy = "vi-VN-HoaiMyNeural"
    case googleVi = "google-vi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .geminiKore: return "Gemini AI Nữ (Truyền cảm)"
        case .geminiPuck: return "Gemini AI Nam (Trầm ấm)"
        case .namMinh: return "Nam Minh (AI Trầm ấm)"
        case .hoaiMy: return "Hoài My (AI Truyền cảm)"
        case .googleVi: return "Google Tiếng Việt (AI)"
        }
    }

    var shortName: String {
        switch self {
        case .geminiKore: return "Gemini Nữ"
        case .geminiPuck: return "Gemini Nam"
        case .namMinh: return "Nam Minh AI"
        case .hoaiMy: return "Hoài My AI"
        case .googleVi: return "Google AI"
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

    @Published var selectedVoiceChoice: StoryVoiceChoice = .geminiKore {
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
    private var prefetchTasks: [Int: Task<Data?, Never>] = [:]
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
            selectedVoiceChoice = .geminiKore
            UserDefaults.standard.set(StoryVoiceChoice.geminiKore.rawValue, forKey: "DOC_TRUYEN_SPEECH_VOICE_CHOICE")
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
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentChapterTitle.isEmpty ? "Đọc Truyện AI" : currentChapterTitle,
            MPMediaItemPropertyArtist: selectedVoiceChoice.shortName,
            MPNowPlayingInfoPropertyPlaybackRate: (isSpeaking && !isPaused) ? playbackSpeedMultiplier : 0.0
        ]
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
        for (_, task) in prefetchTasks { task.cancel() }
        prefetchTasks.removeAll()
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
        for (_, task) in prefetchTasks { task.cancel() }
        prefetchTasks.removeAll()
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

    // MARK: - Phát từng đoạn (Kết hợp Gemini AI TTS -> Edge Neural AI -> Google AI, không dùng giọng ngoại tuyến)
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
                prefetchUpcomingChunks(after: chunkIdx, voice: voiceMode, sessionToken: sessionToken)
                return
            }
        }

        isBuffering = true
        Task {
            let audioData = await resolveOnlineSpeechData(index: chunkIdx, text: text, voice: voiceMode)
            guard self.playSessionToken == sessionToken, self.isSpeaking, !self.isPaused else { return }
            self.isBuffering = false

            if let audioData, self.playAudioData(audioData, voiceLabel: voiceMode.shortName) {
                self.consecutiveFailures = 0
                self.prefetchUpcomingChunks(after: chunkIdx, voice: voiceMode, sessionToken: sessionToken)
            } else {
                self.consecutiveFailures += 1
                if self.consecutiveFailures < 3 && self.currentChunkIndex + 1 < self.chunks.count {
                    self.currentChunkIndex += 1
                    self.playCurrentChunk()
                } else {
                    self.stopInternal(resetTitle: false)
                    self.onError?("Không thể tải âm thanh giọng đọc AI. Vui lòng kiểm tra kết nối mạng hoặc Gemini API Key.")
                }
            }
        }
    }

    private func prefetchUpcomingChunks(after index: Int, voice: StoryVoiceChoice, sessionToken: UUID) {
        let apiKey = Self.currentSavedGeminiApiKey
        for offset in 1...2 {
            let targetIdx = index + offset
            guard targetIdx < chunks.count else { break }
            if prefetchedAudioCache[targetIdx] != nil || prefetchTasks[targetIdx] != nil { continue }

            let targetText = chunks[targetIdx]
            let task = Task<Data?, Never> {
                let data = await Self.synthesizeSpeechData(text: targetText, voice: voice, geminiApiKey: apiKey)
                if !Task.isCancelled, self.playSessionToken == sessionToken, let data {
                    self.prefetchedAudioCache[targetIdx] = data
                }
                self.prefetchTasks.removeValue(forKey: targetIdx)
                return data
            }
            prefetchTasks[targetIdx] = task
        }
    }

    private func resolveOnlineSpeechData(index: Int, text: String, voice: StoryVoiceChoice) async -> Data? {
        if let cached = prefetchedAudioCache[index] {
            prefetchedAudioCache.removeValue(forKey: index)
            return cached
        }
        if let existingTask = prefetchTasks[index] {
            if let data = await existingTask.value {
                return data
            }
        }
        let apiKey = Self.currentSavedGeminiApiKey
        return await Self.synthesizeSpeechData(text: text, voice: voice, geminiApiKey: apiKey)
    }

    private static func synthesizeSpeechData(
        text: String,
        voice: StoryVoiceChoice,
        geminiApiKey: String
    ) async -> Data? {
        let cleaned = sanitizeLineForSpeech(text)
        guard !cleaned.isEmpty else { return nil }

        switch voice {
        case .geminiKore, .geminiPuck:
            // 1. Ưu tiên gọi trực tiếp Gemini 2.5 Flash TTS bằng API Key người dùng đã nhập
            if !geminiApiKey.isEmpty {
                if let geminiAudio = await GeminiTTSClient.synthesize(
                    text: cleaned,
                    voiceName: voice.geminiVoiceName,
                    apiKey: geminiApiKey
                ), geminiAudio.count > 200 {
                    return geminiAudio
                }
            }
            // 2. Dự phòng tức thì sang Edge Neural AI cùng giới tính giọng
            if let edgeData = await EdgeNeuralTTSClient.synthesize(text: cleaned, voiceName: voice.edgeVoiceName),
               edgeData.count > 200 {
                return edgeData
            }
            // 3. Dự phòng cuối sang Google Cloud / Translate TTS
            if let googleData = await GoogleTranslateTTSClient.synthesize(text: cleaned),
               googleData.count > 200 {
                return googleData
            }

        case .namMinh, .hoaiMy:
            // 1. Ưu tiên Edge Neural AI (Nam Minh / Hoài My)
            if let edgeData = await EdgeNeuralTTSClient.synthesize(text: cleaned, voiceName: voice.edgeVoiceName),
               edgeData.count > 200 {
                return edgeData
            }
            // 2. Nếu mạng chặn WebSocket Edge -> Gọi Gemini AI TTS
            if !geminiApiKey.isEmpty {
                if let geminiAudio = await GeminiTTSClient.synthesize(
                    text: cleaned,
                    voiceName: voice.geminiVoiceName,
                    apiKey: geminiApiKey
                ), geminiAudio.count > 200 {
                    return geminiAudio
                }
            }
            // 3. Dự phòng sang Google Cloud / Translate TTS
            if let googleData = await GoogleTranslateTTSClient.synthesize(text: cleaned),
               googleData.count > 200 {
                return googleData
            }

        case .googleVi:
            if let googleData = await GoogleTranslateTTSClient.synthesize(text: cleaned),
               googleData.count > 200 {
                return googleData
            }
            if !geminiApiKey.isEmpty {
                if let geminiAudio = await GeminiTTSClient.synthesize(
                    text: cleaned,
                    voiceName: "Kore",
                    apiKey: geminiApiKey
                ), geminiAudio.count > 200 {
                    return geminiAudio
                }
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

        // Ưu tiên ghi ra file tạm luân phiên (.wav / .mp3) để AVAudioPlayer trên iOS đọc header chính xác 100%
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

    // MARK: - Làm sạch ký tự đặc biệt (===, ..., ", —, ***) & Chia đoạn kèm tỷ lệ vị trí cuộn
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
        s = s.replacingOccurrences(of: #"[\s,]+"#, with: " ", options: .regularExpression)
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

        let maxChunkLen = 220

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
                    output.append(subBuf)
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
}

// MARK: - Gemini 2.5 Flash Native Audio TTS Client (Bọc chuẩn RIFF/WAV 24kHz 16-bit PCM cho AVAudioPlayer)
private enum GeminiTTSClient {
    private static let stateLock = NSLock()
    private static var quotaCooldownUntil: TimeInterval = 0

    private static let candidateTTSModels = [
        "gemini-2.5-flash-preview-tts",
        "gemini-2.5-flash-tts"
    ]

    private static func isInQuotaCooldown() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Date().timeIntervalSince1970 < quotaCooldownUntil
    }

    private static func markQuotaCooldown(seconds: TimeInterval) {
        stateLock.lock()
        quotaCooldownUntil = Date().timeIntervalSince1970 + seconds
        stateLock.unlock()
    }

    static func synthesize(text: String, voiceName: String, apiKey: String) async -> Data? {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !trimmed.isEmpty, !isInQuotaCooldown() else {
            return nil
        }

        for model in candidateTTSModels {
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
                // Tạm chuyển sang Edge Neural / Google trong 20s để không bị ngắt quãng khi chạm RPM
                markQuotaCooldown(seconds: 20)
                return nil
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

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": "Đọc diễn cảm tiếng Việt đoạn văn sau: \(text)"]
                    ]
                ]
            ],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": voiceName
                        ]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return .tryNextModel
        }
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

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                return .tryNextModel
            }

            for part in parts {
                if let inlineData = part["inlineData"] as? [String: Any],
                   let b64 = inlineData["data"] as? String,
                   let rawAudio = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                   rawAudio.count > 200 {
                    let mime = ((inlineData["mimeType"] as? String) ?? "").lowercased()
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

    /// Đóng gói dữ liệu PCM 16-bit signed little-endian nguyên bản của Gemini thành file WAV chuẩn RIFF (44-byte header)
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
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.append(uint32LE(chunkSize))
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.append(uint32LE(16))                         // Subchunk1Size (16 for PCM)
        header.append(uint16LE(1))                          // AudioFormat (1 = PCM)
        header.append(uint16LE(channels))
        header.append(uint32LE(sampleRate))
        header.append(uint32LE(byteRate))
        header.append(uint16LE(blockAlign))
        header.append(uint16LE(bitsPerSample))
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
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

// MARK: - Microsoft Edge Neural TTS WebSocket Client (Có Cookie MUID + withTaskCancellationHandler chống treo)
private enum EdgeNeuralTTSClient {
    private static let trustedToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let secMsGecVersion = "1-130.0.2849.68"
    private static let clockLock = NSLock()
    private static var serverTimeOffsetSeconds: TimeInterval = 0
    private static var hasSyncedServerClock: Bool = false

    static func synthesize(text: String, voiceName: String) async -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !isClockSynced() {
            await syncServerClock()
        }

        return await attemptSynthesizeWithTimeout(text: trimmed, voiceName: voiceName, timeoutSeconds: 4.0)
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
        let secMsGec = generateSecMsGec(timestamp: nowTimestamp)
        let urlString = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(trustedToken)&Sec-MS-GEC=\(secMsGec)&Sec-MS-GEC-Version=\(secMsGecVersion)&ConnectionId=\(connectionId)"
        guard let url = URL(string: urlString) else { return nil }

        let muid = (0..<32).map { _ in String(format: "%X", Int.random(in: 0...15)) }.joined()
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("MUID=\(muid);", forHTTPHeaderField: "Cookie")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        let ws = session.webSocketTask(with: request)
        ws.resume()

        return await withTaskCancellationHandler {
            defer {
                ws.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            }

            let timestamp = formatEdgeTimestamp(from: nowTimestamp)
            let configPayload = "X-Timestamp:\(timestamp)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"

            let escapedText = text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")

            let reqId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='vi-VN'><voice name='\(voiceName)'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>\(escapedText)</prosody></voice></speak>"
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

    private static func generateSecMsGec(timestamp: TimeInterval) -> String {
        let winEpochOffset: Int64 = 11_644_473_600
        let unixSeconds = Int64(timestamp)
        let totalSeconds = unixSeconds + winEpochOffset
        let roundedSeconds = totalSeconds - (totalSeconds % 300)
        let fileTime = roundedSeconds * 10_000_000
        let raw = "\(fileTime)\(trustedToken)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
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

// MARK: - Google Cloud / Translate TTS Multi-Endpoint Client (Dùng URLComponents chuẩn xác 100%)
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
