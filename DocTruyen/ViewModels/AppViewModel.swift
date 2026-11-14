import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    enum ScreenMode {
        case folders
        case chapters
        case reader
    }

    enum FolderLayoutMode: String {
        case list
        case grid
    }

    // MARK: - Storage Keys
    private let readingStateStorageKey = "DOC_TRUYEN_READING_STATES_SWIFT_V2"
    private let geminiApiKeyStorageKey = "DOC_TRUYEN_GEMINI_API_KEY"
    private let geminiPromptStorageKey = "DOC_TRUYEN_GEMINI_PROMPT"
    private let geminiModelStorageKey = "DOC_TRUYEN_GEMINI_MODEL"
    private let autoFallbackStorageKey = "DOC_TRUYEN_GEMINI_AUTO_FALLBACK"
    private let driveApiKeyOverrideStorageKey = "DOC_TRUYEN_DRIVE_API_KEY_OVERRIDE"
    private let driveFolderIdOverrideStorageKey = "DOC_TRUYEN_DRIVE_FOLDER_ID_OVERRIDE"
    private let driveAccessTokenStorageKey = "DOC_TRUYEN_DRIVE_ACCESS_TOKEN"
    private let fontSizeStorageKey = "DOC_TRUYEN_STORY_FONT_SIZE"
    private let readerThemeStorageKey = "DOC_TRUYEN_READER_THEME"

    // MARK: - Navigation & Data State
    @Published var screenMode: ScreenMode = .folders
    @Published var folderLayoutMode: FolderLayoutMode = .grid
    @Published var folderStack: [FolderNode] = []
    @Published var folders: [DriveItem] = []
    @Published var chapters: [DriveItem] = []
    @Published var selectedChapter: DriveItem?
    @Published var chapterContent: String = ""
    @Published var searchQuery: String = ""

    /// Tăng mỗi khi chuyển sang chương mới để ép ScrollView tạo mới và cuộn về đầu trang (y = 0)
    @Published var readerScrollResetToken: Int = 0

    @Published var isLoading: Bool = false
    @Published var errorMessage: String = ""
    @Published var toastMessage: String = ""

    // MARK: - Reader Settings & State
    @Published var storyFontSize: Double = 20 {
        didSet { UserDefaults.standard.set(storyFontSize, forKey: fontSizeStorageKey) }
    }
    @Published var readerTheme: ReaderTheme = .sepia {
        didSet { UserDefaults.standard.set(readerTheme.rawValue, forKey: readerThemeStorageKey) }
    }
    @Published var tocVisible: Bool = false
    @Published var tocStartIndex: Int = 0
    @Published var nextSwipePromptVisible: Bool = false
    @Published var readingStates: [String: StoryReadingState] = [:]
    @Published var lastReadingFolderId: String?

    // MARK: - AI Gemini Translation Settings & Batch State
    @Published var geminiApiKey: String = "" {
        didSet { UserDefaults.standard.set(geminiApiKey, forKey: geminiApiKeyStorageKey) }
    }
    @Published var translationPrompt: String = DefaultPrompts.standardNovelPolish {
        didSet { UserDefaults.standard.set(translationPrompt, forKey: geminiPromptStorageKey) }
    }
    @Published var selectedGeminiModel: GeminiModelChoice = .flash35Lite {
        didSet { UserDefaults.standard.set(selectedGeminiModel.rawValue, forKey: geminiModelStorageKey) }
    }
    @Published var autoSwitchTo31OnQuota: Bool = true {
        didSet { UserDefaults.standard.set(autoSwitchTo31OnQuota, forKey: autoFallbackStorageKey) }
    }

    // MARK: - Google Drive Configuration (Info.plist + Optional User Override)
    @Published var driveApiKeyOverride: String = "" {
        didSet { UserDefaults.standard.set(driveApiKeyOverride, forKey: driveApiKeyOverrideStorageKey) }
    }
    @Published var driveFolderIdOverride: String = "" {
        didSet { UserDefaults.standard.set(driveFolderIdOverride, forKey: driveFolderIdOverrideStorageKey) }
    }
    @Published var driveAccessToken: String = "" {
        didSet { UserDefaults.standard.set(driveAccessToken, forKey: driveAccessTokenStorageKey) }
    }

    // MARK: - Modals & Translation Range State
    @Published var showSettingsSheet: Bool = false
    @Published var showTranslationPopup: Bool = false
    @Published var translateFromChapterIndex: Int = 0
    @Published var translateToChapterIndex: Int = 0
    @Published var isTranslatingBatch: Bool = false
    @Published var translationProgressCount: Int = 0
    @Published var translationTotalCount: Int = 0
    @Published var translationCurrentChapterTitle: String = ""
    @Published var translationStatusNote: String = ""
    @Published var translatedRevisionTrigger: Int = 0

    // MARK: - In-Memory Caches (kết hợp cùng Disk Cache trong LocalChapterStorage)
    private var folderCache: [String: (mode: ScreenMode, folders: [DriveItem], chapters: [DriveItem])] = [:]
    private var chapterContentCache: [String: String] = [:]
    private var prefetchingIds: Set<String> = []
    private var translationTask: Task<Void, Never>?

    let tocWindowSize = 50

    var bundledDriveApiKey: String {
        let secret = GeneratedSecrets.googleDriveApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            return secret
        }
        let raw = (Bundle.main.object(forInfoDictionaryKey: "GoogleDriveAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty || raw == "__GOOGLE_DRIVE_API_KEY__" || raw.hasPrefix("$(") {
            return ""
        }
        return raw
    }

    var bundledRootFolderId: String {
        let secret = GeneratedSecrets.googleDriveFolderId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            return DriveInputParser.extractFolderId(from: secret)
        }
        let raw = (Bundle.main.object(forInfoDictionaryKey: "GoogleDriveFolderID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty || raw == "__GOOGLE_DRIVE_FOLDER_ID__" || raw.hasPrefix("$(") {
            return ""
        }
        return DriveInputParser.extractFolderId(from: raw)
    }

    var isDriveConfiguredViaSecrets: Bool {
        !bundledDriveApiKey.isEmpty && !bundledRootFolderId.isEmpty
    }

    var activeDriveApiKey: String {
        let override = driveApiKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return override }
        return bundledDriveApiKey
    }

    var activeRootFolderId: String {
        let override = DriveInputParser.extractFolderId(from: driveFolderIdOverride)
        if !override.isEmpty { return override }
        return bundledRootFolderId
    }

    var currentFolder: FolderNode {
        folderStack.last ?? FolderNode(id: activeRootFolderId, name: "Thư viện truyện")
    }

    var currentChapterIndex: Int {
        guard let selectedChapter else { return -1 }
        return chapters.firstIndex(where: { $0.id == selectedChapter.id }) ?? -1
    }

    var currentStorySavedState: StoryReadingState? {
        readingStates[currentFolder.id]
    }

    var filteredFolders: [DriveItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return folders }
        return folders.filter { $0.name.lowercased().contains(q) }
    }

    var filteredChapters: [DriveItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return chapters }
        return chapters.filter { $0.cleanChapterName.lowercased().contains(q) }
    }

    var currentTocSlice: [DriveItem] {
        guard !chapters.isEmpty else { return [] }
        let start = max(0, min(tocStartIndex, chapters.count - 1))
        let end = min(start + tocWindowSize, chapters.count)
        return Array(chapters[start..<end])
    }

    init() {
        loadUserPreferences()
        Task {
            await initializeApp()
        }
    }

    private func loadUserPreferences() {
        let defaults = UserDefaults.standard

        if let savedKey = defaults.string(forKey: geminiApiKeyStorageKey) {
            geminiApiKey = savedKey
        }
        if let savedPrompt = defaults.string(forKey: geminiPromptStorageKey), !savedPrompt.isEmpty {
            translationPrompt = savedPrompt
        } else {
            translationPrompt = DefaultPrompts.standardNovelPolish
        }
        if let savedModelRaw = defaults.string(forKey: geminiModelStorageKey),
           let model = GeminiModelChoice(rawValue: savedModelRaw) {
            selectedGeminiModel = model
        }
        if defaults.object(forKey: autoFallbackStorageKey) != nil {
            autoSwitchTo31OnQuota = defaults.bool(forKey: autoFallbackStorageKey)
        }
        if let savedDriveKey = defaults.string(forKey: driveApiKeyOverrideStorageKey) {
            driveApiKeyOverride = savedDriveKey
        }
        if let savedDriveFolder = defaults.string(forKey: driveFolderIdOverrideStorageKey) {
            driveFolderIdOverride = savedDriveFolder
        }
        if let savedToken = defaults.string(forKey: driveAccessTokenStorageKey) {
            driveAccessToken = savedToken
        }
        let savedFontSize = defaults.double(forKey: fontSizeStorageKey)
        if savedFontSize >= 13 && savedFontSize <= 34 {
            storyFontSize = savedFontSize
        }
        if let savedThemeRaw = defaults.string(forKey: readerThemeStorageKey),
           let theme = ReaderTheme(rawValue: savedThemeRaw) {
            readerTheme = theme
        }
    }

    func resetPromptToDefault() {
        translationPrompt = DefaultPrompts.standardNovelPolish
        showToast("Đã khôi phục câu lệnh dịch mặc định")
    }

    func applyCustomDriveSettingsAndReload() async {
        folderCache.removeAll()
        LocalChapterStorage.shared.clearFolderDiskCache()
        let rootNode = FolderNode(id: activeRootFolderId, name: "Thư viện truyện")
        folderStack = [rootNode]
        _ = await loadFolder(rootNode, forceRefreshFromDrive: true)
        showToast("Đã cập nhật kết nối Google Drive")
    }

    func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if self.toastMessage == message {
                self.toastMessage = ""
            }
        }
    }

    // MARK: - Reading State Persistence
    private func loadPersistedReadingData() -> PersistedReadingData {
        guard let data = UserDefaults.standard.data(forKey: readingStateStorageKey),
              let decoded = try? JSONDecoder().decode(PersistedReadingData.self, from: data) else {
            return PersistedReadingData(states: [:], lastReadingFolderId: nil)
        }
        return decoded
    }

    private func persistReadingData() {
        let payload = PersistedReadingData(states: readingStates, lastReadingFolderId: lastReadingFolderId)
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: readingStateStorageKey)
        }
    }

    func saveReadingProgress(paragraphIndex: Int = 0, chapterOverride: DriveItem? = nil) {
        guard let chapter = chapterOverride ?? selectedChapter else { return }
        let storyFolderId = currentFolder.id
        guard !storyFolderId.isEmpty else { return }

        let state = StoryReadingState(
            folderId: storyFolderId,
            folderStack: folderStack,
            chapterId: chapter.id,
            chapterName: chapter.name,
            paragraphIndex: paragraphIndex,
            savedAt: Date().timeIntervalSince1970
        )
        readingStates[storyFolderId] = state
        lastReadingFolderId = storyFolderId
        persistReadingData()
    }

    // MARK: - App Initialization & Instant Offline Restore
    func initializeApp() async {
        let rootNode = FolderNode(id: activeRootFolderId, name: "Thư viện truyện")
        folderStack = [rootNode]

        let saved = loadPersistedReadingData()
        readingStates = saved.states
        lastReadingFolderId = saved.lastReadingFolderId

        // Khôi phục ngay lập tức chương đang đọc từ bộ nhớ đệm trên máy mà không cần gọi lại Google Drive
        if let lastId = saved.lastReadingFolderId,
           let lastState = saved.states[lastId],
           let lastFolder = lastState.folderStack.last,
           !lastFolder.id.isEmpty {
            folderStack = lastState.folderStack

            if let diskFolder = LocalChapterStorage.shared.loadFolderSnapshotFromDisk(folderId: lastFolder.id),
               !diskFolder.chapters.isEmpty,
               let savedChapter = diskFolder.chapters.first(where: { $0.id == lastState.chapterId }),
               let localChapterText = LocalChapterStorage.shared.readChapterContent(chapterId: savedChapter.id),
               !localChapterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {

                let cachedTuple: (mode: ScreenMode, folders: [DriveItem], chapters: [DriveItem]) = (.chapters, [], diskFolder.chapters)
                folderCache[lastFolder.id] = cachedTuple
                chapterContentCache[savedChapter.id] = localChapterText

                chapters = diskFolder.chapters
                folders = []
                selectedChapter = savedChapter
                chapterContent = localChapterText
                screenMode = .reader
                readerScrollResetToken += 1

                if let idx = diskFolder.chapters.firstIndex(where: { $0.id == savedChapter.id }) {
                    tocStartIndex = computeTocStart(for: idx)
                    prefetchNextChapter(after: idx)
                }
                return
            }

            if let loaded = await loadFolder(lastFolder, silent: true),
               !loaded.chapters.isEmpty,
               let savedChapter = loaded.chapters.first(where: { $0.id == lastState.chapterId }) {
                chapters = loaded.chapters
                folders = []
                screenMode = .chapters
                await openChapter(savedChapter)
                return
            }
        }

        _ = await loadFolder(rootNode)
    }

    func refreshCurrentFolder() async {
        folderCache.removeValue(forKey: currentFolder.id)
        LocalChapterStorage.shared.clearFolderDiskCache(folderId: currentFolder.id)
        _ = await loadFolder(currentFolder, forceRefreshFromDrive: true)
    }

    func loadFolder(
        _ folder: FolderNode,
        silent: Bool = false,
        forceRefreshFromDrive: Bool = false
    ) async -> (mode: ScreenMode, folders: [DriveItem], chapters: [DriveItem])? {
        errorMessage = ""
        tocVisible = false
        nextSwipePromptVisible = false
        searchQuery = ""

        if !forceRefreshFromDrive {
            if let cached = folderCache[folder.id] {
                if !silent {
                    screenMode = cached.mode
                    folders = cached.folders
                    chapters = cached.chapters
                }
                return cached
            }

            if let diskCached = LocalChapterStorage.shared.loadFolderSnapshotFromDisk(folderId: folder.id) {
                let mode: ScreenMode = diskCached.isChaptersMode ? .chapters : .folders
                let tuple = (mode: mode, folders: diskCached.folders, chapters: diskCached.chapters)
                folderCache[folder.id] = tuple
                if !silent {
                    screenMode = mode
                    folders = diskCached.folders
                    chapters = diskCached.chapters
                }
                return tuple
            }
        }

        if !silent {
            isLoading = true
        }
        defer {
            if !silent {
                isLoading = false
            }
        }

        do {
            let children = try await DriveService.shared.listChildren(
                folderId: folder.id,
                apiKey: activeDriveApiKey
            )
            let txtFiles = children.filter { $0.isTextFile }
            let childFolders = children.filter { $0.isFolder }

            if !txtFiles.isEmpty {
                let result: (mode: ScreenMode, folders: [DriveItem], chapters: [DriveItem]) = (.chapters, [], txtFiles)
                folderCache[folder.id] = result
                LocalChapterStorage.shared.saveFolderSnapshotToDisk(
                    folderId: folder.id,
                    isChaptersMode: true,
                    folders: [],
                    chapters: txtFiles
                )
                if !silent {
                    screenMode = .chapters
                    folders = []
                    chapters = txtFiles
                }
                return result
            }

            let apiKey = activeDriveApiKey
            var enrichedFolders: [DriveItem] = []
            await withTaskGroup(of: (Int, String?).self) { group in
                for (index, item) in childFolders.enumerated() {
                    group.addTask {
                        let cover = await DriveService.shared.fetchFolderCover(folderId: item.id, apiKey: apiKey)
                        return (index, cover)
                    }
                }
                var coverMap: [Int: String?] = [:]
                for await (idx, cover) in group {
                    coverMap[idx] = cover
                }
                for (index, var item) in childFolders.enumerated() {
                    item.coverUrl = coverMap[index] ?? nil
                    enrichedFolders.append(item)
                }
            }

            let result: (mode: ScreenMode, folders: [DriveItem], chapters: [DriveItem]) = (.folders, enrichedFolders, [])
            folderCache[folder.id] = result
            LocalChapterStorage.shared.saveFolderSnapshotToDisk(
                folderId: folder.id,
                isChaptersMode: false,
                folders: enrichedFolders,
                chapters: []
            )
            if !silent {
                screenMode = .folders
                folders = enrichedFolders
                chapters = []
            }
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func openFolder(_ item: DriveItem) async {
        let node = FolderNode(id: item.id, name: item.name)
        folderStack.append(node)
        _ = await loadFolder(node)
    }

    var canNavigateBack: Bool {
        screenMode == .reader || folderStack.count > 1
    }

    func navigateBack() async {
        errorMessage = ""
        tocVisible = false
        nextSwipePromptVisible = false

        if screenMode == .reader {
            saveReadingProgress()
            screenMode = .chapters
            return
        }

        guard folderStack.count > 1 else { return }
        folderStack.removeLast()
        if let parent = folderStack.last {
            _ = await loadFolder(parent)
        }
    }

    // MARK: - Chapter Reading & Local File Caching / Overwriting
    func fetchChapterText(_ chapter: DriveItem, forceRemote: Bool = false) async throws -> String {
        if !forceRemote {
            if let localSaved = LocalChapterStorage.shared.readChapterContent(chapterId: chapter.id),
               !localSaved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chapterContentCache[chapter.id] = localSaved
                return localSaved
            }
            if let cached = chapterContentCache[chapter.id] {
                return cached
            }
        }

        let downloaded = try await DriveService.shared.downloadTextFile(
            fileId: chapter.id,
            apiKey: activeDriveApiKey
        )

        chapterContentCache[chapter.id] = downloaded
        if !LocalChapterStorage.shared.isChapterTranslated(chapter.id) {
            try? LocalChapterStorage.shared.overwriteChapterFile(
                chapterId: chapter.id,
                chapterName: chapter.name,
                content: downloaded,
                markAsTranslated: false
            )
        }
        return downloaded
    }

    func openChapter(_ chapter: DriveItem) async {
        errorMessage = ""
        selectedChapter = chapter
        tocVisible = false
        nextSwipePromptVisible = false

        if let localSaved = LocalChapterStorage.shared.readChapterContent(chapterId: chapter.id),
           !localSaved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chapterContentCache[chapter.id] = localSaved
            chapterContent = localSaved
            screenMode = .reader
            readerScrollResetToken += 1

            if let idx = chapters.firstIndex(where: { $0.id == chapter.id }) {
                tocStartIndex = computeTocStart(for: idx)
                prefetchNextChapter(after: idx)
            }
            saveReadingProgress(paragraphIndex: 0, chapterOverride: chapter)
            return
        }

        isLoading = true
        do {
            let text = try await fetchChapterText(chapter)
            chapterContent = text
            screenMode = .reader
            readerScrollResetToken += 1

            if let idx = chapters.firstIndex(where: { $0.id == chapter.id }) {
                tocStartIndex = computeTocStart(for: idx)
                prefetchNextChapter(after: idx)
            }
            saveReadingProgress(paragraphIndex: 0, chapterOverride: chapter)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func openNextChapter() async {
        let idx = currentChapterIndex
        guard idx >= 0, idx + 1 < chapters.count else { return }
        await openChapter(chapters[idx + 1])
    }

    func openPreviousChapter() async {
        let idx = currentChapterIndex
        guard idx > 0 else { return }
        await openChapter(chapters[idx - 1])
    }

    private func prefetchNextChapter(after index: Int) {
        guard index + 1 < chapters.count else { return }
        let nextChap = chapters[index + 1]
        guard !LocalChapterStorage.shared.hasLocalFile(for: nextChap.id),
              chapterContentCache[nextChap.id] == nil,
              !prefetchingIds.contains(nextChap.id) else { return }

        prefetchingIds.insert(nextChap.id)
        Task {
            _ = try? await fetchChapterText(nextChap)
            prefetchingIds.remove(nextChap.id)
        }
    }

    // MARK: - TOC Pagination
    private func computeTocStart(for index: Int) -> Int {
        guard index >= 0 else { return 0 }
        let maxStart = max(chapters.count - tocWindowSize, 0)
        return max(0, min(index - 3, maxStart))
    }

    func openTableOfContents() {
        let idx = currentChapterIndex >= 0
            ? currentChapterIndex
            : (chapters.firstIndex(where: { $0.id == currentStorySavedState?.chapterId }) ?? 0)
        tocStartIndex = computeTocStart(for: idx)
        tocVisible = true
    }

    func nextTocPage() {
        let maxStart = max(chapters.count - tocWindowSize, 0)
        tocStartIndex = min(tocStartIndex + tocWindowSize, maxStart)
    }

    func prevTocPage() {
        tocStartIndex = max(tocStartIndex - tocWindowSize, 0)
    }

    // MARK: - Gemini Translation Popup & Batch Overwrite
    func prepareAndOpenTranslationPopup() {
        guard !chapters.isEmpty else {
            showToast("Không có chương nào để dịch.")
            return
        }
        let currentIdx = max(0, currentChapterIndex)
        translateFromChapterIndex = currentIdx
        translateToChapterIndex = currentIdx
        translationStatusNote = ""
        showTranslationPopup = true
    }

    func cancelBatchTranslation() {
        translationTask?.cancel()
        isTranslatingBatch = false
        translationStatusNote = "Đã dừng tiến trình dịch."
    }

    func startBatchTranslation() {
        guard !chapters.isEmpty else { return }
        let startIdx = max(0, min(translateFromChapterIndex, translateToChapterIndex))
        let endIdx = min(chapters.count - 1, max(translateFromChapterIndex, translateToChapterIndex))

        let cleanKey = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            translationStatusNote = "⚠️ Bạn chưa nhập Gemini API Key! Hãy nhập API Key ngay bên dưới hoặc trong phần Cài đặt."
            return
        }

        isTranslatingBatch = true
        let targetSlice = Array(chapters[startIdx...endIdx])
        translationTotalCount = targetSlice.count
        translationProgressCount = 0
        translationStatusNote = "Đang khởi tạo tiến trình dịch..."

        translationTask = Task {
            var successCount = 0
            var switchedModelNotice = ""

            for (offset, chapter) in targetSlice.enumerated() {
                if Task.isCancelled { break }

                translationCurrentChapterTitle = chapter.cleanChapterName
                translationStatusNote = "Đang dịch (\(offset + 1)/\(targetSlice.count)): \(chapter.cleanChapterName)..."

                do {
                    let sourceText = try await fetchChapterText(chapter)

                    let outcome = try await GeminiService.shared.translateChapterContent(
                        rawContent: sourceText,
                        customInstruction: translationPrompt,
                        apiKey: cleanKey,
                        preferredModel: selectedGeminiModel,
                        autoFallbackWhenQuotaExceeded: autoSwitchTo31OnQuota
                    )

                    if outcome.didAutoSwitchToFallback {
                        selectedGeminiModel = outcome.usedModelChoice
                        switchedModelNotice = " (Đã tự động chuyển sang \(outcome.usedModelChoice.shortBadge) do hết quota)"
                    }

                    try LocalChapterStorage.shared.overwriteChapterFile(
                        chapterId: chapter.id,
                        chapterName: chapter.name,
                        content: outcome.translatedText,
                        markAsTranslated: true
                    )

                    chapterContentCache[chapter.id] = outcome.translatedText

                    if selectedChapter?.id == chapter.id {
                        chapterContent = outcome.translatedText
                    }

                    _ = await DriveService.shared.overwriteRemoteDriveFileIfPossible(
                        fileId: chapter.id,
                        content: outcome.translatedText,
                        apiKey: activeDriveApiKey,
                        accessToken: driveAccessToken
                    )

                    successCount += 1
                    translationProgressCount = offset + 1
                    translatedRevisionTrigger += 1
                } catch {
                    translationStatusNote = "❌ Lỗi tại \(chapter.cleanChapterName): \(error.localizedDescription)"
                    isTranslatingBatch = false
                    return
                }
            }

            isTranslatingBatch = false
            if !Task.isCancelled {
                translationStatusNote = "✅ Hoàn tất dịch và ghi đè \(successCount)/\(targetSlice.count) chương!\(switchedModelNotice)"
                showToast("Đã dịch và ghi đè \(successCount) chương thành công!")
            }
        }
    }

    func restoreOriginalFromDrive(for chapter: DriveItem) async {
        isLoading = true
        defer { isLoading = false }
        do {
            LocalChapterStorage.shared.removeTranslatedOverride(chapterId: chapter.id)
            chapterContentCache.removeValue(forKey: chapter.id)
            let original = try await fetchChapterText(chapter, forceRemote: true)
            if selectedChapter?.id == chapter.id {
                chapterContent = original
                readerScrollResetToken += 1
            }
            translatedRevisionTrigger += 1
            showToast("Đã khôi phục bản gốc từ Google Drive")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
