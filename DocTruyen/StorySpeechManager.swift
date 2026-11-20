import Foundation
import AVFoundation
import MediaPlayer
import CryptoKit
import Combine
import Network
import Security

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

    var isAIVoice: Bool {
        switch self {
        case .namMinh, .hoaiMy, .geminiKore, .geminiPuck:
            return true
        case .googleVi:
            return false
        }
    }
}

// MARK: - Codable Struct chuẩn cho Gemini TTS (Tránh hoàn toàn lỗi treo trình biên dịch Swiftc)
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

    /// Các mốc thời gian hẹn giờ tắt (tính bằng phút) theo đúng yêu cầu: 5, 10, 15, 30, 45, 60
    static let sleepTimerPresets: [Int] = [5, 10, 15, 30, 45, 60]

    @Published var isSpeaking: Bool = false
    @Published var isPaused: Bool = false
    @Published var isBuffering: Bool = false
    @Published var currentChunkIndex: Int = 0
    @Published var totalChunks: Int = 0
    @Published var currentChapterTitle: String = ""
    @Published var activeVoiceLabel: String = ""

    // MARK: - Trạng thái Hẹn giờ tắt (Sleep Timer)
    @Published var activeSleepTimerMinutes: Int? = nil
    @Published var sleepTimerRemainingSeconds: Int = 0
    private var sleepTimerEndDate: Date? = nil
    private var sleepTimerTicker: Timer? = nil

    @Published var selectedVoiceChoice: StoryVoiceChoice = .namMinh {
        didSet {
            UserDefaults.standard.set(selectedVoiceChoice.rawValue, forKey: "DOC_TRUYEN_SPEECH_VOICE_CHOICE")
            if isSpeaking {
                cancelAllPrefetchAndCache()
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
    var onSleepTimerExpired: (() -> Void)?

    private var audioPlayer: AVAudioPlayer?
    private var currentRawText: String = ""
    private var chunks: [String] = []
    private var chunkStartRatios: [Double] = []
    private var hasPrependedTitleChunk: Bool = false

    /// Bộ nhớ đệm âm thanh đã tải sẵn trong RAM (chỉ lưu âm thanh chuẩn của giọng AI đã chọn)
    private var prefetchedAudioCache: [Int: Data] = [:]
    /// Danh sách các Task đang tải dở của từng đoạn — tái sử dụng kết quả đang tải, không tải trùng
    private var inFlightTasks: [Int: Task<Data?, Never>] = [:]
    private var prefetchCoordinatorTask: Task<Void, Never>?
    private var playSessionToken: UUID = UUID()
    private var consecutiveFailures: Int = 0
    private var tempFileToggle: Int = 0

    var isSleepTimerActive: Bool {
        sleepTimerEndDate != nil && sleepTimerRemainingSeconds > 0
    }

    var formattedSleepTimerCountdown: String {
        guard sleepTimerRemainingSeconds > 0 else { return "" }
        let mins: Int = sleepTimerRemainingSeconds / 60
        let secs: Int = sleepTimerRemainingSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

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

    // MARK: - Điều khiển Hẹn giờ tắt (5, 10, 15, 30, 45, 60 phút)
    func setSleepTimer(minutes: Int?) {
        sleepTimerTicker?.invalidate()
        sleepTimerTicker = nil

        guard let minutes, minutes > 0 else {
            activeSleepTimerMinutes = nil
            sleepTimerRemainingSeconds = 0
            sleepTimerEndDate = nil
            return
        }

        let durationSeconds: Int = minutes * 60
        let targetEndDate = Date().addingTimeInterval(TimeInterval(durationSeconds))
        activeSleepTimerMinutes = minutes
        sleepTimerEndDate = targetEndDate
        sleepTimerRemainingSeconds = durationSeconds

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSleepTimerTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimerTicker = timer
    }

    func toggleSleepTimerPreset(minutes: Int) {
        if activeSleepTimerMinutes == minutes && isSleepTimerActive {
            setSleepTimer(minutes: nil)
        } else {
            setSleepTimer(minutes: minutes)
        }
    }

    private func handleSleepTimerTick() {
        guard let endDate = sleepTimerEndDate else {
            setSleepTimer(minutes: nil)
            return
        }
        let remaining = Int(ceil(endDate.timeIntervalSinceNow))
        if remaining <= 0 {
            triggerSleepTimerExpiration()
        } else {
            sleepTimerRemainingSeconds = remaining
        }
    }

    private func checkIfSleepTimerExpiredNow() -> Bool {
        guard let endDate = sleepTimerEndDate else { return false }
        if Date() >= endDate {
            triggerSleepTimerExpiration()
            return true
        }
        return false
    }

    private func triggerSleepTimerExpiration() {
        setSleepTimer(minutes: nil)
        stopInternal(resetTitle: true, cancelSleepTimer: true)
        onSleepTimerExpired?()
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

    private func cancelAllPrefetchAndCache() {
        prefetchCoordinatorTask?.cancel()
        prefetchCoordinatorTask = nil
        for (_, task) in inFlightTasks {
            task.cancel()
        }
        inFlightTasks.removeAll()
        prefetchedAudioCache.removeAll()
    }

    /// Hủy các tác vụ tải trước của những đoạn phía sau để nhường 100% băng thông/Actor cho đoạn hiện tại đang cần phát
    private func cancelPrefetchTasks(after index: Int) {
        prefetchCoordinatorTask?.cancel()
        prefetchCoordinatorTask = nil
        let keysToRemove = inFlightTasks.keys.filter { $0 > index }
        for key in keysToRemove {
            inFlightTasks[key]?.cancel()
            inFlightTasks.removeValue(forKey: key)
        }
    }

    func startSpeaking(title: String, text: String, fromScrollRatio: Double = 0.0) {
        stopInternal(resetTitle: false, cancelSleepTimer: false)
        configureAudioSession()

        currentChapterTitle = title
        currentRawText = text
        let clampedRatio = min(1.0, max(0.0, fromScrollRatio))
        let built = buildSpeechChunksWithRatios(from: text, title: title, anchorScrollRatio: clampedRatio)
        chunks = built.chunks
        chunkStartRatios = built.ratios
        hasPrependedTitleChunk = built.hasPrependedTitle
        totalChunks = chunks.count

        guard !chunks.isEmpty else {
            isSpeaking = false
            isPaused = false
            return
        }

        let targetIndex = built.anchorChunkIndex
        currentChunkIndex = max(0, min(targetIndex, chunks.count - 1))
        consecutiveFailures = 0
        isSpeaking = true
        isPaused = false
        playSessionToken = UUID()
        playCurrentChunk()
        updateNowPlayingInfo()
    }

    func startSpeaking(title: String, text: String, fromChunkIndex: Int) {
        stopInternal(resetTitle: false, cancelSleepTimer: false)
        configureAudioSession()

        currentChapterTitle = title
        currentRawText = text
        let built = buildSpeechChunksWithRatios(from: text, title: title, anchorScrollRatio: 0.0)
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
        let clampedRatio = min(1.0, max(0.0, ratio))
        if !currentRawText.isEmpty {
            cancelAllPrefetchAndCache()
            let built = buildSpeechChunksWithRatios(
                from: currentRawText,
                title: currentChapterTitle,
                anchorScrollRatio: clampedRatio
            )
            chunks = built.chunks
            chunkStartRatios = built.ratios
            hasPrependedTitleChunk = built.hasPrependedTitle
            totalChunks = chunks.count
            guard !chunks.isEmpty else { return }
            currentChunkIndex = max(0, min(built.anchorChunkIndex, chunks.count - 1))
        } else {
            guard !chunks.isEmpty else { return }
            let targetIndex = resolveChunkIndex(forScrollRatio: clampedRatio)
            currentChunkIndex = max(0, min(targetIndex, chunks.count - 1))
            cancelAllPrefetchAndCache()
        }

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
        prefetchCoordinatorTask?.cancel()
        prefetchCoordinatorTask = nil
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
        if checkIfSleepTimerExpiredNow() { return }
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
        stopInternal(resetTitle: true, cancelSleepTimer: true)
    }

    func skipForwardChunk() {
        guard isSpeaking, !chunks.isEmpty else { return }
        if checkIfSleepTimerExpiredNow() { return }
        if currentChunkIndex + 1 < chunks.count {
            currentChunkIndex += 1
            consecutiveFailures = 0
            restartFromCurrentChunk()
        } else {
            stopInternal(resetTitle: false, cancelSleepTimer: false)
            onChapterFinished?()
        }
    }

    func skipBackwardChunk() {
        guard isSpeaking, !chunks.isEmpty else { return }
        if checkIfSleepTimerExpiredNow() { return }
        currentChunkIndex = max(0, currentChunkIndex - 1)
        consecutiveFailures = 0
        restartFromCurrentChunk()
    }

    func adjustSpeed(delta: Double) {
        let clamped = min(2.0, max(0.6, ((playbackSpeedMultiplier + delta) * 10).rounded() / 10))
        playbackSpeedMultiplier = clamped
    }

    private func stopInternal(resetTitle: Bool, cancelSleepTimer: Bool) {
        playSessionToken = UUID()
        audioPlayer?.stop()
        audioPlayer = nil
        cancelAllPrefetchAndCache()

        if cancelSleepTimer {
            setSleepTimer(minutes: nil)
        }

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
            currentRawText = ""
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    private static var currentSavedGeminiApiKey: String {
        (UserDefaults.standard.string(forKey: "DOC_TRUYEN_GEMINI_API_KEY") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cơ chế Tải trước Tuần tự Thông minh (Luôn dọn sạch inFlightTasks kể cả khi bị cancel)
    private func getOrCreateSynthesisTask(
        for index: Int,
        voice: StoryVoiceChoice,
        allowGoogleFallback: Bool,
        forceNewTask: Bool = false
    ) -> Task<Data?, Never>? {
        guard index >= 0, index < chunks.count else { return nil }
        if !forceNewTask, let existingTask = inFlightTasks[index] {
            if !existingTask.isCancelled {
                return existingTask
            }
            inFlightTasks.removeValue(forKey: index)
        }

        let targetText = chunks[index]
        let apiKey = Self.currentSavedGeminiApiKey

        let task = Task<Data?, Never> { [weak self] in
            let data = await Self.synthesizeSpeechData(
                text: targetText,
                voice: voice,
                geminiApiKey: apiKey,
                allowGoogleFallback: allowGoogleFallback
            )
            if let self {
                if !Task.isCancelled, let data {
                    self.prefetchedAudioCache[index] = data
                }
                self.inFlightTasks.removeValue(forKey: index)
            }
            return Task.isCancelled ? nil : data
        }
        inFlightTasks[index] = task
        return task
    }

    private func resolveAudioData(for index: Int, voice: StoryVoiceChoice) async -> Data? {
        guard index >= 0, index < chunks.count else { return nil }

        if let cached = prefetchedAudioCache[index] {
            prefetchedAudioCache.removeValue(forKey: index)
            return cached
        }

        // Hủy các task prefetch của những đoạn phía sau (index + 1, index + 2...) để ưu tiên tối đa cho đoạn hiện tại
        cancelPrefetchTasks(after: index)

        if let existingTask = inFlightTasks[index] {
            let data = await existingTask.value
            inFlightTasks.removeValue(forKey: index)
            if let data {
                prefetchedAudioCache.removeValue(forKey: index)
                return data
            }
        }

        guard !Task.isCancelled else { return nil }

        // Thử tải lại giọng AI bằng một Task mới hoàn toàn (không dùng lại Task cũ đã lỗi/hủy)
        if let retryAITask = getOrCreateSynthesisTask(
            for: index,
            voice: voice,
            allowGoogleFallback: !voice.isAIVoice,
            forceNewTask: true
        ) {
            let aiData = await retryAITask.value
            inFlightTasks.removeValue(forKey: index)
            if let aiData {
                prefetchedAudioCache.removeValue(forKey: index)
                return aiData
            }
        }

        guard !Task.isCancelled else { return nil }

        // Chỉ khi tất cả các luồng AI (cả Edge Neural AI lẫn Gemini AI sau khi đã chờ hồi quota) đều thất bại mới dùng dự phòng cho đoạn hiện tại
        let apiKey = Self.currentSavedGeminiApiKey
        return await Self.synthesizeSpeechData(
            text: chunks[index],
            voice: voice,
            geminiApiKey: apiKey,
            allowGoogleFallback: true
        )
    }

    /// Tải trước tuần tự 2 đoạn kế tiếp SAU KHI đoạn hiện tại đã bắt đầu phát loa.
    /// Với kích thước đoạn lũy tiến (900 -> 1400 ký tự ≈ 60-95 giây âm thanh/đoạn), 2 đoạn tải trước tương đương 2.5 - 3 phút âm thanh đệm sẵn trong RAM,
    /// vừa đảm bảo phát liền mạch 100% không bao giờ xoay tròn, vừa giữ tần suất gọi < 0.7 request/phút (không bao giờ chạm ngưỡng 3 RPM của Gemini).
    private func scheduleLookaheadPrefetch(from index: Int, voice: StoryVoiceChoice, sessionToken: UUID) {
        prefetchCoordinatorTask?.cancel()
        let lookaheadCount = 2

        prefetchCoordinatorTask = Task { [weak self] in
            guard let self else { return }
            for offset in 1...lookaheadCount {
                if Task.isCancelled || self.playSessionToken != sessionToken { return }
                let targetIdx = index + offset
                guard targetIdx < self.chunks.count else { break }

                if self.prefetchedAudioCache[targetIdx] != nil {
                    continue
                }
                if let task = self.getOrCreateSynthesisTask(
                    for: targetIdx,
                    voice: voice,
                    allowGoogleFallback: !voice.isAIVoice
                ) {
                    let result = await task.value
                    if Task.isCancelled || self.playSessionToken != sessionToken { return }
                    // Nếu mạng hoặc server đang bận tạm thời, dừng bắn dồn các đoạn sau để chờ hồi nhịp
                    if result == nil {
                        break
                    }
                }
            }
            // Dọn các đoạn cũ đã đọc qua khỏi RAM
            let minKeep = max(0, index - 1)
            for key in self.prefetchedAudioCache.keys where key < minKeep {
                self.prefetchedAudioCache.removeValue(forKey: key)
            }
        }
    }

    private func playCurrentChunk() {
        if checkIfSleepTimerExpiredNow() { return }

        let sessionToken = playSessionToken
        guard currentChunkIndex >= 0, currentChunkIndex < chunks.count else {
            isSpeaking = false
            isPaused = false
            onChapterFinished?()
            return
        }

        let voiceMode = selectedVoiceChoice
        let chunkIdx = currentChunkIndex

        // Nếu đoạn này đã nằm sẵn trong RAM -> Phát ngay lập tức không độ trễ, rồi kích hoạt tải trước các đoạn kế tiếp
        if let cachedData = prefetchedAudioCache[chunkIdx] {
            prefetchedAudioCache.removeValue(forKey: chunkIdx)
            isBuffering = false
            if playAudioData(cachedData, voiceLabel: voiceMode.shortName) {
                consecutiveFailures = 0
                scheduleLookaheadPrefetch(from: chunkIdx, voice: voiceMode, sessionToken: sessionToken)
                return
            }
        }

        isBuffering = true

        Task {
            let audioData = await self.resolveAudioData(for: chunkIdx, voice: voiceMode)
            guard self.playSessionToken == sessionToken, self.isSpeaking, !self.isPaused else { return }
            if self.checkIfSleepTimerExpiredNow() { return }
            self.isBuffering = false

            if let audioData, self.playAudioData(audioData, voiceLabel: voiceMode.shortName) {
                self.consecutiveFailures = 0
                // Ngay khi loa bắt đầu đọc đoạn hiện tại, âm thầm tải tuần tự các đoạn kế tiếp trong nền
                self.scheduleLookaheadPrefetch(from: chunkIdx, voice: voiceMode, sessionToken: sessionToken)
            } else {
                self.consecutiveFailures += 1
                if self.consecutiveFailures < 3 && self.currentChunkIndex + 1 < self.chunks.count {
                    self.currentChunkIndex += 1
                    self.playCurrentChunk()
                } else {
                    self.stopInternal(resetTitle: false, cancelSleepTimer: false)
                    self.onError?("Không thể tải âm thanh giọng đọc AI. Vui lòng kiểm tra kết nối mạng.")
                }
            }
        }
    }

    private static func synthesizeSpeechData(
        text: String,
        voice: StoryVoiceChoice,
        geminiApiKey: String,
        allowGoogleFallback: Bool
    ) async -> Data? {
        let cleaned = sanitizeLineForSpeech(text)
        guard !cleaned.isEmpty else { return nil }

        switch voice {
        case .namMinh, .hoaiMy:
            // Ưu tiên 1: Giọng AI Microsoft Edge Neural (Nam Minh / Hoài My)
            if let edgeData = await EdgeNeuralTTSClient.synthesize(text: cleaned, voiceName: voice.edgeVoiceName),
               edgeData.count > 200 {
                return edgeData
            }
            // Ưu tiên 2: Dự phòng bằng Gemini AI Native Audio cùng giới tính (có bộ điều tốc Sliding Window chống 429)
            if !geminiApiKey.isEmpty {
                if let geminiAudio = await GeminiTTSClient.synthesize(
                    text: cleaned,
                    voiceName: voice.geminiVoiceName,
                    apiKey: geminiApiKey
                ), geminiAudio.count > 200 {
                    return geminiAudio
                }
            }
            // Ưu tiên 3: Đồng bộ lại đồng hồ server & thử lại Edge Neural AI với chế độ bảo mật luân phiên (v1/v2)
            if !Task.isCancelled {
                if let retryEdge = await EdgeNeuralTTSClient.synthesize(
                    text: cleaned,
                    voiceName: voice.edgeVoiceName,
                    forceFreshAndFlipGec: true
                ), retryEdge.count > 200 {
                    return retryEdge
                }
            }
            // Chỉ dùng Google khi allowGoogleFallback == true (tuyệt đối không lưu vào cache tải trước)
            if allowGoogleFallback && !Task.isCancelled {
                if let googleData = await GoogleTranslateTTSClient.synthesize(text: cleaned),
                   googleData.count > 200 {
                    return googleData
                }
            }

        case .geminiKore, .geminiPuck:
            // Ưu tiên 1: Giọng Gemini AI Native Audio (Pacer thông minh tự động chờ hồi quota, không bỏ cuộc sớm)
            if !geminiApiKey.isEmpty {
                if let geminiAudio = await GeminiTTSClient.synthesize(
                    text: cleaned,
                    voiceName: voice.geminiVoiceName,
                    apiKey: geminiApiKey
                ), geminiAudio.count > 200 {
                    return geminiAudio
                }
            }
            // Ưu tiên 2: Dự phòng bằng giọng AI Neural tiếng Việt tương ứng (Hoài My AI / Nam Minh AI) — vẫn là giọng AI truyền cảm
            if let edgeData = await EdgeNeuralTTSClient.synthesize(text: cleaned, voiceName: voice.edgeVoiceName),
               edgeData.count > 200 {
                return edgeData
            }
            // Ưu tiên 3: Thử lại Gemini AI hoặc Edge Neural AI một vòng nữa trước khi bỏ cuộc
            if !Task.isCancelled {
                if !geminiApiKey.isEmpty,
                   let retryGemini = await GeminiTTSClient.synthesize(
                       text: cleaned,
                       voiceName: voice.geminiVoiceName,
                       apiKey: geminiApiKey
                   ), retryGemini.count > 200 {
                    return retryGemini
                }
                if let retryEdge = await EdgeNeuralTTSClient.synthesize(
                    text: cleaned,
                    voiceName: voice.edgeVoiceName,
                    forceFreshAndFlipGec: true
                ), retryEdge.count > 200 {
                    return retryEdge
                }
            }
            if allowGoogleFallback && !Task.isCancelled {
                if let googleData = await GoogleTranslateTTSClient.synthesize(text: cleaned),
                   googleData.count > 200 {
                    return googleData
                }
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
        if checkIfSleepTimerExpiredNow() { return }
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

    // MARK: - Chia đoạn Lũy tiến Thông minh (Progressive Chunking)
    // Đoạn đầu tại vị trí bắt đầu nghe dài ~480 ký tự (~28s âm thanh) để phát loa tức thì sau ~1.2s.
    // Đoạn kế tiếp dài ~900 ký tự (~58s âm thanh) và các đoạn sau dài ~1380 ký tự (~90s âm thanh/đoạn).
    // Nhờ mỗi đoạn phát tới 1.5 phút mới cần 1 request tiếp theo, ứng dụng chỉ gọi ~0.65 request/phút —
    // tuyệt đối không bao giờ chạm giới hạn 3 RPM của Gemini AI và luôn tải trước xong 100% trong nền!
    private func buildSpeechChunksWithRatios(
        from rawText: String,
        title: String,
        anchorScrollRatio: Double = 0.0
    ) -> (chunks: [String], ratios: [Double], hasPrependedTitle: Bool, anchorChunkIndex: Int) {
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

        var rawLineChunks: [String] = []
        var rawLineRatios: [Double] = []

        let cleanTitle = Self.sanitizeLineForSpeech(title)
        let firstNonEmptyCleaned = rawLines
            .map { Self.sanitizeLineForSpeech($0) }
            .first(where: { !$0.isEmpty })

        if !cleanTitle.isEmpty {
            if let first = firstNonEmptyCleaned {
                let foldedFirst = first.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
                let foldedTitle = cleanTitle.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
                if !foldedFirst.contains(foldedTitle) {
                    rawLineChunks.append(cleanTitle)
                    rawLineRatios.append(0.0)
                }
            } else {
                rawLineChunks.append(cleanTitle)
                rawLineRatios.append(0.0)
            }
        }

        let singleMaxLen = 380

        for (lineIdx, rawLine) in rawLines.enumerated() {
            let linecleaned = Self.sanitizeLineForSpeech(rawLine)
            guard !linecleaned.isEmpty else { continue }

            let lineStartVisual = lineVisualStarts[lineIdx]
            let lineVisualHeight = max(1.0, ceil(Double(linecleaned.count) / charsPerVisualLine))
            let lineTotalChars = max(1, linecleaned.count)

            let lineSubChunks = splitCleanedLineIntoChunks(linecleaned, maxChunkLen: singleMaxLen)
            var consumedChars = 0

            for sub in lineSubChunks {
                let finalChunk = Self.sanitizeLineForSpeech(sub)
                guard !finalChunk.isEmpty else { continue }
                let progressInLine = min(1.0, Double(consumedChars) / Double(lineTotalChars))
                let chunkVisualY = lineStartVisual + progressInLine * lineVisualHeight
                let ratio = min(1.0, max(0.0, chunkVisualY / totalVisualLines))

                rawLineChunks.append(finalChunk)
                rawLineRatios.append(ratio)
                consumedChars += sub.count
            }
        }

        guard !rawLineChunks.isEmpty else {
            return ([], [], false, 0)
        }

        // Xác định câu bắt đầu tương ứng với vị trí cuộn hiện tại của người đọc
        let clampedAnchor = min(1.0, max(0.0, anchorScrollRatio))
        var rawAnchorIdx: Int = 0
        if clampedAnchor > 0.015 {
            for i in 0..<rawLineChunks.count {
                if rawLineRatios[i] <= clampedAnchor + 0.008 {
                    rawAnchorIdx = i
                }
            }
        }

        var mergedChunks: [String] = []
        var mergedRatios: [Double] = []
        var resolvedAnchorChunkIndex: Int = 0

        var idx = 0
        var forwardStepFromAnchor = 0

        while idx < rawLineChunks.count {
            if idx == rawAnchorIdx {
                resolvedAnchorChunkIndex = mergedChunks.count
                forwardStepFromAnchor = 0
            }

            let targetMergeLen: Int
            if idx < rawAnchorIdx {
                targetMergeLen = 1200
            } else if forwardStepFromAnchor == 0 {
                // Đoạn đầu tiên ngay tại vị trí bắt đầu nghe: vừa đủ ngắn (~480 ký tự) để phát ngay lập tức
                targetMergeLen = 480
            } else if forwardStepFromAnchor == 1 {
                // Đoạn thứ hai: ~920 ký tự (~60 giây âm thanh)
                targetMergeLen = 920
            } else {
                // Các đoạn tiếp theo: ~1380 ký tự (~90 giây âm thanh/đoạn)
                targetMergeLen = 1380
            }

            var currentText = rawLineChunks[idx]
            let startRatio = rawLineRatios[idx]
            let startedBeforeAnchor = (idx < rawAnchorIdx)
            idx += 1

            while idx < rawLineChunks.count {
                // Tuyệt đối không gộp vượt qua ranh giới câu mà người dùng đang cuộn tới
                if startedBeforeAnchor && idx >= rawAnchorIdx {
                    break
                }
                let nextText = rawLineChunks[idx]
                let combinedLen = currentText.count + 2 + nextText.count
                if combinedLen <= targetMergeLen {
                    if currentText.hasSuffix(".") || currentText.hasSuffix("!") || currentText.hasSuffix("?") {
                        currentText += " \(nextText)"
                    } else {
                        currentText += ". \(nextText)"
                    }
                    idx += 1
                } else {
                    break
                }
            }

            mergedChunks.append(currentText)
            mergedRatios.append(startRatio)
            if !startedBeforeAnchor {
                forwardStepFromAnchor += 1
            }
        }

        return (mergedChunks, mergedRatios, false, max(0, min(resolvedAnchorChunkIndex, max(0, mergedChunks.count - 1))))
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

// MARK: - Gemini Native Audio TTS Client (Bộ điều tốc Sliding Window + Tự động chờ hồi Quota 429 + Hỗ trợ đa API Key)
private actor GeminiTTSSerialActor {
    static let shared = GeminiTTSSerialActor()

    /// Chỉ sử dụng các model TTS hợp lệ; loại bỏ các model 404 tự động để không tốn request thừa
    private let candidateTTSModels: [String] = [
        "gemini-2.5-flash-preview-tts",
        "gemini-2.5-pro-preview-tts"
    ]
    private var unavailableModels: Set<String> = []
    private var rateLimitedModelsUntil: [String: TimeInterval] = [:]
    private var keyCursor: Int = 0
    private var lastCallTime: TimeInterval = 0
    /// Lưu lịch sử thời điểm gọi thành công trong 60 giây gần nhất cho từng API Key để điều tiết dưới ngưỡng 3 RPM
    private var recentCallTimestampsByKey: [String: [TimeInterval]] = [:]

    private static func parseApiKeys(from raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;\n\r\t ")
        let tokens = raw.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 20 }
        if tokens.isEmpty {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        var unique: [String] = []
        for t in tokens where !unique.contains(t) {
            unique.append(t)
        }
        return unique
    }

    func synthesize(text: String, voiceName: String, apiKey: String) async -> Data? {
        let keys = Self.parseApiKeys(from: apiKey)
        guard !keys.isEmpty else { return nil }

        // Giãn cách tối thiểu 1.5s giữa 2 request liên tiếp
        let now = Date().timeIntervalSince1970
        let elapsed = now - lastCallTime
        if elapsed < 1.5 && lastCallTime > 0 {
            let waitNs = UInt64((1.5 - elapsed) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: waitNs)
        }

        // Thử tối đa 4 vòng (với thời gian chờ hồi cửa sổ 60s thông minh) để không bao giờ bỏ cuộc giữa chừng khi chạm ngưỡng 3 RPM
        let retryDelaysSeconds: [Double] = [4.0, 7.0, 10.0, 12.0]

        for round in 0..<4 {
            if Task.isCancelled { return nil }

            let activeModels = candidateTTSModels.filter { !unavailableModels.contains($0) }
            let modelsToTry = activeModels.isEmpty ? ["gemini-2.5-flash-preview-tts"] : activeModels
            var sawRateLimit = false
            var suggestedRetryWait: Double? = nil

            for keyOffset in 0..<keys.count {
                if Task.isCancelled { return nil }
                let kIdx = (keyCursor + keyOffset) % keys.count
                let currentKey = keys[kIdx]

                // Kiểm tra cửa sổ 60 giây của key này: nếu đã gọi >= 3 lần trong 58 giây qua và chỉ có 1 key,
                // chủ động chờ cho tới khi request cũ nhất vượt qua mốc 60 giây để không bị Google trả lỗi 429
                let currentTs = Date().timeIntervalSince1970
                let history = (recentCallTimestampsByKey[currentKey] ?? []).filter { currentTs - $0 < 60.0 }
                recentCallTimestampsByKey[currentKey] = history

                if history.count >= 3 && keys.count == 1, let oldest = history.first {
                    let waitUntilWindowReset = max(0.0, 60.5 - (currentTs - oldest))
                    if waitUntilWindowReset > 0.2 && waitUntilWindowReset <= 22.0 {
                        try? await Task.sleep(nanoseconds: UInt64(waitUntilWindowReset * 1_000_000_000))
                        if Task.isCancelled { return nil }
                    }
                }

                for model in modelsToTry {
                    if Task.isCancelled { return nil }
                    let modelCooldownKey = "\(model)_\(kIdx)"
                    if let blockedUntil = rateLimitedModelsUntil[modelCooldownKey],
                       Date().timeIntervalSince1970 < blockedUntil,
                       model != "gemini-2.5-flash-preview-tts" {
                        continue
                    }

                    lastCallTime = Date().timeIntervalSince1970
                    let result = await GeminiTTSClient.callGeminiAudioEndpoint(
                        model: model,
                        text: text,
                        voiceName: voiceName,
                        apiKey: currentKey
                    )

                    switch result {
                    case .success(let wavData):
                        var updatedHistory = (recentCallTimestampsByKey[currentKey] ?? []).filter {
                            Date().timeIntervalSince1970 - $0 < 60.0
                        }
                        updatedHistory.append(Date().timeIntervalSince1970)
                        recentCallTimestampsByKey[currentKey] = updatedHistory
                        keyCursor = (kIdx + 1) % keys.count
                        return wavData

                    case .modelNotFound:
                        unavailableModels.insert(model)
                        continue

                    case .rateLimited(let retryAfterSec):
                        sawRateLimit = true
                        if let retryAfterSec, retryAfterSec > 0 {
                            suggestedRetryWait = min(20.0, max(3.0, retryAfterSec))
                        }
                        // Nếu model phụ (2.5-pro) bị 429 trên Free Tier thì tạm khóa model phụ 3 phút để không gọi thừa
                        if model != "gemini-2.5-flash-preview-tts" {
                            rateLimitedModelsUntil[modelCooldownKey] = Date().timeIntervalSince1970 + 180.0
                        }
                        continue

                    case .otherError:
                        continue
                    }
                }
            }

            if !sawRateLimit && round >= 1 {
                break
            }

            if round < retryDelaysSeconds.count && !Task.isCancelled {
                let waitSec = suggestedRetryWait ?? retryDelaysSeconds[round]
                try? await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
            }
        }
        return nil
    }
}

private enum GeminiTTSClient {
    enum CallResult {
        case success(Data)
        case rateLimited(Double?)
        case modelNotFound
        case otherError
    }

    static func synthesize(text: String, voiceName: String, apiKey: String) async -> Data? {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !trimmed.isEmpty else {
            return nil
        }
        return await GeminiTTSSerialActor.shared.synthesize(
            text: trimmed,
            voiceName: voiceName,
            apiKey: cleanKey
        )
    }

    static func callGeminiAudioEndpoint(
        model: String,
        text: String,
        voiceName: String,
        apiKey: String
    ) async -> CallResult {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return .otherError }

        let part = GeminiTTSRequestPayload.Content.Part(text: text)
        let content = GeminiTTSRequestPayload.Content(parts: [part])
        let prebuilt = GeminiTTSRequestPayload.GenerationConfig.SpeechConfig.VoiceConfig.PrebuiltVoiceConfig(voiceName: voiceName)
        let voiceCfg = GeminiTTSRequestPayload.GenerationConfig.SpeechConfig.VoiceConfig(prebuiltVoiceConfig: prebuilt)
        let speechCfg = GeminiTTSRequestPayload.GenerationConfig.SpeechConfig(voiceConfig: voiceCfg)
        let genCfg = GeminiTTSRequestPayload.GenerationConfig(responseModalities: ["AUDIO"], speechConfig: speechCfg)
        let payload = GeminiTTSRequestPayload(contents: [content], generationConfig: genCfg)

        guard let bodyData = try? JSONEncoder().encode(payload) else {
            return .otherError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 28
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResp = response as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 500

            if statusCode == 404 {
                return .modelNotFound
            }
            if statusCode == 429 || statusCode == 503 {
                let retryHeader = httpResp?.value(forHTTPHeaderField: "Retry-After")
                let parsedRetry = retryHeader.flatMap { Double($0) } ?? extractRetryDelaySeconds(from: data)
                return .rateLimited(parsedRetry)
            }
            guard (200...299).contains(statusCode) else {
                let rawBody = (String(data: data, encoding: .utf8) ?? "").lowercased()
                if rawBody.contains("not found") || rawBody.contains("not supported") {
                    return .modelNotFound
                }
                if rawBody.contains("quota") || rawBody.contains("resource_exhausted") || rawBody.contains("rate") {
                    return .rateLimited(extractRetryDelaySeconds(from: data))
                }
                return .otherError
            }

            guard let decoded = try? JSONDecoder().decode(GeminiTTSResponsePayload.self, from: data),
                  let parts = decoded.candidates?.first?.content?.parts else {
                return .otherError
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
            return .otherError
        } catch {
            return .otherError
        }
    }

    private static func extractRetryDelaySeconds(from data: Data) -> Double? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if let range = text.range(of: #""retryDelay"\s*:\s*"(\d+(\.\d+)?)s""#, options: .regularExpression) {
            let match = String(text[range])
            if let numRange = match.range(of: #"\d+(\.\d+)?"#, options: .regularExpression),
               let val = Double(match[numRange]) {
                return val
            }
        }
        return nil
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

// MARK: - Cổng Continuation An toàn Đa luồng cho NWConnection
private final class SafeContinuationGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: T) -> Bool {
        lock.lock()
        guard let cont = continuation else {
            lock.unlock()
            return false
        }
        continuation = nil
        lock.unlock()
        cont.resume(returning: value)
        return true
    }
}

// MARK: - Kết nối TLS HTTP/1.1 WebSocket Trực tiếp qua NWConnection
private final class EdgeRawTLSWebSocket: @unchecked Sendable {
    enum FrameEvent {
        case text(String)
        case binary(Data)
        case ping(Data)
        case pong(Data)
        case close
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.doctruyen.edgetts.rawtls")
    private var receiveBuffer: [UInt8] = []
    private var fragmentedOpcode: UInt8 = 0
    private var fragmentedPayload = Data()
    private(set) var isConnected: Bool = false
    private let createdAt: TimeInterval = Date().timeIntervalSince1970
    private var lastUsedAt: TimeInterval = Date().timeIntervalSince1970
    private var completedTurns: Int = 0

    /// Chỉ tái sử dụng kết nối khi vừa mới dùng trong vòng 4.5 giây và chưa có dữ liệu rác/frame đóng từ server
    var isReusable: Bool {
        let now = Date().timeIntervalSince1970
        return isConnected
            && receiveBuffer.isEmpty
            && completedTurns < 3
            && (now - lastUsedAt) < 4.5
            && (now - createdAt) < 22.0
    }

    init() {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(
            tlsOptions.securityProtocolOptions,
            "http/1.1"
        )
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        self.connection = NWConnection(
            host: NWEndpoint.Host("speech.platform.bing.com"),
            port: NWEndpoint.Port(rawValue: 443)!,
            using: params
        )
    }

    func close() {
        isConnected = false
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func waitForReady(timeoutSeconds: Double = 5.0) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let gate = SafeContinuationGate(cont)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                if gate.resume(returning: false) {
                    self?.close()
                }
            }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.isConnected = true
                    gate.resume(returning: true)
                case .failed, .cancelled:
                    self?.isConnected = false
                    gate.resume(returning: false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func sendRawData(_ data: Data, timeoutSeconds: Double = 5.0) async -> Bool {
        guard isConnected else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let gate = SafeContinuationGate(cont)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                if gate.resume(returning: false) {
                    self?.close()
                }
            }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    self?.isConnected = false
                    gate.resume(returning: false)
                } else {
                    gate.resume(returning: true)
                }
            })
        }
    }

    private func receiveMoreBytes(timeoutSeconds: Double = 7.0) async -> Bool {
        guard isConnected else { return false }
        let chunk: Data? = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let gate = SafeContinuationGate(cont)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                if gate.resume(returning: nil) {
                    self?.close()
                }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                if let data, !data.isEmpty {
                    gate.resume(returning: data)
                } else if isComplete || error != nil {
                    self?.isConnected = false
                    gate.resume(returning: nil)
                } else {
                    gate.resume(returning: Data())
                }
            }
        }
        guard let chunk else {
            isConnected = false
            return false
        }
        if !chunk.isEmpty {
            receiveBuffer.append(contentsOf: chunk)
        }
        return true
    }

    func connectAndHandshake(
        trustedToken: String,
        secMsGec: String,
        secMsGecVersion: String,
        userAgentVersion: String
    ) async -> (success: Bool, serverDateHeader: String?) {
        guard await waitForReady(timeoutSeconds: 5.0) else {
            close()
            return (false, nil)
        }

        let connectionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let muid = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        var keyBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            keyBytes[i] = UInt8.random(in: 0...255)
        }
        let wsKey = Data(keyBytes).base64EncodedString()

        let path = "/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(trustedToken)&ConnectionId=\(connectionId)&Sec-MS-GEC=\(secMsGec)&Sec-MS-GEC-Version=\(secMsGecVersion)"
        let requestLines = [
            "GET \(path) HTTP/1.1",
            "Host: speech.platform.bing.com",
            "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(userAgentVersion) Safari/537.36 Edg/\(userAgentVersion)",
            "Origin: chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
            "Cookie: muid=\(muid);",
            "Pragma: no-cache",
            "Cache-Control: no-cache",
            "Accept-Encoding: gzip, deflate, br, zstd",
            "Accept-Language: vi-VN,vi;q=0.9,en-US;q=0.8,en;q=0.7",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(wsKey)",
            "Sec-WebSocket-Version: 13",
            "\r\n"
        ].joined(separator: "\r\n")

        guard await sendRawData(Data(requestLines.utf8), timeoutSeconds: 5.0) else {
            close()
            return (false, nil)
        }

        while !Task.isCancelled {
            if let headerEnd = Self.findHTTPHeaderDelimiter(in: receiveBuffer) {
                let headerBytes = Array(receiveBuffer[0..<headerEnd])
                receiveBuffer.removeFirst(headerEnd + 4)
                let headerText = String(decoding: headerBytes, as: UTF8.self)
                let dateHeader = Self.extractHTTPDateHeader(from: headerText)
                let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
                if firstLine.contains(" 101 ") {
                    lastUsedAt = Date().timeIntervalSince1970
                    return (true, dateHeader)
                } else {
                    close()
                    return (false, dateHeader)
                }
            }
            if receiveBuffer.count > 32768 {
                close()
                return (false, nil)
            }
            guard await receiveMoreBytes(timeoutSeconds: 5.0) else {
                close()
                return (false, nil)
            }
        }
        close()
        return (false, nil)
    }

    func synthesizeTurn(
        text: String,
        voiceName: String,
        timestampString: String
    ) async -> Data? {
        guard isConnected else { return nil }

        // Tắt wordBoundaryEnabled để server Microsoft chỉ truyền các frame âm thanh MP3, giảm 60% số frame và tăng gấp đôi tốc độ tải đoạn dài
        let configPayload = "X-Timestamp:\(timestampString)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"

        let cleanText = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let escapedText = cleanText
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")

        let reqId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='vi-VN'><voice name='\(voiceName)'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>\(escapedText)</prosody></voice></speak>"
        let ssmlPayload = "X-RequestId:\(reqId)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(timestampString)Z\r\nPath:ssml\r\n\r\n\(ssml)"

        let frame1 = Self.encodeClientFrame(opcode: 0x1, payload: Data(configPayload.utf8))
        let frame2 = Self.encodeClientFrame(opcode: 0x1, payload: Data(ssmlPayload.utf8))
        var combined = Data(capacity: frame1.count + frame2.count)
        combined.append(frame1)
        combined.append(frame2)

        guard await sendRawData(combined, timeoutSeconds: 5.0) else {
            close()
            return nil
        }

        var audioBuffer = Data()
        while !Task.isCancelled && isConnected {
            while let frame = parseNextFrame() {
                switch frame {
                case .text(let str):
                    if str.contains("Path:turn.end") {
                        lastUsedAt = Date().timeIntervalSince1970
                        completedTurns += 1
                        return audioBuffer.count > 200 ? audioBuffer : nil
                    }
                case .binary(let data):
                    if data.count >= 2 {
                        let headerLen = (Int(data[0]) << 8) | Int(data[1])
                        let payloadStart = 2 + headerLen
                        if payloadStart <= data.count {
                            let headerData = data.subdata(in: 2..<payloadStart)
                            let headerStr = String(decoding: headerData, as: UTF8.self)
                            if headerStr.contains("Path:audio") && payloadStart < data.count {
                                audioBuffer.append(data.subdata(in: payloadStart..<data.count))
                            }
                        }
                    }
                case .ping(let pingData):
                    let pong = Self.encodeClientFrame(opcode: 0xA, payload: pingData)
                    _ = await sendRawData(pong, timeoutSeconds: 4.0)
                case .pong:
                    break
                case .close:
                    close()
                    return audioBuffer.count > 200 ? audioBuffer : nil
                }
            }

            guard await receiveMoreBytes(timeoutSeconds: 7.0) else {
                close()
                return audioBuffer.count > 200 ? audioBuffer : nil
            }
        }

        close()
        return nil
    }

    private func parseNextFrame() -> FrameEvent? {
        while true {
            guard receiveBuffer.count >= 2 else { return nil }
            let b0 = receiveBuffer[0]
            let b1 = receiveBuffer[1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0F
            let isMasked = (b1 & 0x80) != 0
            let len7 = Int(b1 & 0x7F)

            var headerLen = 2
            var payloadLen = 0

            if len7 < 126 {
                payloadLen = len7
            } else if len7 == 126 {
                guard receiveBuffer.count >= 4 else { return nil }
                payloadLen = (Int(receiveBuffer[2]) << 8) | Int(receiveBuffer[3])
                headerLen = 4
            } else {
                guard receiveBuffer.count >= 10 else { return nil }
                var len64: UInt64 = 0
                for i in 2..<10 {
                    len64 = (len64 << 8) | UInt64(receiveBuffer[i])
                }
                if len64 > 15_000_000 {
                    close()
                    return .close
                }
                payloadLen = Int(len64)
                headerLen = 10
            }

            if isMasked {
                headerLen += 4
            }

            let totalFrameLen = headerLen + payloadLen
            guard receiveBuffer.count >= totalFrameLen else { return nil }

            var payloadBytes = Array(receiveBuffer[headerLen..<totalFrameLen])
            if isMasked {
                let mStart = headerLen - 4
                let masks = [
                    receiveBuffer[mStart],
                    receiveBuffer[mStart + 1],
                    receiveBuffer[mStart + 2],
                    receiveBuffer[mStart + 3]
                ]
                for i in 0..<payloadBytes.count {
                    payloadBytes[i] ^= masks[i & 3]
                }
            }
            receiveBuffer.removeFirst(totalFrameLen)
            let frameData = Data(payloadBytes)

            switch opcode {
            case 0x8:
                return .close
            case 0x9:
                return .ping(frameData)
            case 0xA:
                return .pong(frameData)
            case 0x1, 0x2:
                if fin {
                    if opcode == 0x1 {
                        return .text(String(decoding: frameData, as: UTF8.self))
                    } else {
                        return .binary(frameData)
                    }
                } else {
                    fragmentedOpcode = opcode
                    fragmentedPayload = frameData
                    continue
                }
            case 0x0:
                fragmentedPayload.append(frameData)
                if fin {
                    let completedOpcode = fragmentedOpcode
                    let completedData = fragmentedPayload
                    fragmentedOpcode = 0
                    fragmentedPayload.removeAll(keepingCapacity: false)
                    if completedOpcode == 0x1 {
                        return .text(String(decoding: completedData, as: UTF8.self))
                    } else {
                        return .binary(completedData)
                    }
                } else {
                    continue
                }
            default:
                continue
            }
        }
    }

    private static func encodeClientFrame(opcode: UInt8, payload: Data) -> Data {
        let bytes = Array(payload)
        let len = bytes.count
        var out = [UInt8]()
        out.reserveCapacity(len + 14)
        out.append(0x80 | (opcode & 0x0F))

        if len < 126 {
            out.append(0x80 | UInt8(len))
        } else if len <= 65535 {
            out.append(0x80 | 126)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
        } else {
            out.append(0x80 | 127)
            let len64 = UInt64(len)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((len64 >> UInt64(shift)) & 0xFF))
            }
        }

        let mask: [UInt8] = [
            UInt8.random(in: 0...255),
            UInt8.random(in: 0...255),
            UInt8.random(in: 0...255),
            UInt8.random(in: 0...255)
        ]
        out.append(contentsOf: mask)
        for i in 0..<len {
            out.append(bytes[i] ^ mask[i & 3])
        }
        return Data(out)
    }

    private static func findHTTPHeaderDelimiter(in buf: [UInt8]) -> Int? {
        guard buf.count >= 4 else { return nil }
        let limit: Int = buf.count - 4
        for i in 0...limit {
            if buf[i] != 0x0D { continue }
            if buf[i + 1] != 0x0A { continue }
            if buf[i + 2] != 0x0D { continue }
            if buf[i + 3] == 0x0A {
                return i
            }
        }
        return nil
    }

    private static func extractHTTPDateHeader(from headerText: String) -> String? {
        for line in headerText.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("date:") {
                let val = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty {
                    return val
                }
            }
        }
        return nil
    }
}

// MARK: - Actor Điều phối Tuần tự, Tự động Đàm phán Sec-MS-GEC (v1/v2) & Circuit Breaker cho Microsoft Edge Neural TTS
private actor EdgeTTSSerialActor {
    enum GecMode {
        case v2
        case v1
    }

    static let shared = EdgeTTSSerialActor()
    private var activeSocket: EdgeRawTLSWebSocket?
    private var preferredGecMode: GecMode = .v2
    private var consecutiveHardFailures: Int = 0
    private var circuitOpenUntil: TimeInterval = 0

    func synthesize(text: String, voiceName: String, forceFreshAndFlipGec: Bool = false) async -> Data? {
        if forceFreshAndFlipGec {
            activeSocket?.close()
            activeSocket = nil
            preferredGecMode = (preferredGecMode == .v2) ? .v1 : .v2
            circuitOpenUntil = 0
        } else {
            // Nếu mạng hiện tại đang chặn cổng Edge liên tiếp, tạm bỏ qua nhanh trong 40s để chuyển sang Gemini AI ngay lập tức không bị xoay tròn chờ đợi
            if Date().timeIntervalSince1970 < circuitOpenUntil {
                return nil
            }
        }

        // 1. Tái sử dụng kết nối WebSocket đang ấm (chỉ khi vừa dùng trong vòng 4.5s)
        if !forceFreshAndFlipGec, let existing = activeSocket, existing.isReusable {
            let ts = EdgeNeuralTTSClient.formatEdgeTimestamp(from: EdgeNeuralTTSClient.currentSyncedTimestamp())
            if let data = await existing.synthesizeTurn(text: text, voiceName: voiceName, timestampString: ts),
               data.count > 200 {
                consecutiveHardFailures = 0
                return data
            }
            existing.close()
            activeSocket = nil
        } else {
            activeSocket?.close()
            activeSocket = nil
        }

        // 2. Mở kết nối TLS HTTP/1.1 WebSocket mới, tự động thử cả Sec-MS-GEC v2 lẫn v1 (SHA-256 chuẩn)
        let modesToTry: [GecMode] = (preferredGecMode == .v2) ? [.v2, .v1] : [.v1, .v2]

        for (attemptIdx, mode) in modesToTry.enumerated() {
            if Task.isCancelled { return nil }
            let socket = EdgeRawTLSWebSocket()
            let nowTs = EdgeNeuralTTSClient.currentSyncedTimestamp()
            let secMsGec: String
            let secMsGecVersion: String
            let uaVersion: String

            switch mode {
            case .v2:
                secMsGec = EdgeNeuralTTSClient.generateSecMsGecV2(timestamp: nowTs)
                secMsGecVersion = EdgeNeuralTTSClient.secMsGecVersionV2
                uaVersion = "143.0.0.0"
            case .v1:
                secMsGec = EdgeNeuralTTSClient.generateSecMsGecV1(timestamp: nowTs)
                secMsGecVersion = EdgeNeuralTTSClient.secMsGecVersionV1
                uaVersion = "132.0.0.0"
            }

            let handshake = await socket.connectAndHandshake(
                trustedToken: EdgeNeuralTTSClient.trustedToken,
                secMsGec: secMsGec,
                secMsGecVersion: secMsGecVersion,
                userAgentVersion: uaVersion
            )

            if let dateHeader = handshake.serverDateHeader {
                EdgeNeuralTTSClient.updateServerClockFromDateString(dateHeader)
            }

            if handshake.success {
                let ts = EdgeNeuralTTSClient.formatEdgeTimestamp(from: EdgeNeuralTTSClient.currentSyncedTimestamp())
                if let data = await socket.synthesizeTurn(text: text, voiceName: voiceName, timestampString: ts),
                   data.count > 200 {
                    preferredGecMode = mode
                    consecutiveHardFailures = 0
                    if socket.isReusable {
                        activeSocket = socket
                    } else {
                        socket.close()
                    }
                    return data
                }
            }
            socket.close()

            if attemptIdx == 0 && handshake.serverDateHeader == nil {
                await EdgeNeuralTTSClient.syncServerClock()
            }
        }

        // 3. Dự phòng qua URLSessionWebSocketTask với cả 2 chế độ GEC
        for mode in modesToTry {
            if Task.isCancelled { return nil }
            let useV1 = (mode == .v1)
            if let fallbackData = await EdgeNeuralTTSClient.performURLSessionWebSocketSynthesize(
                text: text,
                voiceName: voiceName,
                useV1Gec: useV1
            ), fallbackData.count > 200 {
                preferredGecMode = mode
                consecutiveHardFailures = 0
                return fallbackData
            }
        }

        consecutiveHardFailures += 1
        if consecutiveHardFailures >= 2 {
            circuitOpenUntil = Date().timeIntervalSince1970 + 40.0
        }
        return nil
    }
}

// MARK: - Microsoft Edge Neural TTS WebSocket Client (Hỗ trợ song song Sec-MS-GEC v1 SHA-256 & v2 theo edge-tts)
private enum EdgeNeuralTTSClient {
    static let trustedToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    static let secMsGecVersionV2 = "2-143.0.3650.75"
    static let secMsGecVersionV1 = "1-132.0.2957.140"
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

    static func synthesize(
        text: String,
        voiceName: String,
        forceFreshAndFlipGec: Bool = false
    ) async -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await EdgeTTSSerialActor.shared.synthesize(
            text: trimmed,
            voiceName: voiceName,
            forceFreshAndFlipGec: forceFreshAndFlipGec
        )
    }

    static func setServerClockOffset(_ offset: TimeInterval) {
        clockLock.lock()
        serverTimeOffsetSeconds = offset
        hasSyncedServerClock = true
        clockLock.unlock()
    }

    static func updateServerClockFromDateString(_ dateHeader: String) {
        let trimmed = dateHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss z",
            "EEEE, dd-MMM-yy HH:mm:ss 'GMT'",
            "EEE MMM d HH:mm:ss yyyy"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)

        for fmt in formats {
            df.dateFormat = fmt
            if let serverDate = df.date(from: trimmed) {
                let offset = serverDate.timeIntervalSince1970 - Date().timeIntervalSince1970
                setServerClockOffset(offset)
                return
            }
        }
    }

    static func currentSyncedTimestamp() -> TimeInterval {
        clockLock.lock()
        let offset = serverTimeOffsetSeconds
        clockLock.unlock()
        return Date().timeIntervalSince1970 + offset
    }

    static func syncServerClock() async {
        let probeUrls = [
            "https://www.bing.com",
            "https://translate.googleapis.com"
        ]
        for urlStr in probeUrls {
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 3
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse,
                   let dateHeader = http.value(forHTTPHeaderField: "Date") {
                    updateServerClockFromDateString(dateHeader)
                    return
                }
            } catch {
                continue
            }
        }
    }

    static func performURLSessionWebSocketSynthesize(
        text: String,
        voiceName: String,
        useV1Gec: Bool = false
    ) async -> Data? {
        let connectionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let nowTimestamp = currentSyncedTimestamp()
        let secMsGec = useV1Gec
            ? generateSecMsGecV1(timestamp: nowTimestamp)
            : generateSecMsGecV2(timestamp: nowTimestamp)
        let secVersion = useV1Gec ? secMsGecVersionV1 : secMsGecVersionV2
        let uaVer = useV1Gec ? "132.0.0.0" : "143.0.0.0"

        let urlString = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(trustedToken)&ConnectionId=\(connectionId)&Sec-MS-GEC=\(secMsGec)&Sec-MS-GEC-Version=\(secVersion)"
        guard let url = URL(string: urlString) else { return nil }

        let muid = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(uaVer) Safari/537.36 Edg/\(uaVer)"
        let origin = "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold"

        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.httpShouldHandleCookies = false
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.setValue("muid=\(muid);", forHTTPHeaderField: "Cookie")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("vi-VN,vi;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpAdditionalHeaders = [
            "User-Agent": ua,
            "Origin": origin,
            "Cookie": "muid=\(muid);",
            "Pragma": "no-cache",
            "Cache-Control": "no-cache",
            "Accept-Language": "vi-VN,vi;q=0.9,en-US;q=0.8,en;q=0.7"
        ]
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 10
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

            let cleanText = text
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            let escapedText = cleanText
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
                            return audioBuffer.count > 200 ? audioBuffer : nil
                        }
                    case .data(let data):
                        if data.count >= 2 {
                            let headerLen = (Int(data[0]) << 8) | Int(data[1])
                            let payloadStart = 2 + headerLen
                            if payloadStart <= data.count {
                                let headerData = data.subdata(in: 2..<payloadStart)
                                let headerStr = String(decoding: headerData, as: UTF8.self)
                                if headerStr.contains("Path:audio") && payloadStart < data.count {
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

    // MARK: - Thuật toán Sec-MS-GEC v1 chuẩn (SHA-256 64-hex uppercase) bằng CryptoKit
    static func generateSecMsGecV1(timestamp: TimeInterval) -> String {
        let winEpochOffset: Int64 = 11_644_473_600
        let unixSeconds: Int64 = Int64(timestamp)
        let totalSeconds: Int64 = unixSeconds + winEpochOffset
        let rem300: Int64 = totalSeconds % 300
        let roundedSeconds: Int64 = totalSeconds - rem300
        let fileTime: Int64 = roundedSeconds * 10_000_000
        let rawString = "\(fileTime)\(trustedToken)"
        let digest = SHA256.hash(data: Data(rawString.utf8))
        var hex = ""
        hex.reserveCapacity(64)
        for byte in digest {
            hex += String(format: "%02X", byte)
        }
        return hex
    }

    // MARK: - Thuật toán Sec-MS-GEC v2 (<16-hex>-<64-hex>) chính xác theo rany2/edge-tts 7.3.1 drm.py
    private static func rol16(_ value: UInt64) -> UInt64 {
        let v: UInt64 = value & u32Mask
        let shl: UInt64 = v << (16 as UInt64)
        let shr: UInt64 = v >> (16 as UInt64)
        let combined: UInt64 = shl | shr
        return combined & u32Mask
    }

    private static func sigma0(_ value: UInt64) -> UInt64 {
        let a1: UInt64 = value >> (7 as UInt64)
        let a2: UInt64 = value << (25 as UInt64)
        let s1: UInt64 = a1 ^ a2
        let b1: UInt64 = value >> (18 as UInt64)
        let b2: UInt64 = value << (14 as UInt64)
        let s2: UInt64 = b1 ^ b2
        let c1: UInt64 = value >> (3 as UInt64)
        let x1: UInt64 = s1 ^ s2
        let x2: UInt64 = x1 ^ c1
        return x2 & u32Mask
    }

    private static func sigma1(_ value: UInt64) -> UInt64 {
        let a1: UInt64 = value >> (17 as UInt64)
        let a2: UInt64 = value << (15 as UInt64)
        let s1: UInt64 = a1 ^ a2
        let b1: UInt64 = value >> (19 as UInt64)
        let b2: UInt64 = value << (13 as UInt64)
        let s2: UInt64 = b1 ^ b2
        let c1: UInt64 = value >> (10 as UInt64)
        let x1: UInt64 = s1 ^ s2
        let x2: UInt64 = x1 ^ c1
        return x2 & u32Mask
    }

    private static func packBE32(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> UInt64 {
        let u0: UInt64 = UInt64(b0) << (24 as UInt64)
        let u1: UInt64 = UInt64(b1) << (16 as UInt64)
        let u2: UInt64 = UInt64(b2) << (8 as UInt64)
        let u3: UInt64 = UInt64(b3)
        let hi: UInt64 = u0 | u1
        let lo: UInt64 = u2 | u3
        return hi | lo
    }

    private static func packLE32(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> UInt64 {
        let u0: UInt64 = UInt64(b0)
        let u1: UInt64 = UInt64(b1) << (8 as UInt64)
        let u2: UInt64 = UInt64(b2) << (16 as UInt64)
        let u3: UInt64 = UInt64(b3) << (24 as UInt64)
        let lo: UInt64 = u0 | u1
        let hi: UInt64 = u2 | u3
        return lo | hi
    }

    private static func appendLE32Hex(of word: UInt64, to out: inout String) {
        let b0: UInt64 = word & 0xFF
        let s1: UInt64 = word >> (8 as UInt64)
        let b1: UInt64 = s1 & 0xFF
        let s2: UInt64 = word >> (16 as UInt64)
        let b2: UInt64 = s2 & 0xFF
        let s3: UInt64 = word >> (24 as UInt64)
        let b3: UInt64 = s3 & 0xFF
        out += String(format: "%02X%02X%02X%02X", b0, b1, b2, b3)
    }

    private static func sha256Rounds(state: inout [UInt64], words: [UInt64], firstRound: Int) {
        var a: UInt64 = state[0]
        var b: UInt64 = state[1]
        var c: UInt64 = state[2]
        var d: UInt64 = state[3]
        var e: UInt64 = state[4]
        var f: UInt64 = state[5]
        var g: UInt64 = state[6]
        var h: UInt64 = state[7]

        for i in firstRound..<64 {
            let isSpecialRound: Bool = (firstRound == 14 && i == 14)
            let k: UInt64 = isSpecialRound ? 0xC9DC06A7 : sha256RoundConstants[i]
            let rotE: UInt64 = e &* 0x100000001
            let rotA: UInt64 = a &* 0x100000001

            let re1: UInt64 = rotE >> (6 as UInt64)
            let re2: UInt64 = rotE >> (11 as UInt64)
            let re3: UInt64 = rotE >> (25 as UInt64)
            let re12: UInt64 = re1 ^ re2
            let sumE: UInt64 = re12 ^ re3

            let fg: UInt64 = f ^ g
            let efg: UInt64 = e & fg
            let ch: UInt64 = g ^ efg

            let t1a: UInt64 = h &+ sumE
            let t1b: UInt64 = t1a &+ ch
            let t1c: UInt64 = t1b &+ k
            let t1: UInt64 = t1c &+ words[i]

            let ra1: UInt64 = rotA >> (2 as UInt64)
            let ra2: UInt64 = rotA >> (13 as UInt64)
            let ra3: UInt64 = rotA >> (22 as UInt64)
            let ra12: UInt64 = ra1 ^ ra2
            let sumA: UInt64 = ra12 ^ ra3

            let ab: UInt64 = a & b
            let aOrb: UInt64 = a | b
            let cAndAB: UInt64 = c & aOrb
            let maj: UInt64 = ab | cAndAB
            let t2: UInt64 = sumA &+ maj

            h = g
            g = f
            f = e
            let dPlusT1: UInt64 = d &+ t1
            e = dPlusT1 & u32Mask
            d = c
            c = b
            b = a
            let t1PlusT2: UInt64 = t1 &+ t2
            a = t1PlusT2 & u32Mask
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
            let s1: UInt64 = sigma1(words[i - 2])
            let s0: UInt64 = sigma0(words[i - 15])
            let p1: UInt64 = s1 &+ words[i - 7]
            let p2: UInt64 = s0 &+ words[i - 16]
            let sum: UInt64 = p1 &+ p2
            words[i] = sum & u32Mask
        }
    }

    static func generateSecMsGecV2(timestamp: TimeInterval) -> String {
        let winEpochOffset: Int64 = 11_644_473_600
        let unixSeconds: Int64 = Int64(timestamp)
        let totalSeconds: Int64 = unixSeconds + winEpochOffset
        let rem300: Int64 = totalSeconds % 300
        let roundedSeconds: Int64 = totalSeconds - rem300
        let fileTime: Int64 = roundedSeconds * 10_000_000
        let rawString = "\(fileTime)\(trustedToken)"
        let dataBytes: [UInt8] = Array(rawString.utf8)
        guard dataBytes.count >= 7 else { return "" }

        var initWords = [UInt64](repeating: 0, count: 64)
        initWords[14] = packBE32(0, dataBytes[0], dataBytes[1], dataBytes[2])
        initWords[15] = packBE32(dataBytes[3], dataBytes[4], dataBytes[5], dataBytes[6])

        for i in 16..<30 {
            var v: UInt64 = sha256Schedule[i - 16]
            if i - 2 >= 14 {
                let s1: UInt64 = sigma1(initWords[i - 2])
                let adj1: UInt64 = (i == 16) ? (s1 ^ 0x000B92C0) : s1
                v = v &+ adj1
            }
            if i - 7 >= 14 {
                v = v &+ initWords[i - 7]
            }
            if i - 15 >= 14 {
                let s0: UInt64 = sigma0(initWords[i - 15])
                let adj0: UInt64 = (i == 29) ? (s0 ^ 0x059C0B80) : s0
                v = v &+ adj0
            }
            initWords[i] = v & u32Mask
        }

        let w30a: UInt64 = sigma1(initWords[28]) &+ initWords[23]
        let w30b: UInt64 = sigma0(initWords[15]) &+ initWords[14]
        let w30c: UInt64 = w30a &+ w30b
        let w30d: UInt64 = w30c &+ (0xC9DC06A7 as UInt64)
        let w30: UInt64 = w30d &- sha256RoundConstants[14]
        initWords[30] = w30 & u32Mask
        expandSchedule(&initWords, firstWord: 31)

        var working: [UInt64] = sha256State
        sha256Rounds(state: &working, words: initWords, firstRound: 14)

        var state = [UInt64](repeating: 0, count: 8)
        for i in 0..<8 {
            let sumState: UInt64 = sha256Initial[i] &+ working[i]
            state[i] = sumState & u32Mask
        }

        let totalLen: Int = 57 + dataBytes.count
        let remBytes: [UInt8] = Array(dataBytes[7..<dataBytes.count])
        let mod64: Int = totalLen % 64
        let diff55: Int = (55 - mod64) % 64
        let padZeros: Int = (diff55 + 64) % 64

        var padded = [UInt8]()
        padded.reserveCapacity(remBytes.count + 9 + padZeros)
        padded.append(contentsOf: remBytes)
        padded.append(0x80)
        for _ in 0..<padZeros {
            padded.append(0x00)
        }
        let bitLen: UInt64 = UInt64(totalLen) * (8 as UInt64)
        for shift in stride(from: 56, through: 0, by: -8) {
            let shifted: UInt64 = bitLen >> UInt64(shift)
            let byteVal: UInt8 = UInt8(shifted & 0xFF)
            padded.append(byteVal)
        }

        var offset: Int = 0
        while offset < padded.count {
            var blockWords = [UInt64](repeating: 0, count: 64)
            for i in 0..<16 {
                let p: Int = offset + (i * 4)
                blockWords[i] = packBE32(padded[p], padded[p + 1], padded[p + 2], padded[p + 3])
            }
            expandSchedule(&blockWords, firstWord: 16)
            var blkWorking: [UInt64] = state
            sha256Rounds(state: &blkWorking, words: blockWords, firstRound: 0)
            for i in 0..<8 {
                let nextS: UInt64 = state[i] &+ blkWorking[i]
                state[i] = nextS & u32Mask
            }
            offset += 64
        }

        var digestBytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            let word: UInt64 = state[i]
            let baseIdx: Int = i * 4
            let s24: UInt64 = word >> (24 as UInt64)
            let s16: UInt64 = word >> (16 as UInt64)
            let s8: UInt64 = word >> (8 as UInt64)
            digestBytes[baseIdx] = UInt8(s24 & 0xFF)
            digestBytes[baseIdx + 1] = UInt8(s16 & 0xFF)
            digestBytes[baseIdx + 2] = UInt8(s8 & 0xFF)
            digestBytes[baseIdx + 3] = UInt8(word & 0xFF)
        }

        var keyA: UInt64 = packLE32(digestBytes[0], digestBytes[1], digestBytes[2], digestBytes[3])
        var keyB: UInt64 = packLE32(digestBytes[4], digestBytes[5], digestBytes[6], digestBytes[7])
        keyA |= (1 as UInt64)
        keyB |= (1 as UInt64)

        let rawF0: UInt64 = keyA &* 0x82893933
        let rawF1: UInt64 = keyB &* 0x82893933
        let factor0: UInt64 = rawF0 & u32Mask
        let factor1: UInt64 = rawF1 & u32Mask

        var terms = [UInt64]()
        var offsets = [UInt64]()
        for i in 0..<14 {
            let f: UInt64 = (i % 2 == 0) ? factor0 : factor1
            let prod: UInt64 = cs64CoeffA[i] &* f
            terms.append(prod & u32Mask)
            offsets.append(cs64CoeffB[i])
        }

        var prefixed = [UInt8]()
        prefixed.append(0x00)
        prefixed.append(contentsOf: dataBytes)
        while prefixed.count % 4 != 0 {
            prefixed.append(0x00)
        }

        var leWords = [UInt64]()
        var pIdx: Int = 0
        while pIdx < prefixed.count {
            let w: UInt64 = packLE32(prefixed[pIdx], prefixed[pIdx + 1], prefixed[pIdx + 2], prefixed[pIdx + 3])
            leWords.append(w)
            pIdx += 4
        }
        if leWords.count % 2 == 1 {
            leWords.append(0)
        }

        for (idx, word) in leWords.enumerated() {
            let isEven: Bool = (idx % 2 == 0)
            let k: UInt64 = isEven ? keyA : keyB
            let c: UInt64 = isEven ? 0xEF0569FB : 0xC31713DB
            var term: UInt64 = word &* k
            let rWord: UInt64 = rol16(word)
            var off: UInt64 = rWord &* c
            if idx == 0 {
                let extraTerm: UInt64 = (0xF2F90B1A as UInt64) &* factor0
                term = term &+ extraTerm
                off = off &+ (0x0B1A0000 as UInt64)
            }
            terms.append(term & u32Mask)
            offsets.append(off & u32Mask)
        }

        var swapAcc: UInt64 = 0
        var swapLast: UInt64 = 0
        var st: UInt64 = 0
        var acc: UInt64 = 0

        var tIdx: Int = 0
        while tIdx < terms.count {
            let x: UInt64 = terms[tIdx]
            let y: UInt64 = terms[tIdx + 1]

            let ox: UInt64 = (offsets[tIdx] &+ x) & u32Mask
            let t0: UInt64 = rol16(ox)
            let q0: UInt64 = (t0 &* 0x76F50F34) & u32Mask
            let rq0: UInt64 = rol16(q0) &* 0xC3EFEA97
            let rq0Sum: UInt64 = (rq0 &+ q0) & u32Mask
            swapAcc = swapAcc &+ rq0Sum

            let oy: UInt64 = (offsets[tIdx + 1] &+ y) & u32Mask
            let t1: UInt64 = rol16(oy)
            let q1: UInt64 = (t1 &* 0x1881CE3C) & u32Mask
            let rq1: UInt64 = rol16(q1) &* 0x35BD1EC9
            swapLast = (rq1 &+ q1) & u32Mask
            let nextSwapAcc: UInt64 = swapAcc &+ swapLast
            swapAcc = nextSwapAcc & u32Mask

            let stA: UInt64 = st &* keyA
            st = (stA &+ x) & u32Mask
            st = (rol16(st) &* 0xCF98B111) & u32Mask
            st = (rol16(st) &* 0x87085B9F) & u32Mask
            st = (rol16(st) &* 0x12CEB96D) & u32Mask
            st = (rol16(st) &* 0x257E1D83) & u32Mask
            acc = acc &+ st

            let stB: UInt64 = st &* keyB
            var tm: UInt64 = (stB &+ y) & u32Mask
            tm = (rol16(tm) &* 0xA27416F5) & u32Mask
            tm = (rol16(tm) &* 0xD38396FF) & u32Mask
            let inner: UInt64 = (rol16(tm) &* 0x7C932B89) & u32Mask
            st = (rol16(inner) &* 0xBFA49F69) & u32Mask
            let nextAcc: UInt64 = acc &+ st
            acc = nextAcc & u32Mask

            tIdx += 2
        }

        let cs0: UInt64 = (swapLast ^ st) & u32Mask
        let cs1: UInt64 = (swapAcc ^ acc) & u32Mask

        var csHex = ""
        appendLE32Hex(of: cs0, to: &csHex)
        appendLE32Hex(of: cs1, to: &csHex)

        var shaHex = ""
        for b in digestBytes {
            shaHex += String(format: "%02X", b)
        }
        return "\(csHex)-\(shaHex)"
    }

    static func formatEdgeTimestamp(from timestamp: TimeInterval) -> String {
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
