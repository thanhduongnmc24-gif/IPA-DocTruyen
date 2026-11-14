import SwiftUI

struct TranslationRangeSheetView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPromptEditor: Bool = false
    @State private var activeChapterPickerTarget: ChapterPickerTarget?

    enum ChapterPickerTarget: String, Identifiable {
        case fromChapter = "from"
        case toChapter = "to"
        var id: String { rawValue }
    }

    var body: some View {
        let _ = viewModel.translatedRevisionTrigger
        let startIdx = max(0, min(viewModel.translateFromChapterIndex, viewModel.translateToChapterIndex))
        let endIdx = min(max(viewModel.chapters.count - 1, 0), max(viewModel.translateFromChapterIndex, viewModel.translateToChapterIndex))
        let selectedChaptersSlice = viewModel.chapters.isEmpty ? [] : Array(viewModel.chapters[startIdx...endIdx])
        let alreadyTranslatedCount = selectedChaptersSlice.filter {
            LocalChapterStorage.shared.isChapterTranslated($0.id)
        }.count
        let untranslatedCount = max(0, selectedChaptersSlice.count - alreadyTranslatedCount)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header Card gọn gàng
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [Color.orange, Color.red.opacity(0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 42, height: 42)
                            Image(systemName: "sparkles")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Dịch & Biên tập lại truyện")
                                .font(.subheadline.weight(.bold))
                            Text("Chương đã dịch có dấu ✅ Đã dịch rõ ràng để bạn dễ chọn.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // Range Picker Section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Chọn phạm vi chương cần dịch")
                            .font(.subheadline.weight(.bold))

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                quickRangeButton("Chỉ chương này") {
                                    let idx = max(0, viewModel.currentChapterIndex)
                                    viewModel.translateFromChapterIndex = idx
                                    viewModel.translateToChapterIndex = idx
                                }

                                quickRangeButton("5 chương tiếp") {
                                    let idx = max(0, viewModel.currentChapterIndex)
                                    viewModel.translateFromChapterIndex = idx
                                    viewModel.translateToChapterIndex = min(viewModel.chapters.count - 1, idx + 4)
                                }

                                quickRangeButton("10 chương tiếp") {
                                    let idx = max(0, viewModel.currentChapterIndex)
                                    viewModel.translateFromChapterIndex = idx
                                    viewModel.translateToChapterIndex = min(viewModel.chapters.count - 1, idx + 9)
                                }

                                quickRangeButton("Tìm 5 chương chưa dịch") {
                                    selectNextUntranslatedRange(count: 5)
                                }
                            }
                        }

                        if !viewModel.chapters.isEmpty {
                            VStack(spacing: 0) {
                                chapterSelectorRow(
                                    label: "Từ chương",
                                    selectedIndex: viewModel.translateFromChapterIndex
                                ) {
                                    activeChapterPickerTarget = .fromChapter
                                }

                                Divider()
                                    .padding(.leading, 12)

                                chapterSelectorRow(
                                    label: "Đến chương",
                                    selectedIndex: viewModel.translateToChapterIndex
                                ) {
                                    activeChapterPickerTarget = .toChapter
                                }
                            }
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        // Thống kê rõ ràng bao nhiêu chương đã dịch / chưa dịch trong khoảng đang chọn
                        HStack(spacing: 10) {
                            Label("Tổng: \(selectedChaptersSlice.count) chương", systemImage: "books.vertical.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)

                            Spacer()

                            Text("✅ Đã dịch: \(alreadyTranslatedCount)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.16))
                                .foregroundStyle(Color.green)
                                .clipShape(Capsule())

                            Text("⏳ Chưa dịch: \(untranslatedCount)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.16))
                                .foregroundStyle(Color.orange)
                                .clipShape(Capsule())
                        }
                        .padding(.top, 2)
                    }

                    // Model & API Key Quick Config
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Model AI & Khóa kết nối")
                            .font(.subheadline.weight(.bold))

                        Picker("Chọn Model", selection: $viewModel.selectedGeminiModel) {
                            ForEach(GeminiModelChoice.allCases) { model in
                                Text(model.shortBadge).tag(model)
                            }
                        }
                        .pickerStyle(.segmented)

                        Toggle("Tự chuyển sang 3.1 Flash Lite nếu hết quota", isOn: $viewModel.autoSwitchTo31OnQuota)
                            .font(.caption)

                        if viewModel.geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Nhập nhanh Gemini API Key:")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.red)
                                SecureField("Dán Gemini API Key (AIzaSy...)", text: $viewModel.geminiApiKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(10)
                                    .background(Color(.tertiarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // Prompt Customization Accordion
                    DisclosureGroup("Xem / Chỉnh sửa câu lệnh dịch (Prompt)", isExpanded: $showPromptEditor) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $viewModel.translationPrompt)
                                .frame(minHeight: 120)
                                .font(.caption)
                                .padding(6)
                                .background(Color(.systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                            HStack {
                                Spacer()
                                Button("Khôi phục câu lệnh mặc định") {
                                    viewModel.resetPromptToDefault()
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // Progress / Status Section
                    if viewModel.isTranslatingBatch || !viewModel.translationStatusNote.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            if viewModel.isTranslatingBatch {
                                ProgressView(
                                    value: Double(viewModel.translationProgressCount),
                                    total: Double(max(viewModel.translationTotalCount, 1))
                                )
                                .tint(.orange)
                            }

                            Text(viewModel.translationStatusNote)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(viewModel.translationStatusNote.hasPrefix("❌") ? .red : .primary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    // Action Buttons
                    VStack(spacing: 10) {
                        if viewModel.isTranslatingBatch {
                            Button(role: .destructive) {
                                viewModel.cancelBatchTranslation()
                            } label: {
                                HStack {
                                    ProgressView()
                                        .tint(.white)
                                        .padding(.trailing, 6)
                                    Text("Dừng dịch")
                                        .fontWeight(.bold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.red)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        } else {
                            Button {
                                viewModel.startBatchTranslation()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "wand.and.stars")
                                    Text("Bắt đầu Dịch & Ghi đè File (\(selectedChaptersSlice.count) chương)")
                                        .fontWeight(.bold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(
                                    LinearGradient(
                                        colors: [Color.orange, Color(red: 0.85, green: 0.35, blue: 0.12)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }

                        if let selected = viewModel.selectedChapter,
                           LocalChapterStorage.shared.isChapterTranslated(selected.id),
                           !viewModel.isTranslatingBatch {
                            Button {
                                Task {
                                    await viewModel.restoreOriginalFromDrive(for: selected)
                                }
                            } label: {
                                Label("Khôi phục chương hiện tại về bản gốc trên Drive", systemImage: "arrow.uturn.backward.circle")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Dịch Truyện AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $activeChapterPickerTarget) { target in
                ChapterSelectionListModal(
                    title: target == .fromChapter ? "Chọn chương bắt đầu dịch" : "Chọn chương kết thúc dịch",
                    chapters: viewModel.chapters,
                    selectedIndex: target == .fromChapter ? viewModel.translateFromChapterIndex : viewModel.translateToChapterIndex
                ) { chosenIdx in
                    if target == .fromChapter {
                        viewModel.translateFromChapterIndex = chosenIdx
                        if viewModel.translateToChapterIndex < chosenIdx {
                            viewModel.translateToChapterIndex = chosenIdx
                        }
                    } else {
                        viewModel.translateToChapterIndex = chosenIdx
                        if viewModel.translateFromChapterIndex > chosenIdx {
                            viewModel.translateFromChapterIndex = chosenIdx
                        }
                    }
                }
            }
        }
    }

    private func quickRangeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.14))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func chapterSelectorRow(label: String, selectedIndex: Int, onTap: @escaping () -> Void) -> some View {
        let safeIdx = max(0, min(selectedIndex, max(viewModel.chapters.count - 1, 0)))
        let chapter = viewModel.chapters.isEmpty ? nil : viewModel.chapters[safeIdx]
        let isTranslated = chapter.map { LocalChapterStorage.shared.isChapterTranslated($0.id) } ?? false

        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 86, alignment: .leading)

                if let chapter {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(safeIdx + 1). \(chapter.cleanChapterName)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Image(systemName: isTranslated ? "checkmark.seal.fill" : "clock")
                                .font(.system(size: 10, weight: .bold))
                            Text(isTranslated ? "Đã dịch AI" : "Chưa dịch (Bản gốc)")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(isTranslated ? Color.green : Color.orange)
                    }
                }

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectNextUntranslatedRange(count: Int) {
        guard !viewModel.chapters.isEmpty else { return }
        let startSearch = max(0, viewModel.currentChapterIndex)
        if let firstUntranslated = (startSearch..<viewModel.chapters.count).first(where: {
            !LocalChapterStorage.shared.isChapterTranslated(viewModel.chapters[$0].id)
        }) {
            viewModel.translateFromChapterIndex = firstUntranslated
            viewModel.translateToChapterIndex = min(viewModel.chapters.count - 1, firstUntranslated + count - 1)
        } else if let anyUntranslated = (0..<viewModel.chapters.count).first(where: {
            !LocalChapterStorage.shared.isChapterTranslated(viewModel.chapters[$0].id)
        }) {
            viewModel.translateFromChapterIndex = anyUntranslated
            viewModel.translateToChapterIndex = min(viewModel.chapters.count - 1, anyUntranslated + count - 1)
        }
    }
}

// MARK: - Danh sách chọn chương có tìm kiếm, tự cuộn tới vị trí đang chọn và hiện rõ huy hiệu [Đã dịch] / [Chưa dịch]
private struct ChapterSelectionListModal: View {
    let title: String
    let chapters: [DriveItem]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var filterUntranslatedOnly: Bool = false

    private var filteredItems: [(index: Int, chapter: DriveItem, isTranslated: Bool)] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return chapters.enumerated().compactMap { idx, chap in
            let translated = LocalChapterStorage.shared.isChapterTranslated(chap.id)
            if filterUntranslatedOnly && translated {
                return nil
            }
            if !q.isEmpty {
                let matchTitle = chap.cleanChapterName.lowercased().contains(q)
                let matchNum = "\(idx + 1)".contains(q)
                if !matchTitle && !matchNum {
                    return nil
                }
            }
            return (idx, chap, translated)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Tìm số chương hoặc tên chương...", text: $searchText)
                            .font(.subheadline)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(9)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    Toggle("Chỉ hiện các chương chưa dịch", isOn: $filterUntranslatedOnly)
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.systemBackground))

                Divider()

                ScrollViewReader { proxy in
                    List {
                        ForEach(filteredItems, id: \.chapter.id) { item in
                            let isCurrentSelected = (item.index == selectedIndex)

                            Button {
                                onSelect(item.index)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Text("\(item.index + 1)")
                                        .font(.caption.weight(.bold))
                                        .frame(width: 34, height: 34)
                                        .background(isCurrentSelected ? Color.accentColor : Color(.secondarySystemBackground))
                                        .foregroundStyle(isCurrentSelected ? .white : .primary)
                                        .clipShape(Circle())

                                    Text(item.chapter.cleanChapterName)
                                        .font(.subheadline.weight(isCurrentSelected ? .bold : .regular))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)

                                    Spacer()

                                    if item.isTranslated {
                                        HStack(spacing: 3) {
                                            Image(systemName: "checkmark.seal.fill")
                                            Text("Đã dịch")
                                        }
                                        .font(.system(size: 11, weight: .bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.green.opacity(0.16))
                                        .foregroundStyle(Color.green)
                                        .clipShape(Capsule())
                                    } else {
                                        Text("Chưa dịch")
                                            .font(.system(size: 11, weight: .medium))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.secondary.opacity(0.12))
                                            .foregroundStyle(.secondary)
                                            .clipShape(Capsule())
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .id(item.index)
                        }
                    }
                    .listStyle(.plain)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            proxy.scrollTo(selectedIndex, anchor: .center)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") {
                        dismiss()
                    }
                }
            }
        }
    }
}
