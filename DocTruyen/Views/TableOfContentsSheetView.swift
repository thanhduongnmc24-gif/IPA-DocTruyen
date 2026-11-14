import SwiftUI

struct TableOfContentsSheetView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let palette = ThemePalette.forTheme(viewModel.readerTheme)

        NavigationStack {
            VStack(spacing: 0) {
                // Font & Theme Quick Bar
                VStack(spacing: 12) {
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

                    HStack(spacing: 8) {
                        ForEach(ReaderTheme.allCases) { theme in
                            let itemPalette = ThemePalette.forTheme(theme)
                            Button {
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
                                .background(
                                    viewModel.readerTheme == theme
                                        ? palette.accent.opacity(0.18)
                                        : Color.clear
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(
                                            viewModel.readerTheme == theme ? palette.accent : palette.border,
                                            lineWidth: 1
                                        )
                                )
                                .clipShape(Capsule())
                            }
                            .foregroundStyle(palette.primaryText)
                        }
                    }
                }
                .padding(14)
                .background(palette.headerBackground)

                Divider()

                // Pagination Bar
                HStack {
                    Button {
                        viewModel.prevTocPage()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.bold))
                            .frame(width: 36, height: 36)
                            .background(palette.accent.opacity(viewModel.tocStartIndex <= 0 ? 0.3 : 1))
                            .foregroundStyle(.white)
                            .clipShape(Circle())
                    }
                    .disabled(viewModel.tocStartIndex <= 0)

                    Spacer()

                    let startNum = viewModel.chapters.isEmpty ? 0 : (viewModel.tocStartIndex + 1)
                    let endNum = min(viewModel.tocStartIndex + viewModel.tocWindowSize, viewModel.chapters.count)
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
                            .background(
                                palette.accent.opacity(
                                    viewModel.tocStartIndex + viewModel.tocWindowSize >= viewModel.chapters.count ? 0.3 : 1
                                )
                            )
                            .foregroundStyle(.white)
                            .clipShape(Circle())
                    }
                    .disabled(viewModel.tocStartIndex + viewModel.tocWindowSize >= viewModel.chapters.count)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(palette.background)

                // Chapter Slice List
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(viewModel.currentTocSlice.enumerated()), id: \.element.id) { offset, chapter in
                            let globalIndex = viewModel.tocStartIndex + offset
                            let isCurrent = viewModel.selectedChapter?.id == chapter.id
                            let isTranslated = LocalChapterStorage.shared.isChapterTranslated(chapter.id)

                            Button {
                                dismiss()
                                Task {
                                    await viewModel.openChapter(chapter)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Text("\(globalIndex + 1)")
                                        .font(.caption.weight(.bold))
                                        .frame(width: 34, height: 34)
                                        .background(isCurrent ? palette.accent : palette.border.opacity(0.5))
                                        .foregroundStyle(isCurrent ? .white : palette.primaryText)
                                        .clipShape(Circle())

                                    Text(chapter.cleanChapterName)
                                        .font(.subheadline.weight(isCurrent ? .bold : .medium))
                                        .foregroundStyle(isCurrent ? palette.accent : palette.primaryText)
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
                                .background(isCurrent ? palette.accent.opacity(0.12) : palette.cardBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(isCurrent ? palette.accent : palette.border, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    .padding(14)
                }
                .background(palette.background)
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
}
