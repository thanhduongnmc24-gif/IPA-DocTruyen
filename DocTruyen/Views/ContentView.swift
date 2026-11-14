import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        let palette = ThemePalette.forTheme(viewModel.readerTheme)

        ZStack(alignment: .bottom) {
            palette.background
                .ignoresSafeArea(.all)

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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if !viewModel.toastMessage.isEmpty {
                toastCapsule
                    .padding(.bottom, viewModel.screenMode == .reader ? 76 : 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: viewModel.toastMessage)
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

    // MARK: - Top Navigation Header
    @ViewBuilder
    private func headerBar(palette: ThemePalette) -> some View {
        if viewModel.screenMode == .reader {
            HStack(spacing: 8) {
                Button {
                    Task { await viewModel.navigateBack() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(palette.accent.opacity(0.15))
                        .foregroundStyle(palette.accent)
                        .clipShape(Circle())
                }
                .fixedSize()

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(viewModel.selectedChapter?.cleanChapterName ?? "Đang đọc")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if let chap = viewModel.selectedChapter,
                           LocalChapterStorage.shared.isChapterTranslated(chap.id) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }

                    Text("Chương \(max(viewModel.currentChapterIndex + 1, 1))/\(viewModel.chapters.count) • \(viewModel.selectedGeminiModel.shortBadge)")
                        .font(.caption2)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Nút Dịch Truyện cố định trên 1 dòng, không bị ép gãy chữ dọc
                Button {
                    viewModel.prepareAndOpenTranslationPopup()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.caption2.weight(.bold))
                        Text("Dịch AI")
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        LinearGradient(
                            colors: [Color.orange, Color(red: 0.85, green: 0.35, blue: 0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .shadow(color: Color.orange.opacity(0.28), radius: 3, x: 0, y: 2)
                }
                .fixedSize(horizontal: true, vertical: false)

                Button {
                    viewModel.openTableOfContents()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(palette.accent.opacity(0.15))
                        .foregroundStyle(palette.accent)
                        .clipShape(Circle())
                }
                .fixedSize()

                Button {
                    viewModel.showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(palette.accent.opacity(0.15))
                        .foregroundStyle(palette.accent)
                        .clipShape(Circle())
                }
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(palette.headerBackground)
            .overlay(
                Rectangle()
                    .fill(palette.border)
                    .frame(height: 1),
                alignment: .bottom
            )
        } else {
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
                        .fixedSize()
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.currentFolder.name)
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)

                        if viewModel.screenMode == .chapters {
                            let translatedCount = LocalChapterStorage.shared.translatedCount(in: viewModel.chapters)
                            Text("\(viewModel.chapters.count) chương • Đã dịch AI: \(translatedCount) chương")
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                                .lineLimit(1)
                        } else {
                            Text("Kho truyện Google Drive • AI Gemini Editor")
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if viewModel.screenMode == .chapters && !viewModel.chapters.isEmpty {
                        Button {
                            viewModel.prepareAndOpenTranslationPopup()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                Text("Dịch AI")
                                    .lineLimit(1)
                            }
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(Color.orange)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                        }
                        .fixedSize(horizontal: true, vertical: false)
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
                        .fixedSize()
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
                    .fixedSize()
                }

                // Search Bar
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
        ScrollView {
            if viewModel.filteredFolders.isEmpty {
                emptyStateView(
                    icon: "books.vertical",
                    title: "Chưa có bộ truyện nào",
                    subtitle: "Thư mục này chưa có thư mục con hoặc file .txt.",
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

    private func folderGridCard(folder: DriveItem, palette: ThemePalette) -> some View {
        let saved = viewModel.readingStates[folder.id]

        return Button {
            Task { await viewModel.openFolder(folder) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    if let coverUrl = folder.coverUrl, let url = URL(string: coverUrl) {
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
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    } else {
                        defaultCoverPlaceholder(palette: palette)
                            .frame(height: 200)
                    }

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
                if let coverUrl = folder.coverUrl, let url = URL(string: coverUrl) {
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
                    .frame(width: 68, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    defaultCoverPlaceholder(palette: palette)
                        .frame(width: 68, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

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
                                        Text("Đang đọc dở")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(palette.accent)
                                    }
                                }

                                Spacer()

                                if isTranslated {
                                    HStack(spacing: 4) {
                                        Image(systemName: "sparkles")
                                        Text("Đã dịch")
                                            .lineLimit(1)
                                    }
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(Color.green.opacity(0.16))
                                    .foregroundStyle(Color.green)
                                    .clipShape(Capsule())
                                    .fixedSize(horizontal: true, vertical: false)
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
        let isCurrentTranslated = viewModel.selectedChapter.map {
            LocalChapterStorage.shared.isChapterTranslated($0.id)
        } ?? false

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Chapter Title Banner inside Reader
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            if isCurrentTranslated {
                                Label("Đã biên tập mượt bởi Gemini AI", systemImage: "sparkles")
                                    .font(.caption.weight(.bold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.green.opacity(0.16))
                                    .foregroundStyle(Color.green)
                                    .clipShape(Capsule())
                            } else {
                                Label("Bản gốc (Chưa dịch AI)", systemImage: "doc.text")
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(palette.border.opacity(0.5))
                                    .foregroundStyle(palette.secondaryText)
                                    .clipShape(Capsule())
                            }

                            Spacer(minLength: 4)

                            Button {
                                viewModel.prepareAndOpenTranslationPopup()
                            } label: {
                                Label("Dịch nhiều chương", systemImage: "wand.and.stars")
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.orange.opacity(0.14))
                                    .foregroundStyle(Color.orange)
                                    .clipShape(Capsule())
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }

                        Text(viewModel.selectedChapter?.cleanChapterName ?? "")
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(palette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 6)

                    Divider()

                    // Story Body Text
                    Text(viewModel.chapterContent)
                        .font(.system(size: viewModel.storyFontSize, weight: .regular, design: .serif))
                        .lineSpacing(viewModel.storyFontSize * 0.58)
                        .foregroundStyle(palette.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()
                        .padding(.top, 16)

                    // Bottom Chapter Navigation Bar
                    HStack(spacing: 12) {
                        Button {
                            Task { await viewModel.openPreviousChapter() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.left")
                                Text("Chương trước")
                                    .lineLimit(1)
                            }
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
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
                                .font(.title3.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 13)
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
                            HStack(spacing: 6) {
                                Text("Chương sau")
                                    .lineLimit(1)
                                Image(systemName: "arrow.right")
                            }
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
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
                    .padding(.top, 8)
                    .padding(.bottom, 30)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
            }
        }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
