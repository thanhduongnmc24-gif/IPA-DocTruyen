import SwiftUI

struct TranslationRangeSheetView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPromptEditor: Bool = false
    @State private var showAdvancedOptions: Bool = false
    @State private var activeChapterPickerTarget: ChapterPickerTarget?

    enum ChapterPickerTarget: String, Identifiable {
        case fromChapter = "from"
        case toChapter = "to"
        var id: String { rawValue }
    }

    var body: some View {
        let _ = viewModel.translatedRevisionTrigger
        let totalChapters = viewModel.chapters.count
        let totalTranslatedInStory = LocalChapterStorage.shared.translatedCount(in: viewModel.chapters)
        let totalDriveSyncedInStory = LocalChapterStorage.shared.driveSyncedCount(in: viewModel.chapters)
        let totalUntranslatedInStory = max(0, totalChapters - totalTranslatedInStory)
        let totalUnsyncedInStory = LocalChapterStorage.shared.unsyncedTranslatedChapters(in: viewModel.chapters).count

        let startIdx = max(0, min(viewModel.translateFromChapterIndex, viewModel.translateToChapterIndex))
        let endIdx = min(max(totalChapters - 1, 0), max(viewModel.translateFromChapterIndex, viewModel.translateToChapterIndex))
        let selectedChaptersSlice = viewModel.chapters.isEmpty ? [] : Array(viewModel.chapters[startIdx...endIdx])

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {

                    // 1. THANH THỐNG KÊ TỔNG QUAN BỘ TRUYỆN (Gọn gàng trên 1 hàng, không bao giờ tràn chữ)
                    HStack(spacing: 6) {
                        statMetricPill(
                            icon: "books.vertical.fill",
                            label: "Tổng",
                            value: "\(totalChapters)",
                            tint: .secondary
                        )
                        statMetricPill(
                            icon: "checkmark.circle.fill",
                            label: "Đã dịch",
                            value: "\(totalTranslatedInStory)",
                            tint: .green
                        )
                        statMetricPill(
                            icon: "icloud.fill",
                            label: "Lên Drive",
                            value: "\(totalDriveSyncedInStory)",
                            tint: .blue
                        )
                        statMetricPill(
                            icon: "clock.fill",
                            label: "Chưa dịch",
                            value: "\(totalUntranslatedInStory)",
                            tint: .orange
                        )
                    }

                    // 2. NÚT CHÍNH 1 CHẠM: TỰ ĐỘNG DỊCH NGẦM & GHI ĐÈ CÁC CHƯƠNG CHƯA DỊCH
                    if viewModel.isTranslatingBatch {
                        liveTranslationProgressCard
                    } else {
                        Button {
                            if viewModel.startAutoTranslateAllUntranslatedInBackground() {
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.white.opacity(0.22))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: "bolt.sparkles.fill")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(.white)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(totalUntranslatedInStory > 0
                                         ? "Dịch ngầm \(totalUntranslatedInStory) chương chưa dịch"
                                         : (totalUnsyncedInStory > 0
                                            ? "Đẩy bù ngầm \(totalUnsyncedInStory) chương lên Drive"
                                            : "Tất cả các chương đã được dịch"))
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)

                                    Text("Tự động dịch & ghi đè lên Google Drive • Đóng bảng đọc tiếp ngay")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 4)

                                Image(systemName: "chevron.right.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 0.95, green: 0.45, blue: 0.10), Color(red: 0.82, green: 0.22, blue: 0.14)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: Color.orange.opacity(0.25), radius: 6, x: 0, y: 3)
                        }
                        .buttonStyle(.plain)
                    }

                    // 3. THANH ĐỒNG BỘ BÙ GOOGLE DRIVE GỌN GÀNG (Chỉ hiện khi có chương đã dịch trên máy nhưng chưa lên Drive)
                    if totalUnsyncedInStory > 0 && viewModel.isCloudOverwriteConfigured {
                        HStack(spacing: 10) {
                            Image(systemName: viewModel.isSyncingToDrive ? "arrow.triangle.2.circlepath.icloud.fill" : "exclamationmark.icloud.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(viewModel.isSyncingToDrive ? .blue : .orange)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(viewModel.isSyncingToDrive
                                     ? "Đang ghi đè ngầm lên Drive (\(viewModel.driveSyncProgressCount)/\(viewModel.driveSyncTotalCount))"
                                     : "Còn \(totalUnsyncedInStory) chương đã dịch chưa ghi đè lên Drive")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                if viewModel.isSyncingToDrive {
                                    ProgressView(
                                        value: Double(viewModel.driveSyncProgressCount),
                                        total: Double(max(viewModel.driveSyncTotalCount, 1))
                                    )
                                    .tint(.blue)
                                }
                            }

                            Spacer(minLength: 6)

                            if viewModel.isSyncingToDrive {
                                Button {
                                    viewModel.cancelDriveSync()
                                } label: {
                                    Text("Dừng")
                                        .font(.system(size: 11, weight: .bold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.red.opacity(0.14))
                                        .foregroundStyle(.red)
                                        .clipShape(Capsule())
                                }
                            } else {
                                Button {
                                    Task {
                                        await viewModel.syncAllTranslatedChaptersToDrive(onlyUnsynced: true)
                                    }
                                } label: {
                                    Text("Ghi đè ngầm")
                                        .font(.system(size: 11, weight: .bold))
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(Color.blue)
                                        .foregroundStyle(.white)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    // 4. KHỐI CHỌN PHẠM VI TÙY CHỈNH (Từ chương -> Đến chương gọn đẹp, không rớt dòng)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Hoặc dịch theo phạm vi tùy chọn")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Đã chọn: \(selectedChaptersSlice.count) chương")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                quickRangeButton("Chương này") {
                                    let idx = max(0, viewModel.currentChapterIndex)
                                    viewModel.translateFromChapterIndex = idx
                                    viewModel.translateToChapterIndex = idx
                                }

                                quickRangeButton("+5 chương") {
                                    let idx = max(0, viewModel.currentChapterIndex)
                                    viewModel.translateFromChapterIndex = idx
                                    viewModel.translateToChapterIndex = min(totalChapters - 1, idx + 4)
                                }

                                quickRangeButton("+10 chương") {
                                    let idx = max(0, viewModel.currentChapterIndex)
                                    viewModel.translateFromChapterIndex = idx
                                    viewModel.translateToChapterIndex = min(totalChapters - 1, idx + 9)
                                }

                                quickRangeButton("+20 chương") {
                                    let idx = max(0, viewModel.currentChapterIndex)
                                    viewModel.translateFromChapterIndex = idx
                                    viewModel.translateToChapterIndex = min(totalChapters - 1, idx + 19)
                                }

                                quickRangeButton("5 chương chưa dịch") {
                                    selectNextUntranslatedRange(count: 5)
                                }
                            }
                        }

                        if !viewModel.chapters.isEmpty {
                            VStack(spacing: 0) {
                                chapterSelectorRow(
                                    badgeText: "TỪ",
                                    selectedIndex: viewModel.translateFromChapterIndex
                                ) {
                                    activeChapterPickerTarget = .fromChapter
                                }

                                Divider()
                                    .padding(.leading, 48)

                                chapterSelectorRow(
                                    badgeText: "ĐẾN",
                                    selectedIndex: viewModel.translateToChapterIndex
                                ) {
                                    activeChapterPickerTarget = .toChapter
                                }
                            }
                            .background(Color(.tertiarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        if !viewModel.isTranslatingBatch {
                            Button {
                                viewModel.startBatchTranslation()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("Dịch & Ghi đè phạm vi đã chọn (\(selectedChaptersSlice.count) chương)")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // 5. CẤU HÌNH NHANH MODEL AI & TÙY CHỌN GỌN GÀNG
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Model AI", systemImage: "cpu")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Picker("Chọn Model", selection: $viewModel.selectedGeminiModel) {
                                ForEach(GeminiModelChoice.allCases) { model in
                                    Text(model.shortBadge).tag(model)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 220)
                        }

                        if viewModel.geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Nhập Gemini API Key để bắt đầu dịch:")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.red)
                                SecureField("Dán Gemini API Key (AIzaSy...)", text: $viewModel.geminiApiKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.caption)
                                    .padding(9)
                                    .background(Color(.tertiarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }

                        Divider()

                        DisclosureGroup(
                            isExpanded: $showAdvancedOptions,
                            content: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Toggle("Tự đổi sang 3.1 Flash Lite & chờ hồi Quota", isOn: $viewModel.autoSwitchTo31OnQuota)
                                        .font(.caption)

                                    Toggle("Không dịch lại chương đã dịch (chỉ đẩy bù Drive)", isOn: $viewModel.skipAlreadyTranslatedInBatch)
                                        .font(.caption)
                                }
                                .padding(.top, 6)
                            },
                            label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Tùy chọn nâng cao (Tự đổi model, bỏ qua chương đã dịch)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                            }
                        )

                        Divider()

                        DisclosureGroup(
                            isExpanded: $showPromptEditor,
                            content: {
                                VStack(alignment: .leading, spacing: 8) {
                                    TextEditor(text: $viewModel.translationPrompt)
                                        .frame(minHeight: 110)
                                        .font(.caption)
                                        .padding(6)
                                        .background(Color(.systemBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))

                                    HStack {
                                        Spacer()
                                        Button("Khôi phục mặc định") {
                                            viewModel.resetPromptToDefault()
                                        }
                                        .font(.caption.weight(.semibold))
                                    }
                                }
                                .padding(.top, 6)
                            },
                            label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "text.quote")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Câu lệnh biên tập & dịch truyện (Prompt)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                            }
                        )
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    if !viewModel.isTranslatingBatch && !viewModel.translationStatusNote.isEmpty {
                        Text(viewModel.translationStatusNote)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(viewModel.translationStatusNote.hasPrefix("❌") ? .red : .secondary)
                            .padding(.horizontal, 4)
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
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .navigationTitle("Dịch Truyện AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(viewModel.isTranslatingBatch ? "Đọc tiếp" : "Đóng") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(item: $activeChapterPickerTarget) { target in
                ChapterSelectionListModal(
                    title: target == .fromChapter ? "Chọn chương bắt đầu" : "Chọn chương kết thúc",
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

    // MARK: - Thẻ tiến trình khi đang dịch ngầm
    private var liveTranslationProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.orange)
                Text("Đang dịch & ghi đè ngầm (\(viewModel.translationProgressCount)/\(viewModel.translationTotalCount))")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }

            ProgressView(
                value: Double(viewModel.translationProgressCount),
                total: Double(max(viewModel.translationTotalCount, 1))
            )
            .tint(.orange)

            if !viewModel.translationStatusNote.isEmpty {
                Text(viewModel.translationStatusNote)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Label("Đóng bảng & Đọc tiếp", systemImage: "book.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Button(role: .destructive) {
                    viewModel.cancelBatchTranslation()
                } label: {
                    Label("Dừng dịch", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.red.opacity(0.15))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func statMetricPill(icon: String, label: String, value: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(value)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(tint)
            .lineLimit(1)

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func quickRangeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.14))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func chapterSelectorRow(badgeText: String, selectedIndex: Int, onTap: @escaping () -> Void) -> some View {
        let safeIdx = max(0, min(selectedIndex, max(viewModel.chapters.count - 1, 0)))
        let chapter = viewModel.chapters.isEmpty ? nil : viewModel.chapters[safeIdx]
        let isTranslated = chapter.map { LocalChapterStorage.shared.isChapterTranslated($0.id) } ?? false
        let isDriveSynced = chapter.map { LocalChapterStorage.shared.isChapterSyncedToDrive($0.id) } ?? false

        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(badgeText)
                    .font(.system(size: 10, weight: .heavy))
                    .frame(width: 32, height: 22)
                    .background(Color.accentColor.opacity(0.14))
                    .foregroundStyle(Color.accentColor)
                    .clipShape( RoundedRectangle(cornerRadius: 6) )

                if let chapter {
                    Text("\(safeIdx + 1). \(chapter.cleanChapterName)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                // Nhãn trạng thái siêu gọn trên cùng 1 hàng
                if isDriveSynced {
                    HStack(spacing: 3) {
                        Image(systemName: "icloud.fill")
                        Text("Drive")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.15))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
                } else if isTranslated {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.seal.fill")
                        Text("Đã dịch")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
                } else {
                    Text("Chưa dịch")
                        .font(.system(size: 10, weight: .semibold))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
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

private struct ChapterSelectionListModal: View {
    let title: String
    let chapters: [DriveItem]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var filterUntranslatedOnly: Bool = false
    @State private var listResetToken: Int = 0

    private var filteredItems: [(index: Int, chapter: DriveItem, isTranslated: Bool, isSynced: Bool)] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return chapters.enumerated().compactMap { idx, chap in
            let translated = LocalChapterStorage.shared.isChapterTranslated(chap.id)
            let synced = LocalChapterStorage.shared.isChapterSyncedToDrive(chap.id)
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
            return (idx, chap, translated, synced)
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
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            Color.clear
                                .frame(height: 1)
                                .id("PICKER_TOP_ANCHOR")

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
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(2)

                                        Spacer()

                                        if item.isSynced {
                                            HStack(spacing: 3) {
                                                Image(systemName: "icloud.fill")
                                                Text("Đã lên Drive")
                                            }
                                            .font(.system(size: 10, weight: .bold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.blue.opacity(0.16))
                                            .foregroundStyle(Color.blue)
                                            .clipShape(Capsule())
                                        } else if item.isTranslated {
                                            HStack(spacing: 3) {
                                                Image(systemName: "checkmark.seal.fill")
                                                Text("Đã dịch")
                                            }
                                            .font(.system(size: 10, weight: .bold))
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
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(isCurrentSelected ? Color.accentColor.opacity(0.08) : Color.clear)
                                }
                                .buttonStyle(.plain)
                                .id(item.index)

                                Divider()
                                    .padding(.leading, 58)
                            }
                        }
                    }
                    .id("CHAPTER_PICKER_SCROLL_\(filterUntranslatedOnly)_\(listResetToken)")
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if filterUntranslatedOnly {
                                proxy.scrollTo("PICKER_TOP_ANCHOR", anchor: .top)
                            } else {
                                proxy.scrollTo(selectedIndex, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: filterUntranslatedOnly) { isFilteringUntranslated in
                        listResetToken += 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            if isFilteringUntranslated {
                                if let nextUntranslated = filteredItems.first(where: { $0.index >= selectedIndex }) {
                                    proxy.scrollTo(nextUntranslated.index, anchor: .top)
                                } else {
                                    proxy.scrollTo("PICKER_TOP_ANCHOR", anchor: .top)
                                }
                            } else {
                                proxy.scrollTo(selectedIndex, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: searchText) { _ in
                        proxy.scrollTo("PICKER_TOP_ANCHOR", anchor: .top)
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
