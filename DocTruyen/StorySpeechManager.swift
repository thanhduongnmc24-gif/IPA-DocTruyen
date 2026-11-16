import Foundation
import AVFoundation
import MediaPlayer
import Combine

@MainActor
final class StorySpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = StorySpeechManager()

    @Published var isSpeaking: Bool = false
    @Published var isPaused: Bool = false
    @Published var currentChunkIndex: Int = 0
    @Published var totalChunks: Int = 0
    @Published var currentChapterTitle: String = ""

    /// Hệ số tốc độ đọc hiển thị cho người dùng (0.6x -> 2.0x, mặc định 1.0x)
    @Published var playbackSpeedMultiplier: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(playbackSpeedMultiplier, forKey: "DOC_TRUYEN_SPEECH_SPEED_MULTIPLIER")
        }
    }

    var onChapterFinished: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var chunks: [String] = []
    private var selectedVoice: AVSpeechSynthesisVoice?
    private var isStoppingIntentionally: Bool = false

    private override init() {
        super.init()
        let savedSpeed = UserDefaults.standard.double(forKey: "DOC_TRUYEN_SPEECH_SPEED_MULTIPLIER")
        if savedSpeed >= 0.6 && savedSpeed <= 2.0 {
            playbackSpeedMultiplier = savedSpeed
        }
        synthesizer.delegate = self
        selectedVoice = Self.bestVietnameseVoice()
        setupRemoteCommands()
    }

    private static func bestVietnameseVoice() -> AVSpeechSynthesisVoice? {
        let viVoices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix("vi")
        }
        if let enhanced = viVoices.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        if let firstVi = viVoices.first {
            return firstVi
        }
        return AVSpeechSynthesisVoice(language: "vi-VN")
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetooth, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.resume()
            }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePlayPause()
            }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.skipForwardChunk()
            }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.skipBackwardChunk()
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentChapterTitle.isEmpty ? "Đọc Truyện AI" : currentChapterTitle,
            MPMediaItemPropertyArtist: "Đọc Truyện AI",
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
        speakCurrentChunk()
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if !isSpeaking {
            return
        }
        if isPaused {
            resume()
        } else {
            pause()
        }
    }

    func pause() {
        guard isSpeaking, !isPaused else { return }
        if synthesizer.pauseSpeaking(at: .word) {
            isPaused = true
        } else {
            isStoppingIntentionally = true
            synthesizer.stopSpeaking(at: .immediate)
            isPaused = true
        }
        updateNowPlayingInfo()
    }

    func resume() {
        guard isSpeaking, isPaused else { return }
        configureAudioSession()
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
        } else {
            isPaused = false
            speakCurrentChunk()
        }
        updateNowPlayingInfo()
    }

    func stop() {
        stopInternal(resetTitle: true)
    }

    func skipForwardChunk() {
        guard isSpeaking, !chunks.isEmpty else { return }
        if currentChunkIndex + 1 < chunks.count {
            isStoppingIntentionally = true
            synthesizer.stopSpeaking(at: .immediate)
            currentChunkIndex += 1
            isPaused = false
            speakCurrentChunk()
        } else {
            stopInternal(resetTitle: false)
            onChapterFinished?()
        }
    }

    func skipBackwardChunk() {
        guard isSpeaking, !chunks.isEmpty else { return }
        isStoppingIntentionally = true
        synthesizer.stopSpeaking(at: .immediate)
        currentChunkIndex = max(0, currentChunkIndex - 1)
        isPaused = false
        speakCurrentChunk()
    }

    func adjustSpeed(delta: Double) {
        let next = min(2.0, max(0.6, (playbackSpeedMultiplier + delta * 10).rounded() / 10))
        let clamped = min(2.0, max(0.6, ((playbackSpeedMultiplier + delta) * 10).rounded() / 10))
        _ = next
        playbackSpeedMultiplier = clamped

        // Nếu đang đọc, áp dụng ngay tốc độ mới cho câu tiếp theo / câu hiện tại
        if isSpeaking && !isPaused {
            isStoppingIntentionally = true
            synthesizer.stopSpeaking(at: .immediate)
            speakCurrentChunk()
        }
        updateNowPlayingInfo()
    }

    private func stopInternal(resetTitle: Bool) {
        isStoppingIntentionally = true
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        isPaused = false
        currentChunkIndex = 0
        totalChunks = 0
        chunks = []
        if resetTitle {
            currentChapterTitle = ""
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    private func mappedAVSpeechRate() -> Float {
        // AVSpeechUtteranceDefaultSpeechRate ~ 0.5, min ~ 0.1, max ~ 0.72 cho tiếng Việt tự nhiên
        let base = Double(AVSpeechUtteranceDefaultSpeechRate)
        let scaled = base * (0.72 + (playbackSpeedMultiplier - 0.6) * 0.42)
        return Float(min(0.75, max(0.28, scaled)))
    }

    private func speakCurrentChunk() {
        guard currentChunkIndex >= 0, currentChunkIndex < chunks.count else {
            isSpeaking = false
            isPaused = false
            onChapterFinished?()
            return
        }

        isStoppingIntentionally = false
        let utterance = AVSpeechUtterance(string: chunks[currentChunkIndex])
        utterance.voice = selectedVoice ?? AVSpeechSynthesisVoice(language: "vi-VN")
        utterance.rate = mappedAVSpeechRate()
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.12
        synthesizer.speak(utterance)
        updateNowPlayingInfo()
    }

    /// Chia nhỏ nội dung chương thành các đoạn vừa phải (~450 ký tự) theo ranh giới dòng/câu
    /// để AVSpeechSynthesizer đọc tiếng Việt mượt mà, không bị ngắt quãng giữa chừng.
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

        var buffer = ""
        for line in lines {
            if line.count > 550 {
                if !buffer.isEmpty {
                    result.append(buffer)
                    buffer = ""
                }
                let sentences = line.components(separatedBy: ". ")
                var subBuf = ""
                for s in sentences {
                    let piece = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !piece.isEmpty else { continue }
                    let candidate = subBuf.isEmpty ? piece : "\(subBuf). \(piece)"
                    if candidate.count > 450 && !subBuf.isEmpty {
                        result.append(subBuf)
                        subBuf = piece
                    } else {
                        subBuf = candidate
                    }
                }
                if !subBuf.isEmpty {
                    result.append(subBuf)
                }
            } else {
                let candidate = buffer.isEmpty ? line : "\(buffer)\n\(line)"
                if candidate.count > 450 && !buffer.isEmpty {
                    result.append(buffer)
                    buffer = line
                } else {
                    buffer = candidate
                }
            }
        }
        if !buffer.isEmpty {
            result.append(buffer)
        }
        return result
    }

    // MARK: - AVSpeechSynthesizerDelegate
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.isStoppingIntentionally {
                self.isStoppingIntentionally = false
                return
            }
            guard self.isSpeaking, !self.isPaused else { return }

            if self.currentChunkIndex + 1 < self.chunks.count {
                self.currentChunkIndex += 1
                self.speakCurrentChunk()
            } else {
                self.isSpeaking = false
                self.isPaused = false
                self.currentChunkIndex = 0
                self.onChapterFinished?()
            }
        }
    }
}
