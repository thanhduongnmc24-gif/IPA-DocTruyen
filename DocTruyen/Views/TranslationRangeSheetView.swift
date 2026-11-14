import SwiftUI

struct TranslationRangeSheetView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPromptEditor: Bool = false

    private var selectedSpanCount: Int {
        abs(viewModel.translateToChapterIndex - viewModel.translateFromChapterIndex) + 1
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Header Card
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [Color.orange, Color.red.opacity(0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 46, height: 46)
                            Image(systemName: "sparkles")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        .fixedSize()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Dịch & Biên tập lại truyện")
                                .font(.headline)
                            Text("Thay thế nội dung convert khó đọc và ghi đè trực tiếp vào file chương.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // Range Picker Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Chọn phạm vi chương cần dịch")
                            .font(.subheadline.weight(.bold))

                        // 3 nút chọn nhanh luôn nằm gọn trên 1 dòng, bằng nhau
                        HStack(spacing: 8) {
                            quickRangeButton(title: "Chỉ chương này", span: 1) {
                                let idx = max(0, viewModel.currentChapterIndex)
                                viewModel.translateFromChapterIndex = idx
                                viewModel.translateToChapterIndex = idx
                            }

                            quickRangeButton(title: "5 chương tiếp", span: 5) {
                                let idx = max(0, viewModel.currentChapterIndex)
                                viewModel.translateFromChapterIndex = idx
                                viewModel.translateToChapterIndex = min(max(viewModel.chapters.count - 1, 0), idx + 4)
                            }

                            quickRangeButton(title: "10 chương tiếp", span: 10) {
                                let idx = max(0, viewModel.currentChapterIndex)
                                viewModel.translateFromChapterIndex = idx
                                viewModel.translateToChapterIndex = min(max(viewModel.chapters.count - 1, 0), idx + 9)
                            }
                        }

                        if !viewModel.chapters.isEmpty {
                            VStack(spacing: 12) {
                                chapterSelectorRow(
                                    label: "Từ chương:",
                                    selectedIndex: $viewModel.translateFromChapterIndex
                                )

                                Divider()

                                chapterSelectorRow(
                                    label: "Đến chương:",
                                    selectedIndex: $viewModel.translateToChapterIndex
                                )
                            }
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        Text("Tổng cộng: **\(selectedSpanCount) chương** sẽ được biên tập lại và ghi đè file gốc.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Model & API Key Quick Config
                    VStack(alignment: .leading, spacing: 12) {
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
                                .frame(minHeight: 130)
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
                                    Text("Bắt đầu Dịch & Ghi đè File")
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
                .padding(18)
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
        }
    }

    @ViewBuilder
    private func quickRangeButton(title: String, span: Int, action: @escaping () -> Void) -> some View {
        let isSelected = (viewModel.translateFromChapterIndex == max(0, viewModel.currentChapterIndex)) && (selectedSpanCount == span)

        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
                .background(isSelected ? Color.accentColor : Color.accentColor.opacity(0.14))
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func chapterSelectorRow(label: String, selectedIndex: Binding<Int>) -> some View {
        let safeIdx = min(max(0, selectedIndex.wrappedValue), max(viewModel.chapters.count - 1, 0))
        let currentName = viewModel.chapters.indices.contains(safeIdx)
            ? "\(safeIdx + 1). \(viewModel.chapters[safeIdx].cleanChapterName)"
            : "Chưa chọn"

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 6) {
                    Button {
                        if selectedIndex.wrappedValue > 0 {
                            selectedIndex.wrappedValue -= 1
                        }
                    } label: {
                        Image(systemName: "minus")
                            .font(.caption2.weight(.bold))
                            .frame(width: 26, height: 26)
                            .background(Color(.tertiarySystemBackground))
                            .clipShape(Circle())
                    }
                    .disabled(selectedIndex.wrappedValue <= 0)

                    Button {
                        if selectedIndex.wrappedValue < viewModel.chapters.count - 1 {
                            selectedIndex.wrappedValue += 1
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption2.weight(.bold))
                            .frame(width: 26, height: 26)
                            .background(Color(.tertiarySystemBackground))
                            .clipShape(Circle())
                    }
                    .disabled(selectedIndex.wrappedValue >= viewModel.chapters.count - 1)
                }
            }

            NavigationLink {
                ChapterRangePickerListView(
                    title: label.replacingOccurrences(of: ":", with: ""),
                    chapters: viewModel.chapters,
                    selectedIndex: selectedIndex
                )
            } label: {
                HStack(spacing: 8) {
                    Text(currentName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct ChapterRangePickerListView: View {
    let title: String
    let chapters: [DriveItem]
    @Binding var selectedIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""

    private var filteredItems: [(offset: Int, element: DriveItem)] {
        let all = Array(chapters.enumerated())
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { idx, chap in
            "\(idx + 1)".contains(q) || chap.cleanChapterName.lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(filteredItems, id: \.element.id) { idx, chap in
                    Button {
                        selectedIndex = idx
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(idx + 1).")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .leading)

                            Text(chap.cleanChapterName)
                                .font(.subheadline.weight(selectedIndex == idx ? .bold : .regular))
                                .foregroundStyle(selectedIndex == idx ? Color.accentColor : Color.primary)
                                .lineLimit(1)

                            Spacer()

                            if selectedIndex == idx {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .id(idx)
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Tìm số chương hoặc tên chương...")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    proxy.scrollTo(selectedIndex, anchor: .center)
                }
            }
        }
    }
}