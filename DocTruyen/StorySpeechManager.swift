import Foundation
import AVFoundation
import MediaPlayer
import CryptoKit
import Combine

enum StoryVoiceChoice: String, CaseIterable, Identifiable, Codable {
    case namMinh = "vi-VN-NamMinhNeural"
    case hoaiMy = "vi-VN-HoaiMyNeural"
    case googleVi = "google-vi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .namMinh: return "Nam Minh (AI Trầm ấm)"
        case .hoaiMy: return "Hoài My (AI Truyền cảm)"
        case .googleVi: return "Google Tiếng Việt (AI)"
        }
    }

    var shortName: String {
        switch self {
        case .namMinh: return "Nam Minh AI"
        case .hoaiMy: return "Hoài My AI"
        case .googleVi: return "Google AI"
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
    private var prefetchTasks: [Int: Task<Data?, Never>] = [:]
    private var playSessionToken: UUID = UUID()
    private var consecutiveFailures: Int = 0

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
        // Nếu người dùng đang ở đầu chương (chưa cuộn xuống đáng kể) -> đọc từ đầu (chunk 0)
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

    // MARK: - Phát từng đoạn (100% Giọng đọc AI trực tuyến, tuyệt đối không dùng giọng ngoại tuyến)
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
                    self.onError?("Không thể kết nối giọng đọc AI. Vui lòng kiểm tra kết nối mạng.")
                }
            }
        }
    }

    private func prefetchUpcomingChunks(after index: Int, voice: StoryVoiceChoice, sessionToken: UUID) {
        for offset in 1...2 {
            let targetIdx = index + offset
            guard targetIdx < chunks.count else { break }
            if prefetchedAudioCache[targetIdx] != nil || prefetchTasks[targetIdx] != nil { continue }

            let targetText = chunks[targetIdx]
            let task = Task<Data?, Never> {
                let data = await Self.synthesizeSpeechData(text: targetText, voice: voice)
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
        return await Self.synthesizeSpeechData(text: text, voice: voice)
    }

    private static func synthesizeSpeechData(text: String, voice: StoryVoiceChoice) async -> Data? {
        let cleaned = sanitizeLineForSpeech(text)
        guard !cleaned.isEmpty else { return nil }

        if voice == .namMinh || voice == .hoaiMy {
            if let edgeData = await EdgeNeuralTTSClient.synthesize(text: cleaned, voiceName: voice.rawValue),
               edgeData.count > 200 {
                return edgeData
            }
        }
        if let googleData = await GoogleTranslateTTSClient.synthesize(text: cleaned),
           googleData.count > 200 {
            return googleData
        }
        if voice == .googleVi {
            if let edgeFallback = await EdgeNeuralTTSClient.synthesize(text: cleaned, voiceName: StoryVoiceChoice.namMinh.rawValue),
               edgeFallback.count > 200 {
                return edgeFallback
            }
        }
        return nil
    }

    @discardableResult
    private func playAudioData(_ data: Data, voiceLabel: String) -> Bool {
        audioPlayer?.stop()
        audioPlayer = nil

        if let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue) {
            player.delegate = self
            player.enableRate = true
            player.rate = Float(min(2.0, max(0.6, playbackSpeedMultiplier)))
            player.prepareToPlay()
            if player.play() {
                audioPlayer = player
                activeVoiceLabel = voiceLabel
                updateNowPlayingInfo()
                return true
            }
        }

        if let player = try? AVAudioPlayer(data: data) {
            player.delegate = self
            player.enableRate = true
            player.rate = Float(min(2.0, max(0.6, playbackSpeedMultiplier)))
            player.prepareToPlay()
            if player.play() {
                audioPlayer = player
                activeVoiceLabel = voiceLabel
                updateNowPlayingInfo()
                return true
            }
        }

        // Fallback ghi ra file tạm .mp3 cho các luồng MPEG raw không có ID3 header
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("doctruyen_tts_chunk.mp3")
        do {
            try data.write(to: tempURL, options: .atomic)
            let player = try AVAudioPlayer(contentsOf: tempURL)
            player.delegate = self
            player.enableRate = true
            player.rate = Float(min(2.0, max(0.6, playbackSpeedMultiplier)))
            player.prepareToPlay()
            if player.play() {
                audioPlayer = player
                activeVoiceLabel = voiceLabel
                updateNowPlayingInfo()
                return true
            }
        } catch {
            return false
        }
        return false
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

        // 1. Bỏ tiêu đề markdown đầu dòng (### ...)
        if let r = s.range(of: #"^#{1,6}\s*"#, options: .regularExpression) {
            s.removeSubrange(r)
        }

        // 2. Loại bỏ toàn bộ dấu ngoặc kép, ngoặc truyện và các ký tự trang trí để app không đọc tên ký tự
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

        // 3. Nếu cả dòng chỉ là dòng kẻ phân cách (===, ---, ***, ___, ~~~, ===o0o===, ...)
        if s.range(of: #"^[\s=\-\*_~•·\.…o0O\+<>\|/]+$"#, options: .regularExpression) != nil {
            return ""
        }

        // 4. Thay dấu ba chấm (..., …) và gạch ngang dài (---, —, –) bằng dấu phẩy ngắt nhịp tự nhiên
        s = s.replacingOccurrences(of: #"(\.{2,}|…+)"#, with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\-{2,}|—+|–+)"#, with: ", ", options: .regularExpression)

        // 5. Dọn các dấu câu bị lặp hoặc đứng đầu/cuối câu
        s = s.replacingOccurrences(of: #"(\s*,\s*){2,}"#, with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[,\s]+([.!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([.!?])\s*,+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[\s,.;:\-!?]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[\s,]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // 6. Chỉ giữ lại nếu có ít nhất 1 chữ cái hoặc chữ số
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

        // Tính tổng số dòng hiển thị ước lượng (bao gồm cả dòng trống giống hệt Text trong ScrollView)
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

        let maxChunkLen = 180

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

// MARK: - Microsoft Edge Neural TTS WebSocket Client (Đã sửa lỗi tràn số thực Sec-MS-GEC & đồng bộ giờ Server)
private enum EdgeNeuralTTSClient {
    private static let trustedToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let secMsGecVersion = "1-132.0.2957.140"
    private static let clockLock = NSLock()
    private static var serverTimeOffsetSeconds: TimeInterval = 0
    private static var hasSyncedServerClock: Bool = false

    static func synthesize(text: String, voiceName: String) async -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !isClockSynced() {
            await syncServerClock()
        }

        if let data = await attemptSynthesizeWithTimeout(text: trimmed, voiceName: voiceName, timeoutSeconds: 6.5) {
            return data
        }

        // Nếu lần 1 lỗi (có thể do lệch đồng hồ), ép đồng bộ lại giờ thực từ máy chủ rồi thử lại 1 lần
        await syncServerClock()
        return await attemptSynthesizeWithTimeout(text: trimmed, voiceName: voiceName, timeoutSeconds: 6.5)
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
            req.timeoutInterval = 4
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

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36 Edg/132.0.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        let ws = session.webSocketTask(with: request)
        ws.resume()

        defer {
            ws.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        let timestamp = formatEdgeTimestamp(from: nowTimestamp)
        let configPayload = "X-Timestamp:\(timestamp)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}"

        let escapedText = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")

        let reqId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='vi-VN'><voice name='\(voiceName)'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>\(escapedText)</prosody></voice></speak>"
        let ssmlPayload = "X-RequestId:\(reqId)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(timestamp)\r\nPath:ssml\r\n\r\n\(ssml)"

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
    }

    /// Tính toán Sec-MS-GEC bằng số nguyên Int64 chính xác tuyệt đối (không bị sai số dấu phẩy động Double)
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

// MARK: - Google Cloud / Translate TTS Multi-Endpoint Client
private enum GoogleTranslateTTSClient {
    static func synthesize(text: String) async -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let subSegments = splitForGoogleLimit(trimmed, maxLen: 165)
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

    private static func fetchSingleSegmentAudio(_ segment: String) async -> Data? {
        let encoded = segment.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard !encoded.isEmpty else { return nil }

        let candidateUrls = [
            "https://translate.googleapis.com/translate_tts?client=gtx&ie=UTF-8&tl=vi&dt=t&q=\(encoded)",
            "https://translate.google.com/translate_tts?ie=UTF-8&tl=vi&client=dict-chrome-ex&ttsspeed=1&q=\(encoded)",
            "https://clients5.google.com/translate_tts?ie=UTF-8&tl=vi&client=dict-chrome-ex&q=\(encoded)",
            "https://translate.google.com/translate_tts?ie=UTF-8&tl=vi&client=tw-ob&q=\(encoded)"
        ]

        for urlStr in candidateUrls {
            guard let url = URL(string: urlStr) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 7
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
