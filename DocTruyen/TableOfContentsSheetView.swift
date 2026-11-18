import SwiftUI

struct TableOfContentsSheetView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private var activeChapterIdInCurrentStory: String? {
        if let selId = viewModel.selectedChapter?.id,
           viewModel.chapters.contains(where: { $0.id == selId }) {
            return selId
        }
        return viewModel.currentStorySavedState?.chapterId
    }

    var body: some View {
        let palette = ThemePalette.forTheme(viewModel.readerTheme)
        let _ = viewModel.translatedRevisionTrigger
        let activeChapterId = activeChapterIdInCurrentStory

        NavigationStack {
            VStack(spacing: 0) {
                quickSettingsHeader(palette: palette)
                Divider()
                paginationBar(palette: palette)
                chapterListScrollSection(palette: palette, activeChapterId: activeChapterId)
            }
            .navigationTitle("Mục lục chương")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") {
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }

    @ViewBuilder
    private func quickSettingsHeader(palette: ThemePalette) -> some View {
        VStack(spacing: 12) {
            fontSizeRow(palette: palette)
            themePickerRow(palette: palette)
            autoScrollSettingsSection(palette: palette)
        }
        .padding(14)
        .background(palette.headerBackground)
    }

    @ViewBuilder
    private func fontSizeRow(palette: ThemePalette) -> some View {
        HStack {
            Label("Cỡ chữ: \(Int(viewModel.storyFontSize)) pt", systemImage: "textformat.size")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.primaryText)

            Spacer()

            HStack(spacing: 10) {
                Button {
                    viewModel.storyFontSize = max(14, viewModel.storyFontSize - 1)
                } label: {
                    Text("A-")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(palette.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }

                Button {
                    viewModel.storyFontSize = min(32, viewModel.storyFontSize + 1)
                } label: {
                    Text("A+")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(palette.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private func themePickerRow(palette: ThemePalette) -> some View {
        HStack(spacing: 8) {
            ForEach(ReaderTheme.allCases) { theme in
                themeChipButton(theme: theme, palette: palette)
            }
        }
    }

    private func themeChipButton(theme: ReaderTheme, palette: ThemePalette) -> some View {
        let itemPalette = ThemePalette.forTheme(theme)
        let isSelected = (viewModel.readerTheme == theme)
        let chipBg: Color = isSelected ? palette.accent.opacity(0.18) : Color.clear
        let chipBorder: Color = isSelected ? palette.accent : palette.border

        return Button {
            viewModel.readerTheme = theme
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(itemPalette.background)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 1))
                Text(theme.title)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(chipBg)
            .overlay(
                Capsule()
                    .stroke(chipBorder, lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .foregroundStyle(palette.primaryText)
    }

    @ViewBuilder
    private func autoScrollSettingsSection(palette: ThemePalette) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Label("Tốc độ cuộn: \(Int(viewModel.autoScrollSpeed))", systemImage: "arrow.down.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.primaryText)

                Slider(value: $viewModel.autoScrollSpeed, in: 15...160, step: 5)
                    .tint(palette.accent)
            }

            Toggle(isOn: $viewModel.autoNextChapterOnScrollEnd) {
                Text("Cuộn hết trang tự qua chương mới")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            .tint(palette.accent)
        }
    }

    @ViewBuilder
    private func paginationBar(palette: ThemePalette) -> some View {
        let canGoPrev = viewModel.tocStartIndex > 0
        let canGoNext = (viewModel.tocStartIndex + viewModel.tocWindowSize) < viewModel.chapters.count
        let startNum = viewModel.chapters.isEmpty ? 0 : (viewModel.tocStartIndex + 1)
        let endNum = min(viewModel.tocStartIndex + viewModel.tocWindowSize, viewModel.chapters.count)

        HStack {
            Button {
                viewModel.prevTocPage()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 36, height: 36)
                    .background(palette.accent.opacity(canGoPrev ? 1.0 : 0.3))
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
            .disabled(!canGoPrev)

            Spacer()

            Text("Chương \(startNum) – \(endNum) / \(viewModel.chapters.count)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(palette.primaryText)

            Spacer()

            Button {
                viewModel.nextTocPage()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 36, height: 36)
                    .background(palette.accent.opacity(canGoNext ? 1.0 : 0.3))
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
            .disabled(!canGoNext)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.background)
    }

    @ViewBuilder
    private func chapterListScrollSection(palette: ThemePalette, activeChapterId: String?) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    Color.clear
                        .frame(height: 1)
                        .id("TOC_TOP_ANCHOR")

                    ForEach(Array(viewModel.currentTocSlice.enumerated()), id: \.element.id) { offset, chapter in
                        let globalIndex = viewModel.tocStartIndex + offset
                        let isCurrent = (activeChapterId == chapter.id)
                        let isTranslated = LocalChapterStorage.shared.isChapterTranslated(chapter.id)
                        tocChapterRowButton(
                            chapter: chapter,
                            globalIndex: globalIndex,
                            isCurrent: isCurrent,
                            isTranslated: isTranslated,
                            palette: palette
                        )
                    }
                }
                .padding(14)
            }
            .id("TOC_SCROLL_\(viewModel.tocStartIndex)_\(viewModel.tocScrollResetToken)")
            .onAppear {
                scrollToActiveOrTop(proxy: scrollProxy, activeId: activeChapterId)
            }
            .onChange(of: viewModel.tocStartIndex) { _ in
                scrollToActiveOrTop(proxy: scrollProxy, activeId: activeChapterId)
            }
            .onChange(of: viewModel.tocScrollResetToken) { _ in
                scrollToActiveOrTop(proxy: scrollProxy, activeId: activeChapterId)
            }
        }
        .background(palette.background)
    }

    private func tocChapterRowButton(
        chapter: DriveItem,
        globalIndex: Int,
        isCurrent: Bool,
        isTranslated: Bool,
        palette: ThemePalette
    ) -> some View {
        let badgeBg: Color = isCurrent ? palette.accent : palette.border.opacity(0.5)
        let badgeFg: Color = isCurrent ? Color.white : palette.primaryText
        let titleFg: Color = isCurrent ? palette.accent : palette.primaryText
        let cardBg: Color = isCurrent ? palette.accent.opacity(0.12) : palette.cardBackground
        let borderFg: Color = isCurrent ? palette.accent : palette.border

        return Button {
            dismiss()
            Task {
                await viewModel.openChapter(chapter)
            }
        } label: {
            HStack(spacing: 12) {
                Text("\(globalIndex + 1)")
                    .font(.caption.weight(.bold))
                    .frame(width: 34, height: 34)
                    .background(badgeBg)
                    .foregroundStyle(badgeFg)
                    .clipShape(Circle())

                Text(chapter.cleanChapterName)
                    .font(.subheadline.weight(isCurrent ? .bold : .medium))
                    .foregroundStyle(titleFg)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Spacer()

                if isTranslated {
                    Text("Đã dịch AI")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.18))
                        .foregroundStyle(Color.green)
                        .clipShape(Capsule())
                }
            }
            .padding(12)
            .background(cardBg)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderFg, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .id(chapter.id)
    }

    private func scrollToActiveOrTop(proxy: ScrollViewProxy, activeId: String?) {
        if let activeId, viewModel.currentTocSlice.contains(where: { $0.id == activeId }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                proxy.scrollTo(activeId, anchor: .center)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                proxy.scrollTo(activeId, anchor: .center)
            }
        } else {
            proxy.scrollTo("TOC_TOP_ANCHOR", anchor: .top)
        }
    }
}
