import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @ObservedObject private var speechManager = StorySpeechManager.shared

    var body: some View {
        let palette = ThemePalette.forTheme(viewModel.readerTheme)

        ZStack(alignment: .bottom) {
            palette.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar(palette: palette)

                if !viewModel.errorMessage.isEmpty {
                    errorBanner
                }

                if viewModel.isLoading {
                    loadingStateView(palette: palette)
                } else {
                    mainBodyContent(palette: palette)
                }
            }

            if viewModel.screenMode == .reader && viewModel.showSpeechControls {
                readerFloatingUtilityBar(palette: palette)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            if !viewModel.toastMessage.isEmpty {
                toastCapsule
                    .padding(.bottom, (viewModel.screenMode == .reader && viewModel.showSpeechControls) ? 88 : 24)
            }
        }
        .sheet(isPresented: $viewModel.showSettingsSheet) {
            SettingsSheetView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showTranslationPopup) {
            TranslationRangeSheetView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.tocVisible) {
            TableOfContentsSheetView(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private func mainBodyContent(palette: ThemePalette) -> some View {
        switch viewModel.screenMode {
        case .folders:
            foldersContentView(palette: palette)
        case .chapters:
            chaptersContentView(palette: palette)
        case .reader:
            readerContentView(palette: palette)
        }
    }

    // MARK: - Thanh điều khiển nổi Nghe truyện AI (Đã tách nhỏ View để trình biên dịch Swift không bao giờ bị treo)
    private func readerFloatingUtilityBar(palette: ThemePalette) -> some View {
        HStack(spacing: 8) {
            speechTransportButtons(palette: palette)
            speechVoiceSelectorMenu(palette: palette)
            Spacer(minLength: 4)
            speechSpeedControls(palette: palette)
            speechCloseButton(palette: palette)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(palette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
    }

    private func speechTransportButtons(palette: ThemePalette) -> some View {
        let isPlayingNow = speechManager.isSpeaking && !speechManager.isPaused
        let playIcon = isPlayingNow ? "pause.fill" : "play.fill"

        return HStack(spacing: 6) {
            Button {
                speechManager.skipBackwardChunk()
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(palette.accent.opacity(0.14))
                    .foregroundStyle(palette.accent)
                    .clipShape(Circle())
            }

            Button {
                viewModel.toggleSpeechPlayback()
            } label: {
                ZStack {
                    if speechManager.isBuffering {
                        ProgressView()
                            .tint(Color.white)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: playIcon)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .frame(width: 34, height: 34)
                .background(palette.accent)
                .clipShape(Circle())
            }

            Button {
                speechManager.skipForwardChunk()
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(palette.accent.opacity(0.14))
                    .foregroundStyle(palette.accent)
                    .clipShape(Circle())
            }
        }
    }

    private func speechVoiceSelectorMenu(palette: ThemePalette) -> some View {
        let currentChunk = min(speechManager.currentChunkIndex + 1, max(speechManager.totalChunks, 1))
        let totalChunks = max(speechManager.totalChunks, 1)

        return Menu {
            ForEach(StoryVoiceChoice.allCases) { voice in
                Button {
                    speechManager.selectedVoiceChoice = voice
                } label: {
                    Text(voice.displayName)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(speechManager.selectedVoiceChoice.shortName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(palette.accent)
                }
                Text("Đoạn \(currentChunk)/\(totalChunks)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }

    private func speechSpeedControls(palette: ThemePalette) -> some View {
        let speedLabel = String(format: "%.1fx", speechManager.playbackSpeedMultiplier)

        return HStack(spacing: 4) {
            Button {
                speechManager.adjustSpeed(delta: -0.1)
            } label: {
                Text("-")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(palette.accent.opacity(0.14))
                    .foregroundStyle(palette.accent)
                    .clipShape(Circle())
            }

            Text(speedLabel)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.primaryText)
                .frame(width: 34)

            Button {
                speechManager.adjustSpeed(delta: 0.1)
            } label: {
                Text("+")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(palette.accent.opacity(0.14))
                    .foregroundStyle(palette.accent)
                    .clipShape(Circle())
            }
        }
    }

    private func speechCloseButton(palette: ThemePalette) -> some View {
        Button {
            viewModel.stopSpeechPlayback()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Color.secondary.opacity(0.16))
                .foregroundStyle(palette.secondaryText)
                .clipShape(Circle())
        }
    }

    // MARK: - Top Navigation Header (Tách riêng 3 hàm để biên dịch tức thì)
    @ViewBuilder
    private func headerBar(palette: ThemePalette) -> some View {
        if viewModel.screenMode == .reader {
            readerHeaderBar(palette: palette)
        } else if viewModel.screenMode == .folders && !viewModel.canNavigateBack {
            rootLibraryHeaderBar(palette: palette)
        } else {
            subFolderHeaderBar(palette: palette)
        }
    }

    private func readerHeaderBar(palette: ThemePalette) -> some View {
        let _ = viewModel.translatedRevisionTrigger
        let isTranslated = viewModel.selectedChapter.map {
            LocalChapterStorage.shared.isChapterTranslated($0.id)
        } ?? false
        let isSyncedToDrive = viewModel.selectedChapter.map {
            LocalChapterStorage.shared.isChapterSyncedToDrive($0.id)
        } ?? false

        return HStack(spacing: 5) {
            Button {
                Task { await viewModel.navigateBack() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(palette.accent.opacity(0.14))
                    .foregroundStyle(palette.accent)
                    .clipShape(Circle())
            }

            HStack(spacing: 4) {
                if isSyncedToDrive {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.blue)
                } else if isTranslated {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.green)
                }
                Text(viewModel.selectedChapter?.cleanChapterName ?? "Đang đọc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(max(viewModel.currentChapterIndex + 1, 1))/\(viewModel.chapters.count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.secondaryText)

            readerHeaderActionButtons(palette: palette)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(palette.headerBackground)
        .overlay(
            Rectangle()
                .fill(palette.border.opacity(0.7))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private func readerHeaderActionButtons(palette: ThemePalette) -> some View {
        let scrollIcon = viewModel.isAutoScrolling ? "arrow.down.circle.fill" : "arrow.down.circle"
        let scrollBg: Color = viewModel.isAutoScrolling ? palette.accent : palette.accent.opacity(0.14)
        let scrollFg: Color = viewModel.isAutoScrolling ? Color.white : palette.accent

        let speechIcon = speechManager.isSpeaking ? "speaker.wave.2.fill" : "headphones"
        let speechBg: Color = speechManager.isSpeaking ? palette.accent : palette.accent.opacity(0.14)
        let speechFg: Color = speechManager.isSpeaking ? Color.white : palette.accent

        let translateLabel = viewModel.isTranslatingBatch
            ? "\(viewModel.translationProgressCount)/\(viewModel.translationTotalCount)"
            : "Dịch"

        return HStack(spacing: 5) {
            Button {
                viewModel.toggleAutoScroll()
            } label: {
                Image(systemName: scrollIcon)
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(scrollBg)
                    .foregroundStyle(scrollFg)
                    .clipShape(Circle())
            }

            Button {
                viewModel.toggleSpeechPlayback()
            } label: {
                Image(systemName: speechIcon)
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(speechBg)
                    .foregroundStyle(speechFg)
                    .clipShape(Circle())
            }

            Button {
                viewModel.prepareAndOpenTranslationPopup()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                    Text(translateLabel)
                        .font(.system(size: 11, weight: .bold))
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.orange)
                .foregroundStyle(Color.white)
                .clipShape(Capsule())
            }

            Button {
                viewModel.openTableOfContents()
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(palette.accent.opacity(0.14))
                    .foregroundStyle(palette.accent)
                    .clipShape(Circle())
            }

            Button {
                viewModel.showSettingsSheet = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(palette.accent.opacity(0.14))
                    .foregroundStyle(palette.accent)
                    .clipShape(Circle())
            }
        }
    }

    private func rootLibraryHeaderBar(palette: ThemePalette) -> some View {
        let layoutIcon = viewModel.folderLayoutMode == .grid ? "list.bullet" : "square.grid.2x2.fill"

        return HStack(spacing: 10) {
            searchFieldBox(placeholder: "Tìm tên bộ truyện...", palette: palette)

            Button {
                viewModel.folderLayoutMode = (viewModel.folderLayoutMode == .grid) ? .list : .grid
            } label: {
                Image(systemName: layoutIcon)
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(palette.accent.opacity(0.15))
                    .foregroundStyle(palette.accent)
                    .clipShape(Circle())
            }

            Button {
                viewModel.showSettingsSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(palette.accent.opacity(0.15))
                    .foregroundStyle(palette.accent)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.headerBackground)
        .overlay(
            Rectangle()
                .fill(palette.border)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func subFolderHeaderBar(palette: ThemePalette) -> some View {
        let _ = viewModel.translatedRevisionTrigger
        let translatedCount = LocalChapterStorage.shared.translatedCount(in: viewModel.chapters)
        let syncedCount = LocalChapterStorage.shared.driveSyncedCount(in: viewModel.chapters)
        let translateBtnText = viewModel.isTranslatingBatch
            ? "\(viewModel.translationProgressCount)/\(viewModel.translationTotalCount)"
            : "Dịch AI"
        let placeholder = viewModel.screenMode == .folders
            ? "Tìm tên bộ truyện..."
            : "Tìm số chương hoặc tên chương..."

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                if viewModel.canNavigateBack {
                    Button {
                        Task { await viewModel.navigateBack() }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(palette.accent)
                            .foregroundStyle(Color.white)
                            .clipShape(Circle())
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.currentFolder.name)
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    if viewModel.screenMode == .chapters {
                        Text("\(viewModel.chapters.count) chương • Đã dịch: \(translatedCount) • Lên Drive: \(syncedCount)")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                }

                Spacer()

                if viewModel.screenMode == .chapters && !viewModel.chapters.isEmpty {
                    Button {
                        viewModel.prepareAndOpenTranslationPopup()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text(translateBtnText)
                        }
                        .font(.caption.weight(.bold))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(Color.orange)
                        .foregroundStyle(Color.white)
                        .clipShape(Capsule())
                    }
                }

                Button {
                    viewModel.showSettingsSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 38, height: 38)
                        .background(palette.accent.opacity(0.15))
                        .foregroundStyle(palette.accent)
                        .clipShape(Circle())
                }
            }

            searchFieldBox(placeholder: placeholder, palette: palette)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(palette.headerBackground)
        .overlay(
            Rectangle()
                .fill(palette.border)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func searchFieldBox(placeholder: String, palette: ThemePalette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.secondaryText)
            TextField(placeholder, text: $viewModel.searchQuery)
                .font(.subheadline)
                .foregroundStyle(palette.primaryText)

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.secondaryText)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(palette.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(palette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Folders View (Grid & List)
    @ViewBuilder
    private func foldersContentView(palette: ThemePalette) -> some View {
        let _ = viewModel.coverRevisionTrigger

        ScrollView {
            if viewModel.filteredFolders.isEmpty {
                emptyStateView(
                    icon: "books.vertical",
                    title: "Chưa có bộ truyện nào",
                    subtitle: "Hãy vuốt xuống để tải lại hoặc kiểm tra cài đặt Google Drive.",
                    palette: palette
                )
            } else if viewModel.folderLayoutMode == .grid {
                let columns = [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14)
                ]
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(viewModel.filteredFolders) { folder in
                        folderGridCard(folder: folder, palette: palette)
                    }
                }
                .padding(16)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.filteredFolders) { folder in
                        folderListRow(folder: folder, palette: palette)
                    }
                }
                .padding(16)
            }
        }
        .refreshable {
            await viewModel.refreshCurrentFolder()
        }
    }

    @ViewBuilder
    private func storyCoverThumbnail(folder: DriveItem, palette: ThemePalette) -> some View {
        if let localImage = LocalChapterStorage.shared.loadCachedCoverImage(for: folder.id) {
            Image(uiImage: localImage)
                .resizable()
                .scaledToFill()
        } else if let coverUrl = folder.coverUrl,
                  !coverUrl.hasPrefix("local://"),
                  let url = URL(string: coverUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    defaultCoverPlaceholder(palette: palette)
                }
            }
        } else {
            defaultCoverPlaceholder(palette: palette)
        }
    }

    private func folderGridCard(folder: DriveItem, palette: ThemePalette) -> some View {
        let saved = viewModel.readingStates[folder.id]

        return Button {
            Task { await viewModel.openFolder(folder) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    storyCoverThumbnail(folder: folder, palette: palette)
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipped()

                    if let savedChap = saved?.chapterName {
                        Text("Đang đọc: \(savedChap.replacingOccurrences(of: ".txt", with: ""))")
                            .font(.system(size: 10, weight: .bold))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(folder.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(palette.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(palette.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.04), radius: 5, x: 0, y: 2)
        }
    }

    private func folderListRow(folder: DriveItem, palette: ThemePalette) -> some View {
        let saved = viewModel.readingStates[folder.id]

        return Button {
            Task { await viewModel.openFolder(folder) }
        } label: {
            HStack(spacing: 14) {
                storyCoverThumbnail(folder: folder, palette: palette)
                    .frame(width: 68, height: 92)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    Text(folder.name)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let savedChap = saved?.chapterName {
                        Label("Đang đọc: \(savedChap.replacingOccurrences(of: ".txt", with: ""))", systemImage: "bookmark.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.accent)
                            .lineLimit(1)
                    } else {
                        Text("Nhấn để xem danh sách chương")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(12)
            .background(palette.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(palette.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func defaultCoverPlaceholder(palette: ThemePalette) -> some View {
        ZStack {
            LinearGradient(
                colors: [palette.accent.opacity(0.22), palette.border],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "book.closed.fill")
                .font(.system(size: 34))
                .foregroundStyle(palette.accent)
        }
    }

    // MARK: - Chapters List View
    private var activeChapterIdForCurrentList: String? {
        if let selId = viewModel.selectedChapter?.id,
           viewModel.chapters.contains(where: { $0.id == selId }) {
            return selId
        }
        return viewModel.currentStorySavedState?.chapterId
    }

    private func scrollChapterListToActive(_ proxy: ScrollViewProxy) {
        guard viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let targetId = activeChapterIdForCurrentList else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            proxy.scrollTo(targetId, anchor: .center)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            proxy.scrollTo(targetId, anchor: .center)
        }
    }

    @ViewBuilder
    private func chaptersContentView(palette: ThemePalette) -> some View {
        let _ = viewModel.translatedRevisionTrigger
        let savedChapterId = activeChapterIdForCurrentList

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(Array(viewModel.filteredChapters.enumerated()), id: \.element.id) { idx, chapter in
                        chapterRowItem(idx: idx, chapter: chapter, savedChapterId: savedChapterId, palette: palette)
                    }
                }
                .padding(14)
            }
            .refreshable {
                await viewModel.refreshCurrentFolder()
            }
            .onAppear {
                scrollChapterListToActive(proxy)
            }
            .onChange(of: viewModel.chapters.count) { _ in
                scrollChapterListToActive(proxy)
            }
        }
    }

    private func chapterRowItem(idx: Int, chapter: DriveItem, savedChapterId: String?, palette: ThemePalette) -> some View {
        let isActive = (viewModel.selectedChapter?.id == chapter.id) || (savedChapterId == chapter.id)
        let isTranslated = LocalChapterStorage.shared.isChapterTranslated(chapter.id)
        let isSyncedToDrive = LocalChapterStorage.shared.isChapterSyncedToDrive(chapter.id)
        let isCachedOffline = LocalChapterStorage.shared.hasLocalFile(for: chapter.id)

        let badgeBg: Color = isActive ? palette.accent : palette.border.opacity(0.45)
        let badgeFg: Color = isActive ? Color.white : palette.secondaryText
        let titleFg: Color = isActive ? palette.accent : palette.primaryText
        let cardBg: Color = isActive ? palette.accent.opacity(0.10) : palette.cardBackground
        let borderFg: Color = isActive ? palette.accent : palette.border

        return Button {
            Task { await viewModel.openChapter(chapter) }
        } label: {
            HStack(spacing: 12) {
                Text("\(idx + 1)")
                    .font(.caption.weight(.bold))
                    .frame(width: 34, height: 34)
                    .background(badgeBg)
                    .foregroundStyle(badgeFg)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.cleanChapterName)
                        .font(.subheadline.weight(isActive ? .bold : .medium))
                        .foregroundStyle(titleFg)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    if isActive {
                        Text("Đang đọc dở (Đã lưu trong máy)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.accent)
                    } else if isCachedOffline {
                        Text("Đã lưu sẵn trong máy")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.secondaryText)
                    }
                }

                Spacer()

                if isSyncedToDrive {
                    HStack(spacing: 4) {
                        Image(systemName: "icloud.fill")
                        Text("Đã lên Drive")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.16))
                    .foregroundStyle(Color.blue)
                    .clipShape(Capsule())
                } else if isTranslated {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("Đã dịch")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.16))
                    .foregroundStyle(Color.green)
                    .clipShape(Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(cardBg)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(borderFg, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .id(chapter.id)
    }

    // MARK: - Reader View
    @ViewBuilder
    private func readerContentView(palette: ThemePalette) -> some View {
        let _ = viewModel.translatedRevisionTrigger
        let cleanedStoryText = formatCleanStoryBody(viewModel.chapterContent)

        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        AutoScrollBridge(
                            isScrolling: viewModel.isAutoScrolling,
                            speedPointsPerSecond: viewModel.autoScrollSpeed,
                            onUserDragPause: {
                                viewModel.isAutoScrolling = false
                            },
                            onReachedBottom: {
                                viewModel.isAutoScrolling = false
                                if viewModel.autoNextChapterOnScrollEnd &&
                                    viewModel.currentChapterIndex < viewModel.chapters.count - 1 {
                                    Task {
                                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                                        await viewModel.openNextChapter()
                                        viewModel.isAutoScrolling = true
                                    }
                                }
                            },
                            onScrollProgressChanged: { ratio, isUserDragging in
                                viewModel.handleReaderScrollChanged(ratio: ratio, isUserInteracting: isUserDragging)
                            },
                            onRegisterScrollRatioProvider: { provider in
                                viewModel.liveScrollRatioProvider = provider
                            }
                        )
                        .frame(width: 0, height: 0)

                        Color.clear
                            .frame(height: 1)
                            .id("READER_TOP_ANCHOR")

                        Text(viewModel.selectedChapter?.cleanChapterName ?? "")
                            .font(.system(size: 17, weight: .bold, design: .serif))
                            .foregroundStyle(palette.secondaryText)
                            .padding(.bottom, 2)

                        if viewModel.isChapterLoading {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .tint(palette.accent)
                                Text("Đang tải nội dung chương...")
                                    .font(.subheadline)
                                    .foregroundStyle(palette.secondaryText)
                            }
                            .padding(.vertical, 20)
                        }

                        Text(cleanedStoryText)
                            .font(.system(size: viewModel.storyFontSize, weight: .regular, design: .serif))
                            .lineSpacing(viewModel.storyFontSize * 0.56)
                            .foregroundStyle(palette.primaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()
                            .padding(.top, 12)

                        readerBottomNavigationRow(palette: palette)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .id("READER_SCROLL_\(viewModel.selectedChapter?.id ?? "none")_\(viewModel.readerScrollResetToken)")
                .onAppear {
                    scrollProxy.scrollTo("READER_TOP_ANCHOR", anchor: .top)
                }
                .onChange(of: viewModel.selectedChapter?.id) { _ in
                    scrollProxy.scrollTo("READER_TOP_ANCHOR", anchor: .top)
                }
                .onChange(of: viewModel.readerScrollResetToken) { _ in
                    scrollProxy.scrollTo("READER_TOP_ANCHOR", anchor: .top)
                }
            }
        }
    }

    private func readerBottomNavigationRow(palette: ThemePalette) -> some View {
        let hasPrev = viewModel.currentChapterIndex > 0
        let hasNext = viewModel.currentChapterIndex < viewModel.chapters.count - 1
        let prevFg: Color = hasPrev ? palette.primaryText : palette.secondaryText.opacity(0.4)
        let nextBg: Color = hasNext ? palette.accent : palette.border

        return HStack(spacing: 10) {
            Button {
                Task { await viewModel.openPreviousChapter() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left")
                    Text("Chương trước")
                }
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(palette.cardBackground)
                .foregroundStyle(prevFg)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(palette.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!hasPrev)

            Button {
                viewModel.openTableOfContents()
            } label: {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(palette.cardBackground)
                    .foregroundStyle(palette.accent)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(palette.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Button {
                Task { await viewModel.openNextChapter() }
            } label: {
                HStack(spacing: 5) {
                    Text("Chương sau")
                    Image(systemName: "arrow.right")
                }
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(nextBg)
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!hasNext)
        }
        .padding(.top, 6)
        .padding(.bottom, viewModel.showSpeechControls ? 86 : 26)
    }

    private func formatCleanStoryBody(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines)
        let cleaned = lines.map { line -> String in
            var s = line
            if let range = s.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                s.removeSubrange(range)
            }
            return s.replacingOccurrences(of: "**", with: "")
        }
        return cleaned.joined(separator: "\n")
    }

    // MARK: - Supporting Views
    private var errorBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
            Text(viewModel.errorMessage)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.red)
                .multilineTextAlignment(.leading)
            Spacer()
            Button {
                viewModel.errorMessage = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.red.opacity(0.7))
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func loadingStateView(palette: ThemePalette) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .scaleEffect(1.3)
                .tint(palette.accent)
            Text("Đang tải dữ liệu truyện...")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(palette.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func emptyStateView(icon: String, title: String, subtitle: String, palette: ThemePalette) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 46))
                .foregroundStyle(palette.accent.opacity(0.7))
                .padding(.top, 60)
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(palette.primaryText)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
    }

    private var toastCapsule: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
            Text(viewModel.toastMessage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.84))
        .clipShape(Capsule())
        .shadow(radius: 8)
    }
}
