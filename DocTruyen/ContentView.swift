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
                    switch viewModel.screenMode {
                    case .folders:
                        foldersContentView(palette: palette)
                    case .chapters:
                        chaptersContentView(palette: palette)
                    case .reader:
                        readerContentView(palette: palette)
                    }
                }
            }

            if viewModel.screenMode == .reader && viewModel.showSpeechControls {
                readerFloatingUtilityBar(palette: palette)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !viewModel.toastMessage.isEmpty {
                toastCapsule
                    .padding(.bottom, (viewModel.screenMode == .reader && viewModel.showSpeechControls) ? 88 : 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.toastMessage)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showAutoScrollControls)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showSpeechControls)
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

    // MARK: - Thanh điều khiển nổi Nghe truyện AI (Đã ẩn hoàn toàn thanh cuộn khi tự động cuộn)
    @ViewBuilder
    private func readerFloatingUtilityBar(palette: ThemePalette) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
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
                    Group {
                        if speechManager.isBuffering {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: (speechManager.isSpeaking && !speechManager.isPaused) ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .bold))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(palette.accent)
                    .foregroundStyle(.white)
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

                Menu {
                    ForEach(StoryVoiceChoice.allCases) { voice in
                        Button {
                            speechManager.selectedVoiceChoice = voice
                        } label: {
                            if speechManager.selectedVoiceChoice == voice {
                                Label(voice.displayName, systemImage: "checkmark")
                            } else {
                                Text(voice.displayName)
                            }
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
                        Text("Đoạn \(min(speechManager.currentChunkIndex + 1, max(speechManager.totalChunks, 1)))/\(max(speechManager.totalChunks, 1))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.secondaryText)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
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

                    Text(String(format: "%.1fx", speechManager.playbackSpeedMultiplier))
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

    // MARK: - Top Navigation Header
    @ViewBuilder
    private func headerBar(palette: ThemePalette) -> some View {
        if viewModel.screenMode == .reader {
            let _ = viewModel.translatedRevisionTrigger
            let isTranslated = viewModel.selectedChapter.map {
                LocalChapterStorage.shared.isChapterTranslated($0.id)
            } ?? false
            let isSyncedToDrive = viewModel.selectedChapter.map {
                LocalChapterStorage.shared.isChapterSyncedToDrive($0.id)
            } ?? false

            HStack(spacing: 5) {
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
                            .foregroundStyle(.blue)
                    } else if isTranslated {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
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

                // Nút Tự động cuộn
                Button {
                    viewModel.toggleAutoScroll()
                } label: {
                    Image(systemName: viewModel.isAutoScrolling ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(viewModel.isAutoScrolling ? palette.accent : palette.accent.opacity(0.14))
                        .foregroundStyle(viewModel.isAutoScrolling ? .white : palette.accent)
                        .clipShape(Circle())
                }

                // Nút Nghe truyện
                Button {
                    viewModel.toggleSpeechPlayback()
                } label: {
                    Image(systemName: speechManager.isSpeaking ? "speaker.wave.2.fill" : "headphones")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(speechManager.isSpeaking ? palette.accent : palette.accent.opacity(0.14))
                        .foregroundStyle(speechManager.isSpeaking ? .white : palette.accent)
                        .clipShape(Circle())
                }

                Button {
                    viewModel.prepareAndOpenTranslationPopup()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .bold))
                        Text(viewModel.isTranslatingBatch
                             ? "\(viewModel.translationProgressCount)/\(viewModel.translationTotalCount)"
                             : "Dịch")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        LinearGradient(
                            colors: [Color.orange, Color(red: 0.85, green: 0.35, blue: 0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .foregroundStyle(.white)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(palette.headerBackground)
            .overlay(
                Rectangle()
                    .fill(palette.border.opacity(0.7))
                    .frame(height: 0.5),
                alignment: .bottom
            )
        } else if viewModel.screenMode == .folders && !viewModel.canNavigateBack {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(palette.secondaryText)
                    TextField("Tìm tên bộ truyện...", text: $viewModel.searchQuery)
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

                Button {
                    viewModel.folderLayoutMode = (viewModel.folderLayoutMode == .grid) ? .list : .grid
                } label: {
                    Image(systemName: viewModel.folderLayoutMode == .grid ? "list.bullet" : "square.grid.2x2.fill")
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
        } else {
            let _ = viewModel.translatedRevisionTrigger
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    if viewModel.canNavigateBack {
                        Button {
                            Task { await viewModel.navigateBack() }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: 38, height: 38)
                                .background(palette.accent)
                                .foregroundStyle(.white)
                                .clipShape(Circle())
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.currentFolder.name)
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)

                        if viewModel.screenMode == .chapters {
                            let translatedCount = LocalChapterStorage.shared.translatedCount(in: viewModel.chapters)
                            let syncedCount = LocalChapterStorage.shared.driveSyncedCount(in: viewModel.chapters)
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
                                Text(viewModel.isTranslatingBatch
                                     ? "\(viewModel.translationProgressCount)/\(viewModel.translationTotalCount)"
                                     : "Dịch AI")
                            }
                            .font(.caption.weight(.bold))
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(Color.orange)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                        }
                    }

                    if viewModel.screenMode == .folders {
                        Button {
                            viewModel.folderLayoutMode = (viewModel.folderLayoutMode == .grid) ? .list : .grid
                        } label: {
                            Image(systemName: viewModel.folderLayoutMode == .grid ? "list.bullet" : "square.grid.2x2.fill")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 38, height: 38)
                                .background(palette.accent.opacity(0.15))
                                .foregroundStyle(palette.accent)
                                .clipShape(Circle())
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

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(palette.secondaryText)
                    TextField(
                        viewModel.screenMode == .folders ? "Tìm tên bộ truyện..." : "Tìm số chương hoặc tên chương...",
                        text: $viewModel.searchQuery
                    )
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
    @ViewBuilder
    private func chaptersContentView(palette: ThemePalette) -> some View {
        let _ = viewModel.translatedRevisionTrigger
        let savedChapterId = viewModel.currentStorySavedState?.chapterId

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(Array(viewModel.filteredChapters.enumerated()), id: \.element.id) { idx, chapter in
                        let isActive = (viewModel.selectedChapter?.id == chapter.id) || (savedChapterId == chapter.id)
                        let isTranslated = LocalChapterStorage.shared.isChapterTranslated(chapter.id)
                        let isSyncedToDrive = LocalChapterStorage.shared.isChapterSyncedToDrive(chapter.id)
                        let isCachedOffline = LocalChapterStorage.shared.hasLocalFile(for: chapter.id)

                        Button {
                            Task { await viewModel.openChapter(chapter) }
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(idx + 1)")
                                    .font(.caption.weight(.bold))
                                    .frame(width: 34, height: 34)
                                    .background(isActive ? palette.accent : palette.border.opacity(0.45))
                                    .foregroundStyle(isActive ? .white : palette.secondaryText)
                                    .clipShape(Circle())

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chapter.cleanChapterName)
                                        .font(.subheadline.weight(isActive ? .bold : .medium))
                                        .foregroundStyle(isActive ? palette.accent : palette.primaryText)
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
                            .background(isActive ? palette.accent.opacity(0.10) : palette.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(isActive ? palette.accent : palette.border, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .id(chapter.id)
                    }
                }
                .padding(14)
            }
            .refreshable {
                await viewModel.refreshCurrentFolder()
            }
            .onAppear {
                if let targetId = viewModel.selectedChapter?.id ?? savedChapterId {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation {
                            proxy.scrollTo(targetId, anchor: .center)
                        }
                    }
                }
            }
        }
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
                                        if viewModel.showAutoScrollControls {
                                            viewModel.isAutoScrolling = true
                                        }
                                    }
                                }
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

                        HStack(spacing: 10) {
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
                                .foregroundStyle(viewModel.currentChapterIndex > 0 ? palette.primaryText : palette.secondaryText.opacity(0.4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(palette.border, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .disabled(viewModel.currentChapterIndex <= 0)

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
                                .background(
                                    viewModel.currentChapterIndex < viewModel.chapters.count - 1
                                        ? palette.accent
                                        : palette.border
                                )
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .disabled(viewModel.currentChapterIndex >= viewModel.chapters.count - 1)
                        }
                        .padding(.top, 6)
                        .padding(.bottom, viewModel.showSpeechControls ? 86 : 26)
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
                .foregroundStyle(.red)
            Text(viewModel.errorMessage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
                .multilineTextAlignment(.leading)
            Spacer()
            Button {
                viewModel.errorMessage = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red.opacity(0.7))
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
                .foregroundStyle(.green)
            Text(viewModel.toastMessage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.84))
        .clipShape(Capsule())
        .shadow(radius: 8)
    }
}
