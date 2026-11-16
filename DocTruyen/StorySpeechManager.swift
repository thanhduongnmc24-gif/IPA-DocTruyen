import Foundation
import AVFoundation
import MediaPlayer
import CryptoKit
import Combine

enum StoryVoiceChoice: String, CaseIterable, Identifiable, Codable {
    case namMinh = "vi-VN-NamMinhNeural"
    case hoaiMy = "vi-VN-HoaiMyNeural"
    case googleVi = "google-vi"
    case iphoneOffline = "iphone-offline"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .namMinh: return "Nam Minh (AI Trầm ấm)"
        case .hoaiMy: return "Hoài My (AI Truyền cảm)"
        case .googleVi: return "Google Tiếng Việt"
        case .iphoneOffline: return "iPhone (Ngoại tuyến)"
        }
    }

    var shortName: String {
        switch self {
        case .namMinh: return "Nam Minh AI"
        case .hoaiMy: return "Hoài My AI"
        case .googleVi: return "Google"
        case .iphoneOffline: return "iPhone"
        }
    }
}

@MainActor
final class StorySpeechManager: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
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

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var chunks: [String] = []
    private var prefetchedAudioCache: [Int: Data] = [:]
    private var prefetchTasks: [Int: Task<Data?, Never>] = [:]
    private var playSessionToken: UUID = UUID()
    private var isStoppingIntentionally: Bool = false
    private let offlineVoice: AVSpeechSynthesisVoice?

    private override init() {
        let viVoices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix("vi")
        }
        self.offlineVoice = viVoices.first(where: { $0.quality == .enhanced }) ?? viVoices.first ?? AVSpeechSynthesisVoice(language: "vi-VN")

        super.init()

        let savedSpeed = UserDefaults.standard.double(forKey: "DOC_TRUYEN_SPEECH_SPEED_MULTIPLIER")
        if savedSpeed >= 0.6 && savedSpeed <= 2.0 {
            playbackSpeedMultiplier = savedSpeed
        }
        if let savedVoiceRaw = UserDefaults.standard.string(forKey: "DOC_TRUYEN_SPEECH_VOICE_CHOICE"),
           let voice = StoryVoiceChoice(rawValue: savedVoiceRaw) {
            selectedVoiceChoice = voice
        }

        synthesizer.delegate = self
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

    func startSpeaking(title: String, text: String, fromChunkIndex: Int = 0) {
        stopInternal(resetTitle: false)
        configureAudioSession()

        currentChapterTitle = title
        chunks = buildSpeechChunks(from: text, title: title)
        totalChunks = chunks.count

        guard !chunks.isEmpty else {
            isSpeaking = false
            isPaused = false
            return
        }

        currentChunkIndex = max(0, min(fromChunkIndex, chunks.count - 1))
        isSpeaking = true
        isPaused = false
        playSessionToken = UUID()
        playCurrentChunk()
        updateNowPlayingInfo()
    }

    private func restartFromCurrentChunk() {
        guard isSpeaking, !chunks.isEmpty else { return }
        audioPlayer?.stop()
        audioPlayer = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            isStoppingIntentionally = true
            synthesizer.stopSpeaking(at: .immediate)
        }
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
        if synthesizer.isSpeaking {
            if !synthesizer.pauseSpeaking(at: .word) {
                isStoppingIntentionally = true
                synthesizer.stopSpeaking(at: .immediate)
            }
        }
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
        } else if synthesizer.isPaused {
            synthesizer.continueSpeaking()
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
            restartFromCurrentChunk()
        } else {
            stopInternal(resetTitle: false)
            onChapterFinished?()
        }
    }

    func skipBackwardChunk() {
        guard isSpeaking, !chunks.isEmpty else { return }
        currentChunkIndex = max(0, currentChunkIndex - 1)
        restartFromCurrentChunk()
    }

    func adjustSpeed(delta: Double) {
        let clamped = min(2.0, max(0.6, ((playbackSpeedMultiplier + delta) * 10).rounded() / 10))
        playbackSpeedMultiplier = clamped
        if selectedVoiceChoice == .iphoneOffline && synthesizer.isSpeaking && !isPaused {
            restartFromCurrentChunk()
        }
    }

    private func stopInternal(resetTitle: Bool) {
        playSessionToken = UUID()
        isStoppingIntentionally = true
        audioPlayer?.stop()
        audioPlayer = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        for (_, task) in prefetchTasks { task.cancel() }
        prefetchTasks.removeAll()
        prefetchedAudioCache.removeAll()

        isSpeaking = false
        isPaused = false
        isBuffering = false
        currentChunkIndex = 0
        totalChunks = 0
        chunks = []
        activeVoiceLabel = ""
        if resetTitle {
            currentChapterTitle = ""
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    // MARK: - Phát từng đoạn (Ưu tiên Edge Neural AI -> Google TTS -> iPhone Offline)
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

        if voiceMode == .iphoneOffline {
            activeVoiceLabel = voiceMode.shortName
            speakViaOfflineSynthesizer(text: text)
            return
        }

        if let cachedData = prefetchedAudioCache[chunkIdx] {
            prefetchedAudioCache.removeValue(forKey: chunkIdx)
            playMP3Data(cachedData, voiceLabel: voiceMode.shortName)
            prefetchUpcomingChunks(after: chunkIdx, voice: voiceMode, sessionToken: sessionToken)
            return
        }

        isBuffering = true
        Task {
            let audioData = await resolveOnlineSpeechData(index: chunkIdx, text: text, voice: voiceMode)
            guard self.playSessionToken == sessionToken, self.isSpeaking, !self.isPaused else { return }
            self.isBuffering = false

            if let audioData {
                self.playMP3Data(audioData, voiceLabel: voiceMode.shortName)
                self.prefetchUpcomingChunks(after: chunkIdx, voice: voiceMode, sessionToken: sessionToken)
            } else {
                self.activeVoiceLabel = "Ngoại tuyến"
                self.speakViaOfflineSynthesizer(text: text)
            }
        }
    }

    private func prefetchUpcomingChunks(after index: Int, voice: StoryVoiceChoice, sessionToken: UUID) {
        guard voice != .iphoneOffline else { return }
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
            return await existingTask.value
        }
        return await Self.synthesizeSpeechData(text: text, voice: voice)
    }

    private static func synthesizeSpeechData(text: String, voice: StoryVoiceChoice) async -> Data? {
        if voice == .namMinh || voice == .hoaiMy {
            if let edgeData = await EdgeNeuralTTSClient.synthesize(text: text, voiceName: voice.rawValue),
               edgeData.count > 200 {
                return edgeData
            }
        }
        if let googleData = await GoogleTranslateTTSClient.synthesize(text: text),
           googleData.count > 200 {
            return googleData
        }
        return nil
    }

    private func playMP3Data(_ data: Data, voiceLabel: String) {
        do {
            audioPlayer?.stop()
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.enableRate = true
            player.rate = Float(min(2.0, max(0.6, playbackSpeedMultiplier)))
            player.prepareToPlay()
            if player.play() {
                audioPlayer = player
                activeVoiceLabel = voiceLabel
                updateNowPlayingInfo()
                return
            }
        } catch {
            // Fall through
        }
        speakViaOfflineSynthesizer(text: chunks[currentChunkIndex])
    }

    private func speakViaOfflineSynthesizer(text: String) {
        isStoppingIntentionally = false
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = offlineVoice ?? AVSpeechSynthesisVoice(language: "vi-VN")
        let base = Double(AVSpeechUtteranceDefaultSpeechRate)
        let scaled = base * (0.72 + (playbackSpeedMultiplier - 0.6) * 0.42)
        utterance.rate = Float(min(0.75, max(0.28, scaled)))
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.08
        synthesizer.speak(utterance)
        updateNowPlayingInfo()
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

    // MARK: - AVSpeechSynthesizerDelegate
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.isStoppingIntentionally {
                self.isStoppingIntentionally = false
                return
            }
            self.advanceToNextChunkOrChapter()
        }
    }

    // MARK: - Chia đoạn văn bản tối ưu cho giọng đọc AI
    private func buildSpeechChunks(from rawText: String, title: String) -> [String] {
        let lines = rawText
            .components(separatedBy: .newlines)
            .map { line -> String in
                var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let r = s.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                    s.removeSubrange(r)
                }
                return s.replacingOccurrences(of: "**", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        var result: [String] = []
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = lines.first {
            let foldedFirst = first.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
            let foldedTitle = cleanTitle.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
            if !cleanTitle.isEmpty && !foldedFirst.contains(foldedTitle) {
                result.append(cleanTitle)
            }
        } else if !cleanTitle.isEmpty {
            result.append(cleanTitle)
        }

        let maxChunkLen = 200
        for line in lines {
            if line.count <= maxChunkLen {
                result.append(line)
                continue
            }
            let sentences = line.components(separatedBy: CharacterSet(charactersIn: ".!?;"))
            var buf = ""
            for rawSentence in sentences {
                let s = rawSentence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty else { continue }
                if s.count > maxChunkLen {
                    if !buf.isEmpty {
                        result.append(buf)
                        buf = ""
                    }
                    let clauses = s.components(separatedBy: ",")
                    var subBuf = ""
                    for rawClause in clauses {
                        let c = rawClause.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !c.isEmpty else { continue }
                        let cand = subBuf.isEmpty ? c : "\(subBuf), \(c)"
                        if cand.count > maxChunkLen && !subBuf.isEmpty {
                            result.append(subBuf)
                            subBuf = c
                        } else {
                            subBuf = cand
                        }
                    }
                    if !subBuf.isEmpty { result.append(subBuf) }
                } else {
                    let cand = buf.isEmpty ? s : "\(buf). \(s)"
                    if cand.count > maxChunkLen && !buf.isEmpty {
                        result.append(buf)
                        buf = s
                    } else {
                        buf = cand
                    }
                }
            }
            if !buf.isEmpty { result.append(buf) }
        }
        return result
    }
}

// MARK: - Microsoft Edge Neural TTS WebSocket Client
private enum EdgeNeuralTTSClient {
    private static let trustedToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let secMsGecVersion = "1-130.0.2849.68"

    static func synthesize(text: String, voiceName: String) async -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let connectionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let secMsGec = generateSecMsGec()
        let urlString = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(trustedToken)&Sec-MS-GEC=\(secMsGec)&Sec-MS-GEC-Version=\(secMsGecVersion)&ConnectionId=\(connectionId)"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0", forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: config)
        let ws = session.webSocketTask(with: request)
        ws.resume()

        defer {
            ws.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let configPayload = "X-Timestamp:\(timestamp)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}"

        let escapedText = trimmed
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
            while true {
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
        } catch {
            return nil
        }
    }

    private static func generateSecMsGec() -> String {
        let winEpochOffset: Double = 11_644_473_600
        var ticks = Date().timeIntervalSince1970 + winEpochOffset
        ticks -= ticks.truncatingRemainder(dividingBy: 300)
        let fileTime = UInt64(ticks * 10_000_000)
        let raw = "\(fileTime)\(trustedToken)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - Google Translate TTS Fallback
private enum GoogleTranslateTTSClient {
    static func synthesize(text: String) async -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var comps = URLComponents(string: "https://translate.google.com/translate_tts")
        comps?.queryItems = [
            URLQueryItem(name: "ie", value: "UTF-8"),
            URLQueryItem(name: "tl", value: "vi"),
            URLQueryItem(name: "client", value: "tw-ob"),
            URLQueryItem(name: "q", value: trimmed)
        ]
        guard let url = comps?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://translate.google.com/", forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}
