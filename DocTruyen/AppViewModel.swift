import Foundation
import SwiftUI
import UIKit

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
    private let skipAlreadyTranslatedStorageKey = "DOC_TRUYEN_SKIP_ALREADY_TRANSLATED"
    private let driveApiKeyOverrideStorageKey = "DOC_TRUYEN_DRIVE_API_KEY_OVERRIDE"
    private let driveFolderIdOverrideStorageKey = "DOC_TRUYEN_DRIVE_FOLDER_ID_OVERRIDE"
    private let driveAccessTokenStorageKey = "DOC_TRUYEN_DRIVE_ACCESS_TOKEN"
    private let driveAppsScriptUrlStorageKey = "DOC_TRUYEN_DRIVE_APPS_SCRIPT_URL"
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

    @Published var readerScrollResetToken: Int = 0
    @Published var tocScrollResetToken: Int = 0
    @Published var coverRevisionTrigger: Int = 0

    @Published var isLoading: Bool = false
    @Published var isChapterLoading: Bool = false
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
    @Published var skipAlreadyTranslatedInBatch: Bool = true {
        didSet { UserDefaults.standard.set(skipAlreadyTranslatedInBatch, forKey: skipAlreadyTranslatedStorageKey) }
    }

    // MARK: - Google Drive Configuration & Cloud Write Sync
    @Published var driveApiKeyOverride: String = "" {
        didSet { UserDefaults.standard.set(driveApiKeyOverride, forKey: driveApiKeyOverrideStorageKey) }
    }
    @Published var driveFolderIdOverride: String = "" {
        didSet {
            if DriveInputParser.isAppsScriptUrl(driveFolderIdOverride) {
                let normalized = DriveInputParser.normalizeAppsScriptUrl(driveFolderIdOverride)
                driveAppsScriptUrl = normalized
                driveFolderIdOverride = ""
                UserDefaults.standard.set("", forKey: driveFolderIdOverrideStorageKey)
                showToast("Đã tự động nhận diện Link Apps Script và giữ nguyên thư mục truyện!")
                return
            }
            UserDefaults.standard.set(driveFolderIdOverride, forKey: driveFolderIdOverrideStorageKey)
        }
    }
    @Published var driveAppsScriptUrl: String = "" {
        didSet {
            let normalized = DriveInputParser.normalizeAppsScriptUrl(driveAppsScriptUrl)
            if normalized != driveAppsScriptUrl {
                driveAppsScriptUrl = normalized
                return
            }
            UserDefaults.standard.set(driveAppsScriptUrl, forKey: driveAppsScriptUrlStorageKey)
        }
    }
    @Published var driveAccessToken: String = "" {
        didSet { UserDefaults.standard.set(driveAccessToken, forKey: driveAccessTokenStorageKey) }
    }

    // MARK: - Modals, Background Translation & Background Drive Sync State
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

    @Published var isSyncingToDrive: Bool = false
    @Published var driveSyncProgressCount: Int = 0
    @Published var driveSyncTotalCount: Int = 0
    @Published var driveSyncStatusNote: String = ""

    // MARK: - In-Memory Caches & Tasks
    private var folderCache: [String: (mode: ScreenMode, folders: [DriveItem], chapters: [DriveItem])] = [:]
    private var chapterContentCache: [String: String] = [:]
    private var prefetchingIds: Set<String> = []
    private var fetchingCoverFolderIds: Set<String> = []
    private var translationTask: Task<Void, Never>?
    private var driveSyncTask: Task<Void, Never>?
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

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
            let parsed = DriveInputParser.extractFolderId(from: secret)
            if !parsed.isEmpty { return parsed }
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

    var isCloudOverwriteConfigured: Bool {
        !driveAppsScriptUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !driveAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        folderStack.last ?? FolderNode(id: activeRootFolderId, name: "")
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

    var orderedUntranslatedChapters: [DriveItem] {
        guard !chapters.isEmpty else { return [] }
        let startIdx = max(0, currentChapterIndex)
        let forwardSlice = Array(chapters[startIdx..<chapters.count])
        let backwardSlice = startIdx > 0 ? Array(chapters[0..<startIdx]) : []
        let combined = forwardSlice + backwardSlice
        return combined.filter { !LocalChapterStorage.shared.isChapterTranslated($0.id) }
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
        if defaults.object(forKey: skipAlreadyTranslatedStorageKey) != nil {
            skipAlreadyTranslatedInBatch = defaults.bool(forKey: skipAlreadyTranslatedStorageKey)
        }
        if let savedDriveKey = defaults.string(forKey: driveApiKeyOverrideStorageKey) {
            driveApiKeyOverride = savedDriveKey
        }
        if let savedScriptUrl = defaults.string(forKey: driveAppsScriptUrlStorageKey) {
            driveAppsScriptUrl = DriveInputParser.normalizeAppsScriptUrl(savedScriptUrl)
        }
        if let savedDriveFolder = defaults.string(forKey: driveFolderIdOverrideStorageKey) {
            if DriveInputParser.isAppsScriptUrl(savedDriveFolder) {
                if driveAppsScriptUrl.isEmpty {
                    driveAppsScriptUrl = DriveInputParser.normalizeAppsScriptUrl(savedDriveFolder)
                }
                driveFolderIdOverride = ""
                defaults.set("", forKey: driveFolderIdOverrideStorageKey)
            } else if DriveInputParser.extractFolderId(from: savedDriveFolder).isEmpty {
                driveFolderIdOverride = ""
                defaults.set("", forKey: driveFolderIdOverrideStorageKey)
            } else {
                driveFolderIdOverride = savedDriveFolder
            }
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

    private func updateKeepAwakeState() {
        let active = isTranslatingBatch || isSyncingToDrive
        UIApplication.shared.isIdleTimerDisabled = active

        if active {
            if backgroundTaskId == .invalid {
                backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "DocTruyenCloudSync") { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        if self.backgroundTaskId != .invalid {
                            UIApplication.shared.endBackgroundTask(self.backgroundTaskId)
                            self.backgroundTaskId = .invalid
                        }
                    }
                }
            }
        } else {
            if backgroundTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskId)
                backgroundTaskId = .invalid
            }
        }
    }

    func resetPromptToDefault() {
        translationPrompt = DefaultPrompts.standardNovelPolish
        showToast("Đã khôi phục câu lệnh dịch mặc định")
    }

    func applyCustomDriveSettingsAndReload() async {
        if DriveInputParser.isAppsScriptUrl(driveFolderIdOverride) {
            driveAppsScriptUrl = DriveInputParser.normalizeAppsScriptUrl(driveFolderIdOverride)
            driveFolderIdOverride = ""
        }
        folderCache.removeAll()
        LocalChapterStorage.shared.clearFolderDiskCache()
        LocalChapterStorage.shared.clearCoverCache()
        let rootNode = FolderNode(id: activeRootFolderId, name: "")
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
              var decoded = try? JSONDecoder().decode(PersistedReadingData.self, from: data) else {
            return PersistedReadingData(states: [:], lastReadingFolderId: nil)
        }
        decoded.states = decoded.states.filter { key, state in
            let validKey = !DriveInputParser.extractFolderId(from: key).isEmpty
            let validStack = state.folderStack.allSatisfy { !DriveInputParser.extractFolderId(from: $0.id).isEmpty }
            return validKey && validStack
        }
        if let lastId = decoded.lastReadingFolderId, decoded.states[lastId] == nil {
            decoded.lastReadingFolderId = nil
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
            chapterName: chapter.cleanChapterName,
            paragraphIndex: paragraphIndex,
            savedAt: Date().timeIntervalSince1970
        )
        readingStates[storyFolderId] = state
        lastReadingFolderId = storyFolderId
        persistReadingData()
    }

    // MARK: - App Initialization & Instant Offline Restore
    func initializeApp() async {
        let rootNode = FolderNode(id: activeRootFolderId, name: "")
        folderStack = [rootNode]

        let saved = loadPersistedReadingData()
        readingStates = saved.states
        lastReadingFolderId = saved.lastReadingFolderId

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

        folderStack = [rootNode]
        _ = await loadFolder(rootNode)
    }

    func refreshCurrentFolder() async {
        folderCache.removeValue(forKey: currentFolder.id)
        LocalChapterStorage.shared.clearFolderDiskCache(folderId: currentFolder.id)
        _ = await loadFolder(currentFolder, forceRefreshFromDrive: true)
    }

    // MARK: - Tự động quét & tải ảnh bìa cho từng thư mục truyện (kể cả khi danh sách thư mục lấy từ cache)
    private func ensureFolderCoversLoaded(for targetFolders: [DriveItem], parentFolderId: String) {
        let missingFolders = targetFolders.filter { item in
            !LocalChapterStorage.shared.hasCachedCoverImage(for: item.id) &&
            !fetchingCoverFolderIds.contains(item.id)
        }
        guard !missingFolders.isEmpty else { return }

        for item in missingFolders {
            fetchingCoverFolderIds.insert(item.id)
        }

        let apiKey = activeDriveApiKey
        let scriptUrl = driveAppsScriptUrl

        Task {
            // Tải theo từng đợt 3 thư mục một lúc để Google Drive API không bao giờ chặn rate-limit
            let batchSize = 3
            for start in stride(from: 0, to: missingFolders.count, by: batchSize) {
                let end = min(start + batchSize, missingFolders.count)
                let slice = Array(missingFolders[start..<end])

                await withTaskGroup(of: (String, String?).self) { group in
                    for folderItem in slice {
                        group.addTask {
                            let resolved = await DriveService.shared.fetchAndCacheFolderCover(
                                folderId: folderItem.id,
                                apiKey: apiKey,
                                appsScriptWebAppUrl: scriptUrl
                            )
                            return (folderItem.id, resolved)
                        }
                    }

                    for await (folderId, coverLink) in group {
                        self.fetchingCoverFolderIds.remove(folderId)
                        if let coverLink {
                            if let idx = self.folders.firstIndex(where: { $0.id == folderId }) {
                                self.folders[idx].coverUrl = coverLink
                            }
                            self.coverRevisionTrigger += 1
                        }
                    }
                }

                // Lưu lại danh sách đã cập nhật ảnh bìa vào cache ổ đĩa
                if !self.folders.isEmpty && self.currentFolder.id == parentFolderId {
                    self.folderCache[parentFolderId] = (.folders, self.folders, [])
                    LocalChapterStorage.shared.saveFolderSnapshotToDisk(
                        folderId: parentFolderId,
                        isChaptersMode: false,
                        folders: self.folders,
                        chapters: []
                    )
                }

                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
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

        let cleanFolderId = DriveInputParser.extractFolderId(from: folder.id)
        let targetFolderId = cleanFolderId.isEmpty ? activeRootFolderId : cleanFolderId

        if !forceRefreshFromDrive {
            if let cached = folderCache[targetFolderId], (!cached.folders.isEmpty || !cached.chapters.isEmpty) {
                if !silent {
                    screenMode = cached.mode
                    folders = cached.folders
                    chapters = cached.chapters
                    if cached.mode == .folders {
                        ensureFolderCoversLoaded(for: cached.folders, parentFolderId: targetFolderId)
                    }
                }
                return cached
            }

            if let diskCached = LocalChapterStorage.shared.loadFolderSnapshotFromDisk(folderId: targetFolderId) {
                let mode: ScreenMode = diskCached.isChaptersMode ? .chapters : .folders
                let tuple = (mode: mode, folders: diskCached.folders, chapters: diskCached.chapters)
                folderCache[targetFolderId] = tuple
                if !silent {
                    screenMode = mode
                    folders = diskCached.folders
                    chapters = diskCached.chapters
                    if mode == .folders {
                        ensureFolderCoversLoaded(for: diskCached.folders, parentFolderId: targetFolderId)
                    }
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
                folderId: targetFolderId,
                apiKey: activeDriveApiKey,
                appsScriptWebAppUrl: driveAppsScriptUrl
            )
            let txtFiles = children.filter { $0.isTextFile }
            let childFolders = children.filter { $0.isFolder }

            // Nếu trong thư mục truyện hiện tại có file ảnh (không phải folder, không phải .txt),
            // lưu ngay làm ảnh đại diện cho thư mục truyện này!
            if let coverCandidate = children.first(where: { !$0.isFolder && !$0.isTextFile }) {
                let apiKey = activeDriveApiKey
                Task {
                    if await DriveService.shared.downloadAndCacheCoverFile(
                        coverCandidate,
                        forFolderId: targetFolderId,
                        apiKey: apiKey
                    ) {
                        self.coverRevisionTrigger += 1
                    }
                }
            }

            if !txtFiles.isEmpty {
                let result: (mode: ScreenMode, folders: [DriveItem], chapters: [DriveItem]) = (.chapters, [], txtFiles)
                folderCache[targetFolderId] = result
                LocalChapterStorage.shared.saveFolderSnapshotToDisk(
                    folderId: targetFolderId,
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

            let result: (mode: ScreenMode, folders: [DriveItem], chapters: [DriveItem]) = (.folders, childFolders, [])
            if !childFolders.isEmpty {
                folderCache[targetFolderId] = result
                LocalChapterStorage.shared.saveFolderSnapshotToDisk(
                    folderId: targetFolderId,
                    isChaptersMode: false,
                    folders: childFolders,
                    chapters: []
                )
            }
            if !silent {
                screenMode = .folders
                folders = childFolders
                chapters = []
                ensureFolderCoversLoaded(for: childFolders, parentFolderId: targetFolderId)
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

    // MARK: - Chapter Reading & Local File Caching
    func fetchChapterText(_ chapter: DriveItem, forceRemote: Bool = false) async throws -> String {
        if !forceRemote {
            if let localSaved = LocalChapterStorage.shared.readChapterContent(chapterId: chapter.id),
               !localSaved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chapterContentCache[chapter.id] = localSaved
                return localSaved
            }
            if let cached = chapterContentCache[chapter.id],
               !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return cached
            }
        }

        let downloaded = try await DriveService.shared.downloadTextFile(
            fileId: chapter.id,
            apiKey: activeDriveApiKey,
            appsScriptWebAppUrl: driveAppsScriptUrl,
            accessToken: driveAccessToken
        )

        chapterContentCache[chapter.id] = downloaded
        LocalChapterStorage.shared.saveOriginalChapterIfNeeded(chapterId: chapter.id, content: downloaded)

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

    private func fetchSourceTextForTranslation(_ chapter: DriveItem) async throws -> String {
        if let rawOriginal = LocalChapterStorage.shared.readOriginalChapterContent(chapterId: chapter.id),
           !rawOriginal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return rawOriginal
        }
        if !LocalChapterStorage.shared.isChapterTranslated(chapter.id),
           let localUntranslated = LocalChapterStorage.shared.readChapterContent(chapterId: chapter.id),
           !localUntranslated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LocalChapterStorage.shared.saveOriginalChapterIfNeeded(chapterId: chapter.id, content: localUntranslated)
            return localUntranslated
        }
        return try await fetchChapterText(chapter, forceRemote: true)
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

        if let cached = chapterContentCache[chapter.id],
           !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chapterContent = cached
            screenMode = .reader
            readerScrollResetToken += 1

            if let idx = chapters.firstIndex(where: { $0.id == chapter.id }) {
                tocStartIndex = computeTocStart(for: idx)
                prefetchNextChapter(after: idx)
            }
            saveReadingProgress(paragraphIndex: 0, chapterOverride: chapter)
            return
        }

        screenMode = .reader
        isChapterLoading = true
        chapterContent = "Đang tải nội dung \(chapter.cleanChapterName)..."
        do {
            let text = try await fetchChapterText(chapter)
            if selectedChapter?.id == chapter.id {
                chapterContent = text
                readerScrollResetToken += 1
            }

            if let idx = chapters.firstIndex(where: { $0.id == chapter.id }) {
                tocStartIndex = computeTocStart(for: idx)
                prefetchNextChapter(after: idx)
            }
            saveReadingProgress(paragraphIndex: 0, chapterOverride: chapter)
        } catch {
            errorMessage = error.localizedDescription
            if selectedChapter?.id == chapter.id {
                chapterContent = "Không tải được nội dung chương: \(error.localizedDescription)"
            }
        }
        isChapterLoading = false
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
        let pageIndex = index / tocWindowSize
        return pageIndex * tocWindowSize
    }

    func openTableOfContents() {
        let idx = currentChapterIndex >= 0
            ? currentChapterIndex
            : (chapters.firstIndex(where: { $0.id == currentStorySavedState?.chapterId }) ?? 0)
        tocStartIndex = computeTocStart(for: idx)
        tocScrollResetToken += 1
        tocVisible = true
    }

    func nextTocPage() {
        let maxStart = max(chapters.count - tocWindowSize, 0)
        tocStartIndex = min(tocStartIndex + tocWindowSize, maxStart)
        tocScrollResetToken += 1
    }

    func prevTocPage() {
        tocStartIndex = max(tocStartIndex - tocWindowSize, 0)
        tocScrollResetToken += 1
    }

    // MARK: - Gemini Translation & Guaranteed Cloud Overwrite
    func prepareAndOpenTranslationPopup() {
        guard !chapters.isEmpty else {
            showToast("Không có chương nào để dịch.")
            return
        }
        if !isTranslatingBatch {
            let currentIdx = max(0, currentChapterIndex)
            translateFromChapterIndex = currentIdx
            translateToChapterIndex = currentIdx
            translationStatusNote = ""
        }
        showTranslationPopup = true
    }

    func cancelBatchTranslation() {
        translationTask?.cancel()
        isTranslatingBatch = false
        updateKeepAwakeState()
        translationStatusNote = "Đã dừng tiến trình dịch."
    }

    @discardableResult
    func startAutoTranslateAllUntranslatedInBackground() -> Bool {
        guard !chapters.isEmpty else { return false }

        let untranslatedTarget = orderedUntranslatedChapters
        let unsyncedTranslated = LocalChapterStorage.shared.unsyncedTranslatedChapters(in: chapters)

        if untranslatedTarget.isEmpty {
            if !unsyncedTranslated.isEmpty && isCloudOverwriteConfigured {
                Task {
                    await syncAllTranslatedChaptersToDrive(onlyUnsynced: true)
                }
                showToast("Tất cả chương đã dịch! Đang tự động ghi đè bù \(unsyncedTranslated.count) chương lên Drive...")
                return true
            }
            showToast("Tất cả \(chapters.count) chương trong truyện đều đã được dịch!")
            return false
        }

        let cleanKey = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            translationStatusNote = "⚠️ Bạn chưa nhập Gemini API Key! Hãy nhập API Key bên dưới."
            return false
        }

        runTranslationPipeline(
            targetSlice: untranslatedTarget,
            cleanKey: cleanKey,
            shouldSkipTranslated: true,
            modeLabel: "Dịch ngầm tự động"
        )
        showToast("Đang dịch & ghi đè ngầm \(untranslatedTarget.count) chương chưa dịch...")
        return true
    }

    func startBatchTranslation() {
        guard !chapters.isEmpty else { return }
        let startIdx = max(0, min(translateFromChapterIndex, translateToChapterIndex))
        let endIdx = min(chapters.count - 1, max(translateFromChapterIndex, translateToChapterIndex))

        let cleanKey = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetSlice = Array(chapters[startIdx...endIdx])

        let hasUntranslatedInSlice = targetSlice.contains { !LocalChapterStorage.shared.isChapterTranslated($0.id) }
        if (hasUntranslatedInSlice || !skipAlreadyTranslatedInBatch) && cleanKey.isEmpty {
            translationStatusNote = "⚠️ Bạn chưa nhập Gemini API Key! Hãy nhập API Key bên dưới."
            return
        }

        runTranslationPipeline(
            targetSlice: targetSlice,
            cleanKey: cleanKey,
            shouldSkipTranslated: skipAlreadyTranslatedInBatch,
            modeLabel: "Dịch theo phạm vi"
        )
    }

    private func runTranslationPipeline(
        targetSlice: [DriveItem],
        cleanKey: String,
        shouldSkipTranslated: Bool,
        modeLabel: String
    ) {
        translationTask?.cancel()
        isTranslatingBatch = true
        updateKeepAwakeState()

        translationTotalCount = targetSlice.count
        translationProgressCount = 0
        translationStatusNote = "Đang khởi tạo \(modeLabel.lowercased()) (\(targetSlice.count) chương)..."
        let currentStoryTitle = currentFolder.name

        translationTask = Task {
            var translatedSuccessCount = 0
            var cloudSuccessCount = 0
            var switchedModelNotice = ""
            var lastDriveWarning = ""
            var failedChaptersForRetry: [DriveItem] = []

            for (offset, chapter) in targetSlice.enumerated() {
                if Task.isCancelled { break }

                let alreadyTranslatedLocally = LocalChapterStorage.shared.isChapterTranslated(chapter.id)
                let alreadySyncedToDrive = LocalChapterStorage.shared.isChapterSyncedToDrive(chapter.id)

                if alreadyTranslatedLocally && shouldSkipTranslated {
                    if let localTranslatedText = LocalChapterStorage.shared.readChapterContent(chapterId: chapter.id),
                       !localTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {

                        if !alreadySyncedToDrive && isCloudOverwriteConfigured {
                            translationCurrentChapterTitle = chapter.cleanChapterName
                            translationStatusNote = "Đang ghi đè bù (\(offset + 1)/\(targetSlice.count)): \(chapter.cleanChapterName)..."

                            let savedTitle = LocalChapterStorage.shared.customTitle(for: chapter.id)
                                ?? ChapterTitleExtractor.extractUpdatedChapterTitle(
                                    rawFileName: chapter.name,
                                    storyTitle: currentStoryTitle,
                                    chapterContent: localTranslatedText
                                )

                            let driveSync = await DriveService.shared.overwriteRemoteDriveFile(
                                fileId: chapter.id,
                                newFileName: savedTitle,
                                content: localTranslatedText,
                                apiKey: activeDriveApiKey,
                                appsScriptWebAppUrl: driveAppsScriptUrl,
                                accessToken: driveAccessToken
                            )
                            if driveSync.success {
                                LocalChapterStorage.shared.markChapterSyncedToDrive(chapter.id, synced: true)
                                cloudSuccessCount += 1
                            } else {
                                lastDriveWarning = driveSync.message
                            }
                            try? await Task.sleep(nanoseconds: 250_000_000)
                        } else if alreadySyncedToDrive {
                            cloudSuccessCount += 1
                        }

                        translatedSuccessCount += 1
                        translationProgressCount = offset + 1
                        translatedRevisionTrigger += 1
                        continue
                    }
                }

                translationCurrentChapterTitle = chapter.cleanChapterName
                translationStatusNote = "Đang dịch (\(offset + 1)/\(targetSlice.count)): \(chapter.cleanChapterName)..."

                let stepSuccess = await translateAndOverwriteSingleChapter(
                    chapter: chapter,
                    storyTitle: currentStoryTitle,
                    apiKey: cleanKey,
                    switchedModelNotice: &switchedModelNotice,
                    cloudSuccessCount: &cloudSuccessCount,
                    lastDriveWarning: &lastDriveWarning
                )

                if stepSuccess {
                    translatedSuccessCount += 1
                } else {
                    failedChaptersForRetry.append(chapter)
                }

                translationProgressCount = offset + 1
                translatedRevisionTrigger += 1

                if offset + 1 < targetSlice.count && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
            }

            if !failedChaptersForRetry.isEmpty && !Task.isCancelled {
                translationStatusNote = "Đang tự động thử lại \(failedChaptersForRetry.count) chương bị nghẽn mạng..."
                try? await Task.sleep(nanoseconds: 2_500_000_000)

                for (retryIdx, chapter) in failedChaptersForRetry.enumerated() {
                    if Task.isCancelled { break }
                    translationCurrentChapterTitle = chapter.cleanChapterName
                    translationStatusNote = "Thử lại (\(retryIdx + 1)/\(failedChaptersForRetry.count)): \(chapter.cleanChapterName)..."

                    let retryOk = await translateAndOverwriteSingleChapter(
                        chapter: chapter,
                        storyTitle: currentStoryTitle,
                        apiKey: cleanKey,
                        switchedModelNotice: &switchedModelNotice,
                        cloudSuccessCount: &cloudSuccessCount,
                        lastDriveWarning: &lastDriveWarning
                    )
                    if retryOk {
                        translatedSuccessCount += 1
                        translatedRevisionTrigger += 1
                    }
                }
            }

            if isCloudOverwriteConfigured && !Task.isCancelled && !isSyncingToDrive {
                let remainingUnsynced = LocalChapterStorage.shared.unsyncedTranslatedChapters(in: chapters)
                if !remainingUnsynced.isEmpty {
                    for (idx, unsyncedChap) in remainingUnsynced.enumerated() {
                        if Task.isCancelled { break }
                        guard let localText = LocalChapterStorage.shared.readChapterContent(chapterId: unsyncedChap.id),
                              !localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            continue
                        }
                        translationCurrentChapterTitle = unsyncedChap.cleanChapterName
                        translationStatusNote = "Đang ghi đè bù lên Drive (\(idx + 1)/\(remainingUnsynced.count)): \(unsyncedChap.cleanChapterName)..."

                        let newTitle = LocalChapterStorage.shared.customTitle(for: unsyncedChap.id)
                            ?? ChapterTitleExtractor.extractUpdatedChapterTitle(
                                rawFileName: unsyncedChap.name,
                                storyTitle: currentStoryTitle,
                                chapterContent: localText
                            )

                        let res = await DriveService.shared.overwriteRemoteDriveFile(
                            fileId: unsyncedChap.id,
                            newFileName: newTitle,
                            content: localText,
                            apiKey: activeDriveApiKey,
                            appsScriptWebAppUrl: driveAppsScriptUrl,
                            accessToken: driveAccessToken
                        )
                        if res.success {
                            LocalChapterStorage.shared.markChapterSyncedToDrive(unsyncedChap.id, synced: true)
                            cloudSuccessCount += 1
                            translatedRevisionTrigger += 1
                        } else {
                            lastDriveWarning = res.message
                        }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
            }

            if !chapters.isEmpty {
                folderCache[currentFolder.id] = (.chapters, [], chapters)
                LocalChapterStorage.shared.saveFolderSnapshotToDisk(
                    folderId: currentFolder.id,
                    isChaptersMode: true,
                    folders: [],
                    chapters: chapters
                )
            }

            isTranslatingBatch = false
            updateKeepAwakeState()

            if !Task.isCancelled {
                let totalUnsyncedLeft = LocalChapterStorage.shared.unsyncedTranslatedChapters(in: chapters).count
                if isCloudOverwriteConfigured {
                    if totalUnsyncedLeft == 0 {
                        translationStatusNote = "✅ Hoàn tất! Đã dịch & ghi đè đầy đủ \(translatedSuccessCount)/\(targetSlice.count) chương lên Google Drive!\(switchedModelNotice)"
                    } else {
                        translationStatusNote = "⚠️ Đã dịch \(translatedSuccessCount)/\(targetSlice.count) chương, còn \(totalUnsyncedLeft) chương chờ lên Drive (\(lastDriveWarning))."
                    }
                } else {
                    translationStatusNote = "✅ Đã dịch & lưu \(translatedSuccessCount)/\(targetSlice.count) chương vào bộ nhớ máy!\(switchedModelNotice)"
                }
                showToast("Đã xử lý xong \(translatedSuccessCount)/\(targetSlice.count) chương!")
            }
        }
    }

    private func translateAndOverwriteSingleChapter(
        chapter: DriveItem,
        storyTitle: String,
        apiKey: String,
        switchedModelNotice: inout String,
        cloudSuccessCount: inout Int,
        lastDriveWarning: inout String
    ) async -> Bool {
        do {
            let sourceText = try await fetchSourceTextForTranslation(chapter)

            let outcome = try await GeminiService.shared.translateChapterContent(
                rawContent: sourceText,
                customInstruction: translationPrompt,
                apiKey: apiKey,
                preferredModel: selectedGeminiModel,
                autoFallbackWhenQuotaExceeded: autoSwitchTo31OnQuota
            )

            if outcome.didAutoSwitchToFallback {
                selectedGeminiModel = outcome.usedModelChoice
                switchedModelNotice = " (Đã tự động chuyển sang \(outcome.usedModelChoice.shortBadge))"
            }

            let extractedNewTitle = ChapterTitleExtractor.extractUpdatedChapterTitle(
                rawFileName: chapter.name,
                storyTitle: storyTitle,
                chapterContent: outcome.translatedText
            )

            try LocalChapterStorage.shared.overwriteChapterFile(
                chapterId: chapter.id,
                chapterName: chapter.name,
                content: outcome.translatedText,
                markAsTranslated: true,
                markAsSyncedToDrive: false,
                updatedChapterTitle: extractedNewTitle
            )

            chapterContentCache[chapter.id] = outcome.translatedText

            if let newTitle = extractedNewTitle {
                if let globalIdx = chapters.firstIndex(where: { $0.id == chapter.id }) {
                    chapters[globalIdx].name = "\(newTitle).txt"
                }
                if selectedChapter?.id == chapter.id {
                    selectedChapter?.name = "\(newTitle).txt"
                }
            }

            if selectedChapter?.id == chapter.id {
                chapterContent = outcome.translatedText
            }

            if isCloudOverwriteConfigured {
                translationStatusNote = "Đang ghi đè lên Drive: \(extractedNewTitle ?? chapter.cleanChapterName)..."
                let driveSync = await DriveService.shared.overwriteRemoteDriveFile(
                    fileId: chapter.id,
                    newFileName: extractedNewTitle,
                    content: outcome.translatedText,
                    apiKey: activeDriveApiKey,
                    appsScriptWebAppUrl: driveAppsScriptUrl,
                    accessToken: driveAccessToken
                )
                if driveSync.success {
                    LocalChapterStorage.shared.markChapterSyncedToDrive(chapter.id, synced: true)
                    cloudSuccessCount += 1
                } else {
                    lastDriveWarning = driveSync.message
                }
            }

            return true
        } catch {
            lastDriveWarning = error.localizedDescription
            return false
        }
    }

    func syncAllTranslatedChaptersToDrive(onlyUnsynced: Bool = false) async {
        let targetList: [DriveItem]
        if onlyUnsynced {
            targetList = LocalChapterStorage.shared.unsyncedTranslatedChapters(in: chapters)
        } else {
            targetList = chapters.filter { LocalChapterStorage.shared.isChapterTranslated($0.id) }
        }

        guard !targetList.isEmpty else {
            showToast("Tất cả chương đã dịch đều đã được ghi đè lên Google Drive!")
            return
        }
        guard isCloudOverwriteConfigured else {
            showToast("Hãy dán Link Apps Script hoặc OAuth Token trước.")
            return
        }

        driveSyncTask?.cancel()
        isSyncingToDrive = true
        updateKeepAwakeState()

        driveSyncTotalCount = targetList.count
        driveSyncProgressCount = 0
        driveSyncStatusNote = "Đang ghi đè ngầm \(targetList.count) chương lên Drive..."
        let currentStoryTitle = currentFolder.name

        driveSyncTask = Task {
            var syncedCount = 0
            var lastErrorMsg = ""

            for (idx, chap) in targetList.enumerated() {
                if Task.isCancelled { break }

                guard let localText = LocalChapterStorage.shared.readChapterContent(chapterId: chap.id),
                      !localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    driveSyncProgressCount = idx + 1
                    continue
                }

                driveSyncStatusNote = "Đang ghi đè (\(idx + 1)/\(targetList.count)): \(chap.cleanChapterName)"

                let newTitle = LocalChapterStorage.shared.customTitle(for: chap.id)
                    ?? ChapterTitleExtractor.extractUpdatedChapterTitle(
                        rawFileName: chap.name,
                        storyTitle: currentStoryTitle,
                        chapterContent: localText
                    )

                let res = await DriveService.shared.overwriteRemoteDriveFile(
                    fileId: chap.id,
                    newFileName: newTitle,
                    content: localText,
                    apiKey: activeDriveApiKey,
                    appsScriptWebAppUrl: driveAppsScriptUrl,
                    accessToken: driveAccessToken
                )
                if res.success {
                    LocalChapterStorage.shared.markChapterSyncedToDrive(chap.id, synced: true)
                    syncedCount += 1
                    translatedRevisionTrigger += 1
                } else {
                    lastErrorMsg = res.message
                }

                driveSyncProgressCount = idx + 1
                if idx + 1 < targetList.count && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }

            isSyncingToDrive = false
            updateKeepAwakeState()

            if !Task.isCancelled {
                if syncedCount == targetList.count {
                    driveSyncStatusNote = "✅ Đã ghi đè đủ \(syncedCount)/\(targetList.count) chương lên Google Drive!"
                    showToast("Đã ghi đè \(syncedCount)/\(targetList.count) chương lên Drive!")
                } else {
                    driveSyncStatusNote = "⚠️ Đã ghi đè \(syncedCount)/\(targetList.count) chương. Lỗi: \(lastErrorMsg)"
                    showToast("Đã ghi đè \(syncedCount)/\(targetList.count) chương lên Drive")
                }
            }
        }
    }

    func cancelDriveSync() {
        driveSyncTask?.cancel()
        isSyncingToDrive = false
        updateKeepAwakeState()
        driveSyncStatusNote = "Đã dừng đồng bộ Google Drive."
    }

    func restoreOriginalFromDrive(for chapter: DriveItem) async {
        isChapterLoading = true
        defer { isChapterLoading = false }
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
